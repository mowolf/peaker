import Foundation

/// A calendar day without time or time zone ("2026-08-14"): an outing happens on a day, wherever it is read.
public struct DayDate: Sendable, Hashable, Comparable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int

    public init?(year: Int, month: Int, day: Int) {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        self.year = year; self.month = month; self.day = day
    }

    /// "2026-08-14", also with a time after it ("2026-08-14T10:30"), as YAML tools sometimes write.
    public init?(_ text: String) {
        let parts = text.prefix(10).split(separator: "-", omittingEmptySubsequences: false)
        guard text.count >= 10, parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        if text.count > 10, let next = text.dropFirst(10).first, next != "T", next != " " { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// The day of `date` in `calendar`'s time zone.
    public init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        year = c.year ?? 2000; month = c.month ?? 1; day = c.day ?? 1
    }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    public static func < (a: DayDate, b: DayDate) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }
}

/// One outing in the peak book: a Markdown file with YAML front matter.
///
/// ```markdown
/// ---
/// date: 2026-08-14
/// status: summited
/// peaks:
///   - id: wd:Q1374
///     name: Matterhorn
///     elevation: 4478
///     lat: 45.97630
///     lon: 7.65860
/// companions: [Anna]
/// ---
/// # Matterhorn via the Hörnli ridge
/// ```
///
/// The files are the source of truth and may be edited in any text editor, so reading never fails: missing or
/// broken fields get defaults, and a file without front matter is an entry without peaks ("unlinked").
/// Writing keeps everything the app didn't change exactly as it was (unknown keys, comments, formatting).
public struct PeakEntry: Sendable, Equatable {
    public enum Status: String, Sendable, CaseIterable {
        /// Reached the top.
        case summited
        /// Tried, turned back.
        case attempted
        /// On the wishlist.
        case planned
    }

    /// A peak as recorded in the entry: a snapshot, so the entry stays readable without the peak database.
    public struct Peak: Sendable, Equatable {
        /// Stable peak ID (`wd:Q1374`, `osm:n123`, `gn:456`), nil for peaks typed in by hand.
        public var id: String?
        public var name: String?
        public var elevation: Double?
        public var coordinate: GeoCoordinate?

        public init(id: String?, name: String?, elevation: Double? = nil, coordinate: GeoCoordinate? = nil) {
            self.id = id; self.name = name; self.elevation = elevation; self.coordinate = coordinate
        }

        public init(_ peak: PeakInfo, language: String? = nil) {
            self.init(id: peak.id, name: peak.displayName(language: language), elevation: peak.elevation,
                      coordinate: peak.coordinate)
        }

        public var displayName: String { name ?? id ?? "Unknown peak" }
    }

    /// Day of the outing; nil for wishlist entries (or a missing/unreadable date).
    public var date: DayDate?
    public var status: Status
    public var peaks: [Peak]
    public var companions: [String]
    /// Markdown after the front matter, as written.
    public var body: String
    /// The front matter as read, so writing can keep what the app didn't change. Nil for new entries.
    var source: FrontMatter?

    public init(date: DayDate?, status: Status, peaks: [Peak], companions: [String] = [], body: String = "") {
        self.date = date; self.status = status; self.peaks = peaks; self.companions = companions; self.body = body
    }

    /// Linked to at least one peak (files without front matter, or without peaks, are not).
    public var isLinked: Bool { !peaks.isEmpty }

    /// The first `# ` heading of the body, if any ("Matterhorn via the Hörnli ridge").
    public var title: String? {
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                let title = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                return title.isEmpty ? nil : title
            }
        }
        return nil
    }

    // MARK: - File names

    /// Suggested file name: "2026-08-14 Matterhorn.md", or "Matterhorn.md" for a wishlist entry without date.
    public var suggestedFileName: String {
        let peak = peaks.first?.displayName ?? title ?? "Untitled"
        let parts = [date?.description, peak].compactMap { $0 }
        return Self.sanitizedFileName(parts.joined(separator: " ")) + ".md"
    }

    /// `name`, or "name 2.md", "name 3.md", … if it is taken (compared without case, as on APFS).
    public static func uniqueFileName(_ name: String, existing: Set<String>) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        let stem = name.hasSuffix(".md") ? String(name.dropLast(3)) : name
        var n = 2
        while taken.contains("\(stem) \(n).md".lowercased()) { n += 1 }
        return "\(stem) \(n).md"
    }

    /// True if `fileName` is the name the app would give this entry, possibly numbered ("… 2.md"), i.e. the user
    /// hasn't renamed the file. Such files are renamed when the entry changes (a wishlist entry gets its date).
    public func hasAutomaticName(_ fileName: String) -> Bool {
        let suggested = suggestedFileName.lowercased()
        let name = fileName.lowercased()
        if name == suggested { return true }
        let stem = suggested.dropLast(3) + " "
        guard name.hasPrefix(stem), name.hasSuffix(".md") else { return false }
        let number = name.dropFirst(stem.count).dropLast(3)
        return !number.isEmpty && number.allSatisfy(\.isNumber)
    }

    static func sanitizedFileName(_ text: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        var cleaned = String(String.UnicodeScalarView(text.unicodeScalars.map { forbidden.contains($0) ? "-" : $0 }))
        cleaned = cleaned.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
        if cleaned.count > 80 { cleaned = String(cleaned.prefix(80)).trimmingCharacters(in: .whitespaces) }
        return cleaned.isEmpty ? "Untitled" : cleaned
    }
}

// MARK: - Matching entries to peaks

public extension PeakEntry.Peak {
    /// Within this distance (metres) of the snapshot coordinates, the nearest peak is taken to be this one.
    static let matchRadius = 200.0

    /// The peak in the installed databases this entry refers to: by ID (current or an older alias, which `byID`
    /// resolves), else the nearest peak within `matchRadius` of the recorded coordinates. Nil keeps the snapshot.
    func resolve(byID: (String) -> PeakInfo?, near: (GeoCoordinate, Double) -> [PeakInfo]) -> PeakInfo? {
        if let id, let peak = byID(id) { return peak }
        guard let coordinate else { return nil }
        return near(coordinate, Self.matchRadius)
            .map { ($0, Geo.distance(coordinate, $0.coordinate)) }
            .filter { $0.1 <= Self.matchRadius }
            .min { $0.1 < $1.1 }?.0
    }
}
