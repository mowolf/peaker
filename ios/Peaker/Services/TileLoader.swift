import Foundation
import PeakerKit

/// Decodes tiles from disk and keeps recently used ones in memory (~3 MB each).
actor TileLoader {
    private var cache: [TileID: ElevationTile] = [:]
    private var order: [TileID] = []
    private let capacity = 80

    func tiles(_ ids: [TileID], files: [TileID: URL]) async -> [TileID: ElevationTile] {
        var out: [TileID: ElevationTile] = [:]
        var toLoad: [(TileID, URL)] = []
        for id in ids {
            if let t = cache[id] {
                out[id] = t
                touch(id)
            } else if let url = files[id] {
                toLoad.append((id, url))
            }
        }
        // Decode in parallel: inflate + predictor take ~20 ms per tile.
        let loaded = await withTaskGroup(of: (TileID, ElevationTile?).self) { group in
            for (id, url) in toLoad {
                group.addTask {
                    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return (id, nil) }
                    return (id, try? TileCodec.decode(data))
                }
            }
            var result: [(TileID, ElevationTile?)] = []
            for await r in group { result.append(r) }
            return result
        }
        for (id, tile) in loaded {
            guard let tile else { continue }
            out[id] = tile
            cache[id] = tile
            touch(id)
        }
        while order.count > capacity {
            cache[order.removeFirst()] = nil
        }
        return out
    }

    private func touch(_ id: TileID) {
        order.removeAll { $0 == id }
        order.append(id)
    }

    func clear() {
        cache = [:]
        order = []
    }
}
