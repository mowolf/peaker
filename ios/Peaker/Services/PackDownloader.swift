import CryptoKit
import Foundation
import PeakerKit

enum PackError: LocalizedError {
    case noServer, badResponse(Int), checksumMismatch(String), decompressionFailed
    case notEnoughSpace(needed: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .noServer: "No download server is configured for this build."
        case .badResponse(let code): "The server answered with HTTP \(code)."
        case .checksumMismatch(let file): "\(file) was damaged during download. Please try again."
        case .decompressionFailed: "The peak database could not be unpacked."
        case .notEnoughSpace(let needed, let available):
            "Not enough free space: the download needs \(Self.size(needed)), \(Self.size(available)) are free."
        }
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Networking and file checks for pack downloads. Stateless and off the main actor; `PackStore` keeps the
/// bookkeeping (which pack owns which tiles).
enum PackDownloader {
    static func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw PackError.badResponse(http.statusCode)
        }
        return data
    }

    /// Tiles that must be downloaded: missing on disk, or a different version than the manifest lists.
    /// Files without a recorded checksum (stored by an older app version) are hashed once; their checksums
    /// are returned in `hashed` so the caller can record them.
    static func outdatedTiles(_ tiles: [PackManifest.TileFile], in dir: URL,
                              known: [String: String]) -> (outdated: [PackManifest.TileFile], hashed: [String: String]) {
        var outdated: [PackManifest.TileFile] = []
        var hashed: [String: String] = [:]
        for t in tiles {
            let url = dir.appendingPathComponent("\(t.name).pkt")
            guard FileManager.default.fileExists(atPath: url.path) else {
                outdated.append(t)
                continue
            }
            let local: String?
            if let sha = known[t.name] {
                local = sha
            } else {
                local = (try? Data(contentsOf: url, options: .mappedIfSafe)).map(sha256)
                if let local { hashed[t.name] = local }
            }
            if local != t.sha256 { outdated.append(t) }
        }
        return (outdated, hashed)
    }

    /// Download tiles, 4 at a time, reporting each tile once it is verified and in place.
    static func downloadTiles(_ tiles: [PackManifest.TileFile], resolution: String, from v1: URL, to dir: URL,
                              finished: @escaping @Sendable (PackManifest.TileFile) async -> Void) async throws {
        try await withThrowingTaskGroup(of: PackManifest.TileFile.self) { group in
            var pending = tiles.makeIterator()
            for _ in 0..<4 {
                guard let t = pending.next() else { break }
                group.addTask { try await downloadTile(t, resolution: resolution, from: v1, to: dir) }
            }
            while let t = try await group.next() {
                await finished(t)
                if let t = pending.next() {
                    group.addTask { try await downloadTile(t, resolution: resolution, from: v1, to: dir) }
                }
            }
        }
    }

    /// Download, verify and inflate the peak database. Returns the size of the SQLite file.
    static func downloadPeakDatabase(_ file: PackManifest.PeaksFile, from v1: URL, to destination: URL) async throws -> Int {
        let packed = try await fetch(v1.appendingPathComponent(file.path))
        guard sha256(packed) == file.sha256 else { throw PackError.checksumMismatch("Peak database") }
        guard let inflated = try? (packed as NSData).decompressed(using: .zlib) else {
            throw PackError.decompressionFailed
        }
        let sqlite = inflated as Data
        try sqlite.write(to: destination, options: .atomic)
        return sqlite.count
    }

    private static func downloadTile(_ t: PackManifest.TileFile, resolution: String, from v1: URL,
                                     to dir: URL) async throws -> PackManifest.TileFile {
        try await download(v1.appendingPathComponent("tiles/\(resolution)/\(t.name).pkt"), sha256: t.sha256,
                           to: dir.appendingPathComponent("\(t.name).pkt"))
        return t
    }

    /// Download to a temporary file, verify the checksum, then move into place.
    private static func download(_ url: URL, sha256 expected: String, to destination: URL) async throws {
        let (tmp, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: tmp) }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw PackError.badResponse(http.statusCode)
        }
        let data = try Data(contentsOf: tmp, options: .mappedIfSafe)
        guard sha256(data) == expected else { throw PackError.checksumMismatch(url.lastPathComponent) }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tmp, to: destination)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
