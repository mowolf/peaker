import Foundation
import PeakerKit

/// Smaller versions of the downloaded 90 m tiles for the zoomed-out map and the globe: every `step`-th sample
/// (step 3: ~270 m, 401 × 401; step 6: ~540 m; step 8: ~700 m, 151 × 151).
///
/// Made once per tile and step from its 90 m file and kept in Caches (the system may clear them, they are
/// remade), and the most recently used in memory (up to ~50 MB). A large area then loads in moments instead of
/// decoding hundreds of megabytes.
actor OverviewTiles {
    /// For the globe's world image.
    static let globeStep = 8
    /// Samples kept in memory at most (2 bytes each).
    private static let memoryCapacity = 25_000_000

    private struct Key: Hashable {
        var id: TileID
        var step: Int
    }

    private var memory: [Key: ElevationTile] = [:]
    private var lastUse: [Key: Int] = [:]
    private var samplesInMemory = 0
    private var clock = 0
    private let directory: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("MapOverview", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Smaller tiles for those of `ids` that are downloaded (`files`: the 90 m tile files).
    func tiles(_ ids: [TileID], files: [TileID: URL], step: Int) async -> [TileID: ElevationTile] {
        var out: [TileID: ElevationTile] = [:]
        var missing: [(TileID, URL)] = []
        for id in ids {
            guard let url = files[id] else { continue }
            if let tile = memory[Key(id: id, step: step)] {
                out[id] = tile
                touch(Key(id: id, step: step))
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
                group.addTask { (id, Self.load(id, from: url, step: step, cache: directory)) }
            }
            while let (id, tile) = await group.next() {
                if let tile {
                    let key = Key(id: id, step: step)
                    if memory[key] == nil { samplesInMemory += tile.heights.count }
                    memory[key] = tile
                    touch(key)
                    out[id] = tile
                }
                if let (next, url) = pending.next() {
                    group.addTask { (next, Self.load(next, from: url, step: step, cache: directory)) }
                }
            }
        }
        evict()
        return out
    }

    private func touch(_ key: Key) {
        clock += 1
        lastUse[key] = clock
    }

    /// Least recently used first, down to the capacity.
    private func evict() {
        guard samplesInMemory > Self.memoryCapacity else { return }
        for (key, _) in lastUse.sorted(by: { $0.value < $1.value }) {
            guard samplesInMemory > Self.memoryCapacity else { break }
            samplesInMemory -= memory[key]?.heights.count ?? 0
            memory[key] = nil
            lastUse[key] = nil
        }
    }

    /// From the cache file if it matches the source file, else decoded from the 90 m tile and cached.
    nonisolated private static func load(_ id: TileID, from url: URL, step: Int, cache: URL) -> ElevationTile? {
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
