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
    var id: String { code }
}

/// Everything the background horizon computation needs, captured on the main actor.
struct PackSnapshot: Sendable {
    var tileFiles: [TileID: URL]
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
    private var tilesDir: URL { root.appendingPathComponent("tiles/90", isDirectory: true) }
    private var peaksDir: URL { root.appendingPathComponent("peaks", isDirectory: true) }
    private var installedFile: URL { root.appendingPathComponent("installed.json") }
    private var catalogFile: URL { root.appendingPathComponent("catalog.json") }
    private let demoDir = Bundle.main.url(forResource: "DemoPack", withExtension: nil)

    init() {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "PeakerDataURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        baseURL = raw.isEmpty || raw.hasPrefix("$(") ? nil : URL(string: raw)

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("Packs", isDirectory: true)
        try? FileManager.default.createDirectory(at: tilesDir, withIntermediateDirectories: true)
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
        if let demo = loadDemoPack() {
            installed.insert(demo, at: 0)
        }
        if let data = try? Data(contentsOf: catalogFile) {
            catalog = try? Catalog.decode(data)
        }
    }

    private func loadDemoPack() -> InstalledPack? {
        guard let demoDir, let data = try? Data(contentsOf: demoDir.appendingPathComponent("manifest.json")),
              let m = try? PackManifest.decode(data) else { return nil }
        let tiles = m.tiles["90"] ?? []
        return InstalledPack(code: m.code, name: m.name, builtAt: m.builtAt, tiles: tiles.map(\.name),
                             peaksFile: m.peaks.path, bytes: tiles.reduce(m.peaks.bytes) { $0 + $1.bytes },
                             peakCount: m.peaks.count, isBundled: true)
    }

    // MARK: - Lookup

    func snapshot() -> PackSnapshot {
        var files: [TileID: URL] = [:]
        var dbs: [URL] = []
        for pack in installed {
            for name in pack.tiles {
                guard let id = TileID(name: name) else { continue }
                if pack.isBundled, let demoDir {
                    files[id] = files[id] ?? demoDir.appendingPathComponent("tiles/90/\(name).pkt")
                } else {
                    files[id] = tilesDir.appendingPathComponent("\(name).pkt")  // downloaded tiles win
                }
            }
            if pack.isBundled, let demoDir {
                dbs.append(demoDir.appendingPathComponent(pack.peaksFile))
            } else {
                dbs.append(peaksDir.appendingPathComponent(pack.peaksFile))
            }
        }
        return PackSnapshot(tileFiles: files, peakDatabases: dbs, landTiles: catalog?.landTiles())
    }

    func isInstalled(_ code: String) -> Bool { installed.contains { $0.code == code } }

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

    func install(_ entry: Catalog.CountryEntry) async {
        guard let baseURL else { return }
        guard downloads[entry.code] == nil || downloads[entry.code]?.error != nil else { return }
        downloads[entry.code] = DownloadState()
        do {
            let v1 = baseURL.appendingPathComponent("v1")
            let manifest = try PackManifest.decode(try await Self.fetch(v1.appendingPathComponent(entry.manifest)))
            let tiles = manifest.tiles["90"] ?? []
            let missing = tiles.filter { !FileManager.default.fileExists(atPath: tilesDir.appendingPathComponent("\($0.name).pkt").path) }
            downloads[entry.code]?.bytesTotal = missing.reduce(manifest.peaks.bytes) { $0 + $1.bytes }

            // Tiles, 4 at a time.
            let tilesDir = tilesDir
            try await withThrowingTaskGroup(of: Int.self) { group in
                var queue = missing[...]
                func addNext() {
                    guard let t = queue.popFirst() else { return }
                    group.addTask {
                        try await Self.download(v1.appendingPathComponent("tiles/90/\(t.name).pkt"), sha256: t.sha256,
                                                to: tilesDir.appendingPathComponent("\(t.name).pkt"))
                    }
                }
                for _ in 0..<4 { addNext() }
                while let bytes = try await group.next() {
                    downloads[entry.code]?.bytesDone += bytes
                    addNext()
                }
            }

            // Peak DB: verify, inflate, store as <CC>.sqlite.
            let packed = try await Self.fetch(v1.appendingPathComponent(manifest.peaks.path))
            guard Self.sha256(packed) == manifest.peaks.sha256 else { throw PackError.checksumMismatch("Peak database") }
            guard let sqlite = try? (packed as NSData).decompressed(using: .zlib) as Data else {
                throw PackError.decompressionFailed
            }
            let peaksFile = "\(manifest.code).sqlite"
            try sqlite.write(to: peaksDir.appendingPathComponent(peaksFile), options: .atomic)
            downloads[entry.code]?.bytesDone += manifest.peaks.bytes

            let pack = InstalledPack(code: manifest.code, name: manifest.name, builtAt: manifest.builtAt,
                                     tiles: tiles.map(\.name), peaksFile: peaksFile,
                                     bytes: tiles.reduce(sqlite.count) { $0 + $1.bytes },
                                     peakCount: manifest.peaks.count, isBundled: false)
            installed.removeAll { $0.code == pack.code }
            installed.append(pack)
            saveInstalled()
            downloads[entry.code] = nil
            version += 1
        } catch {
            downloads[entry.code]?.error = error.localizedDescription
        }
    }

    func remove(_ code: String) {
        guard let pack = installed.first(where: { $0.code == code }), !pack.isBundled else { return }
        installed.removeAll { $0.code == code }
        let stillUsed = Set(installed.filter { !$0.isBundled }.flatMap(\.tiles))
        for name in pack.tiles where !stillUsed.contains(name) {
            try? FileManager.default.removeItem(at: tilesDir.appendingPathComponent("\(name).pkt"))
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
