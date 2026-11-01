import Foundation
import PeakerKit

/// Decodes tiles from disk, raises the summits to their official heights (SummitBurnIn), and keeps
/// recently used tiles in memory (~3 MB each).
actor TileLoader {
    private var cache: [TileID: ElevationTile] = [:]
    private var order: [TileID] = []
    private let capacity = 80
    private var cacheVersion = -1

    /// - Parameter version: installed-packs version; a change (new peaks, new tiles) empties the cache.
    func tiles(_ ids: [TileID], files: [TileID: URL], peakDatabases: [URL], version: Int) async -> [TileID: ElevationTile] {
        if version != cacheVersion {
            cache = [:]
            order = []
            cacheVersion = version
        }
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
                    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                          let tile = try? TileCodec.decode(data) else { return (id, nil) }
                    // Summits from a slightly larger box: a summit's cone can reach over the tile edge.
                    let margin = 0.01
                    let peaks = PeakDatabase.peaks(in: peakDatabases, south: Double(id.lat) - margin,
                                                   north: Double(id.lat + 1) + margin,
                                                   west: Double(id.lon) - margin, east: Double(id.lon + 1) + margin)
                    let summits = peaks.compactMap { p in
                        p.elevation.map { SummitBurnIn.Summit(coordinate: p.coordinate, elevation: $0) }
                    }
                    return (id, SummitBurnIn.apply(to: tile, summits: summits))
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
