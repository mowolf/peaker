import Foundation
import PeakerKit

/// ~700 m versions of the downloaded 90 m tiles (151 × 151 samples instead of 1201 × 1201), for the zoomed-out map.
///
/// Made once per tile from its 90 m file and kept in Caches (45 KB each; the system may clear them, they are
/// remade), and the most recently used ~900 in memory. A whole country then loads in moments instead of
/// decoding hundreds of megabytes.
actor OverviewTiles {
    static let step = 8
    private static let memoryCapacity = 900

    private var memory: [TileID: ElevationTile] = [:]
    private var lastUse: [TileID: Int] = [:]
    private var clock = 0
    private let directory: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("MapOverview", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Overview tiles for those of `ids` that are downloaded (`files`: the 90 m tile files).
    func tiles(_ ids: [TileID], files: [TileID: URL]) async -> [TileID: ElevationTile] {
        var out: [TileID: ElevationTile] = [:]
        var missing: [(TileID, URL)] = []
        for id in ids {
            guard let url = files[id] else { continue }
            if let tile = memory[id] {
                out[id] = tile
                touch(id)
            } else {
                missing.append((id, url))
            }
        }
        let directory = directory
        let window = max(2, ProcessInfo.processInfo.activeProcessorCount)
        await withTaskGroup(of: (TileID, ElevationTile?).self) { group in
            var pending = missing.makeIterator()
            for _ in 0..<window {
                guard let (id, url) = pending.next() else { break }
                group.addTask { (id, Self.load(id, from: url, cache: directory)) }
            }
            while let (id, tile) = await group.next() {
                if let tile {
                    memory[id] = tile
                    touch(id)
                    out[id] = tile
                }
                if let (next, url) = pending.next() {
                    group.addTask { (next, Self.load(next, from: url, cache: directory)) }
                }
            }
        }
        evict()
        return out
    }

    private func touch(_ id: TileID) {
        clock += 1
        lastUse[id] = clock
    }

    /// Least recently used first, down to the capacity.
    private func evict() {
        guard memory.count > Self.memoryCapacity else { return }
        let drop = memory.count - Self.memoryCapacity
        for (id, _) in lastUse.sorted(by: { $0.value < $1.value }).prefix(drop) {
            memory[id] = nil
            lastUse[id] = nil
        }
    }

    /// From the cache file if it matches the source file, else decoded from the 90 m tile and cached.
    nonisolated private static func load(_ id: TileID, from url: URL, cache: URL) -> ElevationTile? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        let modified = Int((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let cacheURL = cache.appendingPathComponent("\(id.name)-s\(step)-\(size)-\(modified).ovr")
        if let data = try? Data(contentsOf: cacheURL), let tile = decode(data, id: id) { return tile }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let full = try? TileCodec.decode(data) else { return nil }
        let small = full.downsampled(step: step)
        try? encode(small).write(to: cacheURL, options: .atomic)
        return small
    }

    /// rows (u16), cols (u16), heights (i16), little-endian.
    nonisolated private static func encode(_ tile: ElevationTile) -> Data {
        var data = Data(capacity: 4 + tile.heights.count * 2)
        for v in [UInt16(tile.rows), UInt16(tile.cols)] { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        tile.heights.withUnsafeBufferPointer { h in
            for v in h { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        }
        return data
    }

    nonisolated private static func decode(_ data: Data, id: TileID) -> ElevationTile? {
        guard data.count >= 4 else { return nil }
        let bytes = [UInt8](data)
        let rows = Int(bytes[0]) | Int(bytes[1]) << 8, cols = Int(bytes[2]) | Int(bytes[3]) << 8
        guard rows >= 2, cols >= 2, bytes.count == 4 + rows * cols * 2 else { return nil }
        var heights = [Int16](repeating: 0, count: rows * cols)
        for i in 0..<(rows * cols) {
            heights[i] = Int16(bitPattern: UInt16(bytes[4 + 2 * i]) | UInt16(bytes[5 + 2 * i]) << 8)
        }
        return ElevationTile(id: id, rows: rows, cols: cols, heights: heights)
    }
}
