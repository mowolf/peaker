import Foundation
import Observation
import PeakerKit

/// An entry file in the peak book folder.
struct StoredEntry: Identifiable, Sendable, Equatable {
    var fileName: String
    var entry: PeakEntry
    var modified: Date
    /// The installed peak each of `entry.peaks` refers to (same order; nil: not found, the snapshot is shown).
    var resolvedIDs: [String?]

    var id: String { fileName }

    /// IDs to mark in the viewer: the resolved ID, else the ID written in the file.
    var peakIDs: [String] {
        zip(entry.peaks, resolvedIDs).compactMap { peak, resolved in resolved ?? peak.id }
    }
}

/// How a peak shows in the viewer.
enum PeakMark: Sendable { case climbed, wishlist }

/// The peak book: Markdown files in the app's Documents folder (Files › On My iPhone › Peaker).
///
/// The files are the only source of truth. This keeps them in memory, matched to the installed peaks, and
/// re-reads the folder at launch, when the app comes back to the foreground (files may have been edited in
/// the Files app) and when the installed peak data changes. A scan of a few hundred small files takes
/// milliseconds, so there is no on-disk index.
@MainActor
@Observable
final class PeakBook {
    /// Newest first; wishlist entries (no date) after the dated ones, by name.
    private(set) var entries: [StoredEntry] = []
    /// Peak ID → mark, for the viewer labels. Climbed wins over wishlist.
    private(set) var marks: [String: PeakMark] = [:]
    /// Changes whenever `marks` does (cheap to compare, for caches keyed on the marks).
    private(set) var marksVersion = 0
    private(set) var isLoaded = false

    let folder: URL
    @ObservationIgnored private var databases: [URL] = []
    @ObservationIgnored private var generation = 0

    init(folder: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]) {
        self.folder = folder
    }

    // MARK: - Loading

    /// Peak databases to match entries against (call when the installed packs change).
    func setDatabases(_ urls: [URL]) async {
        guard urls != databases else { return }
        databases = urls
        await reload()
    }

    /// Re-read all entry files and match them to peaks (off the main thread).
    func reload() async {
        generation += 1
        let current = generation
        let folder = folder, databases = databases
        let loaded = await Task.detached(priority: .utility) {
            Self.resolve(Self.readFolder(folder), databases: databases)
        }.value
        guard current == generation else { return }  // a newer reload or a write happened meanwhile
        apply(loaded)
        isLoaded = true
    }

    nonisolated private static func readFolder(_ folder: URL) -> [(String, PeakEntry, Date)] {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                options: [.skipsHiddenFiles])) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "md" }.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return (url.lastPathComponent, PeakEntry(markdown: text), modified ?? .distantPast)
        }
    }

    /// Match every entry's peaks to the installed databases: all IDs in one query per database, then the
    /// position fallback for the rest.
    nonisolated private static func resolve(_ files: [(String, PeakEntry, Date)], databases: [URL]) -> [StoredEntry] {
        let ids = Set(files.flatMap { $0.1.peaks.compactMap(\.id) })
        let byID = databases.isEmpty ? [:] : PeakDatabase.peaks(ids: ids, in: databases)
        return files.map { name, entry, modified in
            let resolved = entry.peaks.map { peak in
                peak.resolve(byID: { byID[$0] },
                             near: { databases.isEmpty ? [] : PeakDatabase.peaks(near: $0, radius: $1, in: databases) })?.id
            }
            return StoredEntry(fileName: name, entry: entry, modified: modified, resolvedIDs: resolved)
        }
    }

    private func apply(_ loaded: [StoredEntry]) {
        entries = loaded.sorted(by: Self.order)
        var marks: [String: PeakMark] = [:]
        for stored in entries {
            for id in stored.peakIDs {
                switch stored.entry.status {
                case .summited: marks[id] = .climbed
                case .planned where marks[id] == nil: marks[id] = .wishlist
                default: break
                }
            }
        }
        if marks != self.marks {
            self.marks = marks
            marksVersion += 1
        }
    }

    private static func order(_ a: StoredEntry, _ b: StoredEntry) -> Bool {
        switch (a.entry.date, b.entry.date) {
        case let (x?, y?) where x != y: return x > y
        case (.some, nil): return true
        case (nil, .some): return false
        default: return a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending
        }
    }

    // MARK: - Queries

    /// Entries that mention this peak, newest first.
    func entries(forPeak id: String) -> [StoredEntry] {
        entries.filter { $0.peakIDs.contains(id) }
    }

    func mark(of peakID: String) -> PeakMark? { marks[peakID] }

    // MARK: - Changes

    /// Record a climb. A wishlist entry for the peak becomes the climb (its notes start the story, the file
    /// gets the date in its name); a climb of the same peak on the same day is not duplicated.
    @discardableResult
    func markClimbed(_ peak: PeakInfo, on day: DayDate, language: String?) throws -> StoredEntry {
        let mine = entries(forPeak: peak.id)
        if let existing = mine.first(where: { $0.entry.status == .summited && $0.entry.date == day }) {
            return existing
        }
        if let planned = mine.first(where: { $0.entry.status == .planned }) {
            var entry = planned.entry
            entry.status = .summited
            entry.date = day
            return try save(planned, as: entry)
        }
        let entry = PeakEntry(date: day, status: .summited, peaks: [PeakEntry.Peak(peak, language: language)])
        return try create(entry, resolvedIDs: [peak.id])
    }

    /// Put a peak on the wishlist (once).
    @discardableResult
    func addToWishlist(_ peak: PeakInfo, language: String?) throws -> StoredEntry {
        if let planned = entries(forPeak: peak.id).first(where: { $0.entry.status == .planned }) { return planned }
        let entry = PeakEntry(date: nil, status: .planned, peaks: [PeakEntry.Peak(peak, language: language)])
        return try create(entry, resolvedIDs: [peak.id])
    }

    /// Write a new entry file.
    @discardableResult
    func create(_ entry: PeakEntry, resolvedIDs: [String?]) throws -> StoredEntry {
        let name = PeakEntry.uniqueFileName(entry.suggestedFileName, existing: Set(entries.map(\.fileName)))
        try write(entry, to: name)
        let stored = StoredEntry(fileName: name, entry: entry, modified: Date(), resolvedIDs: resolvedIDs)
        changed { $0.append(stored) }
        return stored
    }

    /// Save changes to an entry. A file that still has the name the app gave it is renamed when that name
    /// changes (e.g. a wishlist entry gets its date); names chosen by the user are kept. The editor saves with
    /// `rename: false` while open (the entry keeps its identity) and renames when it closes.
    /// - Parameter namedAfter: the entry as it was when the file got its name (the editor passes the entry as
    ///   opened, since its earlier saves already changed `stored.entry`).
    @discardableResult
    func save(_ stored: StoredEntry, as entry: PeakEntry, rename: Bool = true,
              namedAfter: PeakEntry? = nil) throws -> StoredEntry {
        var name = stored.fileName
        if rename, (namedAfter ?? stored.entry).hasAutomaticName(stored.fileName), !entry.hasAutomaticName(stored.fileName) {
            let others = Set(entries.map(\.fileName)).subtracting([stored.fileName])
            name = PeakEntry.uniqueFileName(entry.suggestedFileName, existing: others)
        }
        try write(entry, to: name)
        if name != stored.fileName {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(stored.fileName))
        }
        // Peaks edited: the IDs as written (peaks picked from the database carry their current ID); matched
        // properly again on the next reload.
        let resolved = entry.peaks == stored.entry.peaks ? stored.resolvedIDs : entry.peaks.map(\.id)
        let updated = StoredEntry(fileName: name, entry: entry, modified: Date(), resolvedIDs: resolved)
        changed { list in
            list.removeAll { $0.fileName == stored.fileName }
            list.append(updated)
        }
        return updated
    }

    func delete(_ stored: StoredEntry) throws {
        let url = folder.appendingPathComponent(stored.fileName)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        changed { $0.removeAll { $0.fileName == stored.fileName } }
    }

    private func write(_ entry: PeakEntry, to name: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(entry.markdown().utf8).write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    /// Apply an in-memory change; a reload still running would overwrite it with older data, so it is dropped.
    private func changed(_ change: (inout [StoredEntry]) -> Void) {
        generation += 1
        var list = entries
        change(&list)
        apply(list)
    }
}
