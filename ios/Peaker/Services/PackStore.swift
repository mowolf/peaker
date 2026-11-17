import Foundation
import Observation
import PeakerKit
import UIKit

struct InstalledPack: Codable, Hashable, Identifiable {
    var code: String
    var name: String
    var builtAt: String
    var tiles: [String]
    /// File name of the peak DB in the packs' peaks directory (or inside the bundle for the demo).
    var peaksFile: String
    var bytes: Int
    var peakCount: Int
    var isBundled: Bool
    /// Folder name under `BundledPacks/` for packs shipped with the app.
    var bundleFolder: String?
    /// High-detail (30 m) tiles of the pack, if it has them. `tiles` are the 90 m ones.
    var tiles30: [String]?
    var id: String { isBundled ? "bundled-\(code)" : code }

    /// Tile names per resolution ("90", "30").
    var tilesByResolution: [String: Set<String>] {
        var out: [String: Set<String>] = ["90": Set(tiles)]
        if let tiles30, !tiles30.isEmpty { out["30"] = Set(tiles30) }
        return out
    }
}

/// Everything the background horizon computation needs, captured on the main actor.
struct PackSnapshot: Sendable {
    var tileFiles: [TileID: URL]
    /// High-detail 30 m tiles; used for the terrain near the viewer.
    var tileFiles30: [TileID: URL]
    var peakDatabases: [URL]
    var landTiles: LandTiles?
}

struct DownloadState: Equatable {
    var bytesDone: Int = 0
    var bytesTotal: Int = 0
    var error: String?
    var fraction: Double { bytesTotal > 0 ? Double(bytesDone) / Double(bytesTotal) : 0 }
}

/// Offline packs: the bundled ones, downloaded countries, the catalog, and downloads.
///
/// Downloaded tiles live in one shared store (`tiles/<resolution>/<name>.pkt`), used by every pack that
/// lists them. `TileLedger` decides what may be deleted: a tile stays while an installed pack or a running
/// download needs it. Files nobody uses (e.g. from a cancelled download) are removed at launch.
@MainActor
@Observable
final class PackStore {
    /// Data server root (contains `v1/`), from Info.plist `PeakerDataURL`.
    let baseURL: URL?
    private(set) var installed: [InstalledPack] = []
    private(set) var catalog: Catalog?
    private(set) var catalogError: String?
    private(set) var isLoadingCatalog = false
    private(set) var downloads: [String: DownloadState] = [:]
    /// Bumped whenever installed data changes, so the viewer knows to recompute.
    private(set) var version = 0

    /// Tiles each running download needs (by pack code), so removing another pack can't delete them.
    @ObservationIgnored private var reserved: [String: [String: Set<String>]] = [:]
    /// SHA-256 of every stored tile file, per resolution: tells an outdated tile from a current one.
    @ObservationIgnored private var tileChecksums: [String: [String: String]] = [:]
    /// Running downloads by pack code, so they can be cancelled.
    @ObservationIgnored private var downloadTasks: [String: Task<Void, Never>] = [:]
    /// Free space to leave on the device after a download (bytes).
    private static let spaceReserve = 300 * 1024 * 1024

    private static let resolutions = ["90", "30"]
    private let root: URL
    private func tilesDir(_ resolution: String) -> URL {
        root.appendingPathComponent("tiles/\(resolution)", isDirectory: true)
    }
    private var peaksDir: URL { root.appendingPathComponent("peaks", isDirectory: true) }
    private var installedFile: URL { root.appendingPathComponent("installed.json") }
    private var catalogFile: URL { root.appendingPathComponent("catalog.json") }
    private var checksumsFile: URL { root.appendingPathComponent("tile-checksums.json") }
    /// Packs shipped inside the app: one folder per pack with manifest.json, tiles/90/*.pkt, peaks.sqlite.
    private let bundledRoot = Bundle.main.url(forResource: "BundledPacks", withExtension: nil)

    init() {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "PeakerDataURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        baseURL = raw.isEmpty || raw.hasPrefix("$(") ? nil : URL(string: raw)

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("Packs", isDirectory: true)
        for resolution in Self.resolutions {
            try? FileManager.default.createDirectory(at: tilesDir(resolution), withIntermediateDirectories: true)
        }
        try? FileManager.default.createDirectory(at: peaksDir, withIntermediateDirectories: true)
        // Re-downloadable data: keep it out of iCloud backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var rootURL = root
        try? rootURL.setResourceValues(values)

        // An unreadable list must not look like "nothing installed": the cleanup below would then delete every
        // downloaded tile. Without a readable list, keep all files.
        var installedListReadable = true
        if FileManager.default.fileExists(atPath: installedFile.path) {
            if let data = try? Data(contentsOf: installedFile),
               let list = try? JSONDecoder().decode([InstalledPack].self, from: data) {
                installed = list.filter { !$0.isBundled }
            } else {
                installedListReadable = false
            }
        }
        installed.insert(contentsOf: loadBundledPacks(), at: 0)
        if let data = try? Data(contentsOf: catalogFile) {
            catalog = try? Catalog.decode(data)
        }
        if let data = try? Data(contentsOf: checksumsFile),
           let sums = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            tileChecksums = sums
        }
        if installedListReadable { removeUnusedTiles() }
    }

    private func loadBundledPacks() -> [InstalledPack] {
        guard let bundledRoot,
              let folders = try? FileManager.default.contentsOfDirectory(atPath: bundledRoot.path) else { return [] }
        var packs: [InstalledPack] = []
        for folder in folders.sorted() {
            let manifestURL = bundledRoot.appendingPathComponent(folder).appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL), let m = try? PackManifest.decode(data) else { continue }
            let tiles = m.tiles["90"] ?? []
            var bytes = m.peaks.bytes
            for t in tiles { bytes += t.bytes }
            packs.append(InstalledPack(code: m.code, name: m.name, builtAt: m.builtAt, tiles: tiles.map(\.name),
                                       peaksFile: m.peaks.path, bytes: bytes, peakCount: m.peaks.count,
                                       isBundled: true, bundleFolder: folder))
        }
        return packs
    }

    private func bundledURL(_ pack: InstalledPack, _ relativePath: String) -> URL? {
        guard let bundledRoot, let folder = pack.bundleFolder else { return nil }
        return bundledRoot.appendingPathComponent(folder).appendingPathComponent(relativePath)
    }

    // MARK: - Lookup

    func snapshot() -> PackSnapshot {
        var files: [TileID: URL] = [:]
        var files30: [TileID: URL] = [:]
        var dbs: [URL] = []
        for pack in installed {
            for name in pack.tiles {
                guard let id = TileID(name: name) else { continue }
                if pack.isBundled {
                    if files[id] == nil, let url = bundledURL(pack, "tiles/90/\(name).pkt") { files[id] = url }
                } else {
                    files[id] = tilesDir("90").appendingPathComponent("\(name).pkt")  // downloaded tiles win
                }
            }
            for name in pack.tiles30 ?? [] {
                if let id = TileID(name: name) { files30[id] = tilesDir("30").appendingPathComponent("\(name).pkt") }
            }
            if pack.isBundled {
                if let url = bundledURL(pack, pack.peaksFile) { dbs.append(url) }
            } else {
                dbs.append(peaksDir.appendingPathComponent(pack.peaksFile))
            }
        }
        return PackSnapshot(tileFiles: files, tileFiles30: files30, peakDatabases: dbs, landTiles: catalog?.landTiles())
    }

    func isInstalled(_ code: String) -> Bool { installed.contains { $0.code == code } }

    /// Downloaded (not bundled) copy of a country, if any.
    func isDownloaded(_ code: String) -> Bool { installed.contains { $0.code == code && !$0.isBundled } }

    var downloadedBytes: Int { installed.filter { !$0.isBundled }.reduce(0) { $0 + $1.bytes } }

    /// Catalog entries for countries around a coordinate, to suggest downloads.
    func suggestedCountries(near c: GeoCoordinate) -> [Catalog.CountryEntry] {
        (catalog?.countries ?? []).filter { e in
            e.bbox.count == 4 && c.longitude >= e.bbox[0] && c.latitude >= e.bbox[1]
                && c.longitude <= e.bbox[2] && c.latitude <= e.bbox[3]
        }
    }

    // MARK: - Catalog

    func refreshCatalog() async {
        guard let baseURL else {
            catalogError = PackError.noServer.localizedDescription
            return
        }
        isLoadingCatalog = true
        defer { isLoadingCatalog = false }
        do {
            let data = try await PackDownloader.fetch(baseURL.appendingPathComponent("v1/catalog.json"))
            let fresh = try Catalog.decode(data)
            let oldLand: [String: String]? = catalog?.landTiles
            catalog = fresh
            catalogError = nil
            try? data.write(to: catalogFile, options: .atomic)
            // Only the land tiles affect the terrain (sea vs. missing data): recompute only if they changed,
            // not on every launch.
            if oldLand != fresh.landTiles { version += 1 }
        } catch {
            catalogError = error.localizedDescription
        }
    }

    // MARK: - Tile bookkeeping

    /// Which downloaded pack owns which tiles, plus the tiles running downloads need.
    private var ledger: TileLedger {
        var ledger = TileLedger()
        for pack in installed where !pack.isBundled {
            ledger.installed[pack.code] = pack.tilesByResolution
        }
        ledger.reserved = reserved
        return ledger
    }

    private func deleteTiles(_ tiles: [String: Set<String>]) {
        for (resolution, names) in tiles {
            for name in names {
                try? FileManager.default.removeItem(at: tilesDir(resolution).appendingPathComponent("\(name).pkt"))
                tileChecksums[resolution]?[name] = nil
            }
        }
    }

    /// Delete tile files no installed pack or running download uses (left by an interrupted download, or by
    /// a pack whose new version dropped tiles).
    private func removeUnusedTiles() {
        var onDisk: [String: Set<String>] = [:]
        for resolution in Self.resolutions {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: tilesDir(resolution).path)) ?? []
            let names = Set(files.filter { $0.hasSuffix(".pkt") }.map { String($0.dropLast(4)) })
            onDisk[resolution] = names
            // Forget checksums of files that are gone.
            tileChecksums[resolution] = tileChecksums[resolution]?.filter { names.contains($0.key) }
        }
        deleteTiles(ledger.orphans(onDisk: onDisk))
        saveChecksums()
    }

    // MARK: - Install / remove

    /// Start downloading a country (no-op while it is already downloading).
    /// - Parameter allowsMobileData: false = Wi-Fi only; the download stops with a message on mobile data.
    func startInstall(_ entry: Catalog.CountryEntry, allowsMobileData: Bool) {
        guard downloadTasks[entry.code] == nil else { return }
        let session = PackDownloader.session(allowsMobileData: allowsMobileData)
        downloadTasks[entry.code] = Task { await install(entry, session: session) }
    }

    /// Stop a running download. Tiles fetched so far are kept for the next try (see `install`).
    func cancelInstall(_ code: String) {
        downloadTasks[code]?.cancel()
    }

    // `install` is split into small functions on purpose: one long async function containing the
    // task group made the Swift 6.2 compiler hang (SIL ClosureLifetimeFixup pass).
    private func install(_ entry: Catalog.CountryEntry, session: URLSession) async {
        defer { downloadTasks[entry.code] = nil }
        guard let baseURL else { return }
        guard downloads[entry.code] == nil || downloads[entry.code]?.error != nil else { return }
        downloads[entry.code] = DownloadState()
        // Keep going for a while when the user switches apps (iOS suspends the app after a few seconds
        // otherwise, and the download fails). If iOS ends that time, the download is cancelled cleanly.
        let code = entry.code
        let background = BackgroundTime(name: "Download \(entry.name)") { [weak self] in self?.cancelInstall(code) }
        defer { background.end() }
        do {
            let pack = try await downloadPack(entry, v1: baseURL.appendingPathComponent("v1"), session: session)
            finishInstall(pack)
        } catch {
            // Tiles fetched so far stay on disk (with their checksums), so trying again right away resumes.
            // Unused, they are removed at the next launch or after the next completed install.
            reserved[entry.code] = nil
            saveChecksums()
            if Self.isCancellation(error) {
                downloads[entry.code] = nil
            } else if PackDownloader.isRefusedForMobileData(error) {
                downloads[entry.code]?.error = PackError.needsWiFi.localizedDescription
            } else {
                downloads[entry.code]?.error = error.localizedDescription
            }
        }
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// Fail early with a clear message instead of running out of space halfway through.
    private func checkFreeSpace(needed: Int) throws {
        let key = URLResourceKey.volumeAvailableCapacityForImportantUsageKey
        guard let free = (try? root.resourceValues(forKeys: [key]))?.volumeAvailableCapacityForImportantUsage else {
            return  // unknown: try anyway
        }
        if Int64(needed + Self.spaceReserve) > free {
            throw PackError.notEnoughSpace(needed: Int64(needed), available: free)
        }
    }

    private func downloadPack(_ entry: Catalog.CountryEntry, v1: URL, session: URLSession) async throws -> InstalledPack {
        let manifestData = try await PackDownloader.fetch(v1.appendingPathComponent(entry.manifest))
        let manifest = try PackManifest.decode(manifestData)
        let tiles = manifest.tiles["90"] ?? []
        let tiles30 = manifest.tiles["30"] ?? []
        // Reserve every tile of the pack, including ones already on disk: removing another pack meanwhile
        // must not delete them.
        reserved[entry.code] = ["90": Set(tiles.map(\.name)), "30": Set(tiles30.map(\.name))]

        let needed90 = await outdatedTiles(tiles, resolution: "90")
        let needed30 = await outdatedTiles(tiles30, resolution: "30")
        var total = manifest.peaks.bytes
        for t in needed90 + needed30 { total += t.bytes }
        downloads[entry.code]?.bytesTotal = total
        // The peak database is unpacked after the download: count its full size too.
        try checkFreeSpace(needed: total + manifest.peaks.uncompressedBytes)

        let code = entry.code
        // 90 m first: enough to show the view; then the high-detail 30 m tiles.
        for (resolution, list) in [("90", needed90), ("30", needed30)] where !list.isEmpty {
            try await PackDownloader.downloadTiles(list, resolution: resolution, from: v1,
                                                   to: tilesDir(resolution), session: session) { [weak self] tile in
                await self?.tileStored(tile, resolution: resolution, pack: code)
            }
        }
        let sqliteBytes = try await PackDownloader.downloadPeakDatabase(
            manifest.peaks, from: v1, to: peaksDir.appendingPathComponent("\(manifest.code).sqlite"), session: session)
        addProgress(code, bytes: manifest.peaks.bytes)

        var bytes = sqliteBytes
        for t in tiles + tiles30 { bytes += t.bytes }
        return InstalledPack(code: manifest.code, name: manifest.name, builtAt: manifest.builtAt,
                             tiles: tiles.map(\.name), peaksFile: "\(manifest.code).sqlite",
                             bytes: bytes, peakCount: manifest.peaks.count, isBundled: false,
                             tiles30: tiles30.isEmpty ? nil : tiles30.map(\.name))
    }

    /// Tiles not on disk in the manifest's version. Hashing unknown files runs off the main actor.
    private func outdatedTiles(_ tiles: [PackManifest.TileFile], resolution: String) async -> [PackManifest.TileFile] {
        guard !tiles.isEmpty else { return [] }
        let dir = tilesDir(resolution)
        let known = tileChecksums[resolution] ?? [:]
        let result = await Task.detached(priority: .userInitiated) {
            PackDownloader.outdatedTiles(tiles, in: dir, known: known)
        }.value
        for (name, sha) in result.hashed { tileChecksums[resolution, default: [:]][name] = sha }
        return result.outdated
    }

    private func tileStored(_ tile: PackManifest.TileFile, resolution: String, pack code: String) {
        tileChecksums[resolution, default: [:]][tile.name] = tile.sha256
        addProgress(code, bytes: tile.bytes)
    }

    private func addProgress(_ code: String, bytes: Int) {
        downloads[code]?.bytesDone += bytes
    }

    private func finishInstall(_ pack: InstalledPack) {
        installed.removeAll { $0.code == pack.code && !$0.isBundled }
        installed.append(pack)
        reserved[pack.code] = nil
        saveInstalled()
        downloads[pack.code] = nil
        removeUnusedTiles()  // e.g. tiles an older version of this pack had
        version += 1
    }

    func remove(_ code: String) {
        guard let pack = installed.first(where: { $0.code == code && !$0.isBundled }) else { return }
        deleteTiles(ledger.removable(after: code))
        installed.removeAll { $0.code == code && !$0.isBundled }
        try? FileManager.default.removeItem(at: peaksDir.appendingPathComponent(pack.peaksFile))
        saveInstalled()
        saveChecksums()
        version += 1
    }

    func clearError(_ code: String) { downloads[code] = nil }

    private func saveInstalled() {
        let list = installed.filter { !$0.isBundled }
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: installedFile, options: .atomic)
        }
    }

    private func saveChecksums() {
        if let data = try? JSONEncoder().encode(tileChecksums) {
            try? data.write(to: checksumsFile, options: .atomic)
        }
    }
}

/// Extra time to finish work after the app goes to the background (`beginBackgroundTask`).
@MainActor
private final class BackgroundTime {
    private var id: UIBackgroundTaskIdentifier = .invalid

    /// - Parameter expired: called when iOS ends the extra time; the assertion is released right after.
    init(name: String, expired: @escaping @MainActor @Sendable () -> Void) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated {
                expired()
                self?.end()
            }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
