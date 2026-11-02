import CryptoKit
import Foundation
import Observation
import PeakerKit

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

enum PackError: LocalizedError {
    case noServer, badResponse(Int), checksumMismatch(String), decompressionFailed

    var errorDescription: String? {
        switch self {
        case .noServer: "No download server is configured for this build."
        case .badResponse(let code): "The server answered with HTTP \(code)."
        case .checksumMismatch(let file): "\(file) was damaged during download. Please try again."
        case .decompressionFailed: "The peak database could not be unpacked."
        }
    }
}

/// Offline packs: the bundled demo, downloaded countries, the catalog, and downloads.
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

    private let root: URL
    private var tilesDir: URL { tilesDir("90") }
    private func tilesDir(_ resolution: String) -> URL {
        root.appendingPathComponent("tiles/\(resolution)", isDirectory: true)
    }
    private var peaksDir: URL { root.appendingPathComponent("peaks", isDirectory: true) }
    private var installedFile: URL { root.appendingPathComponent("installed.json") }
    private var catalogFile: URL { root.appendingPathComponent("catalog.json") }
    /// Packs shipped inside the app: one folder per pack with manifest.json, tiles/90/*.pkt, peaks.sqlite.
    private let bundledRoot = Bundle.main.url(forResource: "BundledPacks", withExtension: nil)

    init() {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "PeakerDataURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        baseURL = raw.isEmpty || raw.hasPrefix("$(") ? nil : URL(string: raw)

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("Packs", isDirectory: true)
        try? FileManager.default.createDirectory(at: tilesDir("90"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: tilesDir("30"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: peaksDir, withIntermediateDirectories: true)
        // Re-downloadable data: keep it out of iCloud backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var rootURL = root
        try? rootURL.setResourceValues(values)

        if let data = try? Data(contentsOf: installedFile),
           let list = try? JSONDecoder().decode([InstalledPack].self, from: data) {
            installed = list.filter { !$0.isBundled }
        }
        installed.insert(contentsOf: loadBundledPacks(), at: 0)
        if let data = try? Data(contentsOf: catalogFile) {
            catalog = try? Catalog.decode(data)
        }
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
                    files[id] = tilesDir.appendingPathComponent("\(name).pkt")  // downloaded tiles win
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
            let data = try await Self.fetch(baseURL.appendingPathComponent("v1/catalog.json"))
            catalog = try Catalog.decode(data)
            catalogError = nil
            try? data.write(to: catalogFile, options: .atomic)
            version += 1  // land tiles may have changed
        } catch {
            catalogError = error.localizedDescription
        }
    }

    // MARK: - Install / remove

    // `install` is split into small functions on purpose: one long async function containing the
    // task group made the Swift 6.2 compiler hang (SIL ClosureLifetimeFixup pass).
    func install(_ entry: Catalog.CountryEntry) async {
        guard let baseURL else { return }
        guard downloads[entry.code] == nil || downloads[entry.code]?.error != nil else { return }
        downloads[entry.code] = DownloadState()
        do {
            let pack = try await downloadPack(entry, v1: baseURL.appendingPathComponent("v1"))
            finishInstall(pack)
        } catch {
            downloads[entry.code]?.error = error.localizedDescription
        }
    }

    private func downloadPack(_ entry: Catalog.CountryEntry, v1: URL) async throws -> InstalledPack {
        let manifestData = try await Self.fetch(v1.appendingPathComponent(entry.manifest))
        let manifest = try PackManifest.decode(manifestData)
        let tiles = manifest.tiles["90"] ?? []
        let tiles30 = manifest.tiles["30"] ?? []
        let missing = missingTiles(tiles, resolution: "90")
        let missing30 = missingTiles(tiles30, resolution: "30")
        var total = manifest.peaks.bytes
        for t in missing + missing30 { total += t.bytes }
        downloads[entry.code]?.bytesTotal = total

        let code = entry.code
        // 90 m first: enough to show the view; then the high-detail 30 m tiles.
        for (resolution, list) in [("90", missing), ("30", missing30)] where !list.isEmpty {
            try await Self.downloadTiles(list, resolution: resolution, from: v1, to: tilesDir(resolution)) { [weak self] bytes in
                await self?.addProgress(code, bytes: bytes)
            }
        }
        let sqliteBytes = try await Self.downloadPeakDatabase(manifest.peaks, from: v1,
                                                              to: peaksDir.appendingPathComponent("\(manifest.code).sqlite"))
        addProgress(code, bytes: manifest.peaks.bytes)

        var bytes = sqliteBytes
        for t in tiles + tiles30 { bytes += t.bytes }
        return InstalledPack(code: manifest.code, name: manifest.name, builtAt: manifest.builtAt,
                             tiles: tiles.map(\.name), peaksFile: "\(manifest.code).sqlite",
                             bytes: bytes, peakCount: manifest.peaks.count, isBundled: false,
                             tiles30: tiles30.isEmpty ? nil : tiles30.map(\.name))
    }

    private func missingTiles(_ tiles: [PackManifest.TileFile], resolution: String) -> [PackManifest.TileFile] {
        let dir = tilesDir(resolution)
        return tiles.filter { t in
            !FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(t.name).pkt").path)
        }
    }

    private func addProgress(_ code: String, bytes: Int) {
        downloads[code]?.bytesDone += bytes
    }

    private func finishInstall(_ pack: InstalledPack) {
        installed.removeAll { $0.code == pack.code && !$0.isBundled }
        installed.append(pack)
        saveInstalled()
        downloads[pack.code] = nil
        version += 1
    }

    func remove(_ code: String) {
        guard let pack = installed.first(where: { $0.code == code && !$0.isBundled }) else { return }
        installed.removeAll { $0.code == code && !$0.isBundled }
        let others = installed.filter { !$0.isBundled }
        let stillUsed = Set(others.flatMap(\.tiles)), stillUsed30 = Set(others.flatMap { $0.tiles30 ?? [] })
        for name in pack.tiles where !stillUsed.contains(name) {
            try? FileManager.default.removeItem(at: tilesDir("90").appendingPathComponent("\(name).pkt"))
        }
        for name in pack.tiles30 ?? [] where !stillUsed30.contains(name) {
            try? FileManager.default.removeItem(at: tilesDir("30").appendingPathComponent("\(name).pkt"))
        }
        try? FileManager.default.removeItem(at: peaksDir.appendingPathComponent(pack.peaksFile))
        saveInstalled()
        version += 1
    }

    func clearError(_ code: String) { downloads[code] = nil }

    private func saveInstalled() {
        let list = installed.filter { !$0.isBundled }
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: installedFile, options: .atomic)
        }
    }

    // MARK: - Networking

    nonisolated private static func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw PackError.badResponse(http.statusCode)
        }
        return data
    }

    /// Download tiles, 4 at a time, reporting each finished tile's size.
    nonisolated private static func downloadTiles(_ tiles: [PackManifest.TileFile], resolution: String,
                                                  from v1: URL, to dir: URL,
                                                  progress: @escaping @Sendable (Int) async -> Void) async throws {
        try await withThrowingTaskGroup(of: Int.self) { group in
            var pending = tiles.makeIterator()
            for _ in 0..<4 {
                guard let t = pending.next() else { break }
                group.addTask { try await downloadTile(t, resolution: resolution, from: v1, to: dir) }
            }
            while let bytes = try await group.next() {
                await progress(bytes)
                if let t = pending.next() {
                    group.addTask { try await downloadTile(t, resolution: resolution, from: v1, to: dir) }
                }
            }
        }
    }

    /// Download, verify and inflate the peak database. Returns the size of the SQLite file.
    nonisolated private static func downloadPeakDatabase(_ file: PackManifest.PeaksFile, from v1: URL,
                                                         to destination: URL) async throws -> Int {
        let packed = try await fetch(v1.appendingPathComponent(file.path))
        guard sha256(packed) == file.sha256 else { throw PackError.checksumMismatch("Peak database") }
        guard let inflated = try? (packed as NSData).decompressed(using: .zlib) else {
            throw PackError.decompressionFailed
        }
        let sqlite = inflated as Data
        try sqlite.write(to: destination, options: .atomic)
        return sqlite.count
    }

    nonisolated private static func downloadTile(_ t: PackManifest.TileFile, resolution: String, from v1: URL,
                                                 to dir: URL) async throws -> Int {
        try await download(v1.appendingPathComponent("tiles/\(resolution)/\(t.name).pkt"), sha256: t.sha256,
                           to: dir.appendingPathComponent("\(t.name).pkt"))
    }

    /// Download to a temporary file, verify the checksum, then move into place. Returns the byte count.
    nonisolated private static func download(_ url: URL, sha256 expected: String, to destination: URL) async throws -> Int {
        let (tmp, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: tmp) }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw PackError.badResponse(http.statusCode)
        }
        let data = try Data(contentsOf: tmp, options: .mappedIfSafe)
        guard sha256(data) == expected else { throw PackError.checksumMismatch(url.lastPathComponent) }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tmp, to: destination)
        return data.count
    }

    nonisolated private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
