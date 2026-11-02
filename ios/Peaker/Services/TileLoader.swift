import Foundation
import PeakerKit

/// Decodes tiles from disk, raises the summits to their official heights (SummitBurnIn), and keeps
/// recently used tiles in memory.
///
/// Near the viewer the high-detail 30 m tiles are used when downloaded (26 MB in memory each, so only a
/// handful are kept); everywhere else the 90 m tiles (3 MB each).
actor TileLoader {
    private struct Key: Hashable {
        var id: TileID
        var highDetail: Bool
    }

    private var cache: [Key: ElevationTile] = [:]
    private var order: [Key] = []
    private let capacity90 = 80
    private let capacity30 = 6
    private var cacheVersion = -1

    /// - Parameters:
    ///   - near: tiles close enough to the viewer to be worth the 30 m version
    ///   - version: installed-packs version; a change (new peaks, new tiles) empties the cache.
    func tiles(_ ids: [TileID], near: Set<TileID>, files: [TileID: URL], files30: [TileID: URL],
               peakDatabases: [URL], version: Int) async -> [TileID: ElevationTile] {
        if version != cacheVersion {
            cache = [:]
            order = []
            cacheVersion = version
        }
        var out: [TileID: ElevationTile] = [:]
        var toLoad: [(Key, URL)] = []
        for id in ids {
            let wantsDetail = near.contains(id) && files30[id] != nil
            let key = Key(id: id, highDetail: wantsDetail)
            if let t = cache[key] {
                out[id] = t
                touch(key)
            } else if let url = wantsDetail ? files30[id] : files[id] {
                toLoad.append((key, url))
            }
        }
        // Decode in parallel: inflate + predictor take ~20 ms per 90 m tile, ~200 ms per 30 m tile.
        let loaded = await withTaskGroup(of: (Key, ElevationTile?).self) { group in
            for (key, url) in toLoad {
                group.addTask { (key, Self.load(key.id, from: url, peakDatabases: peakDatabases)) }
            }
            var result: [(Key, ElevationTile?)] = []
            for await r in group { result.append(r) }
            return result
        }
        for (key, tile) in loaded {
            guard let tile else { continue }
            out[key.id] = tile
            cache[key] = tile
            touch(key)
        }
        evict()
        return out
    }

    private static func load(_ id: TileID, from url: URL, peakDatabases: [URL]) -> ElevationTile? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let tile = try? TileCodec.decode(data) else { return nil }
        // Summits from a slightly larger box: a summit's cone can reach over the tile edge.
        let margin = 0.01
        let peaks = PeakDatabase.peaks(in: peakDatabases, south: Double(id.lat) - margin,
                                       north: Double(id.lat + 1) + margin,
                                       west: Double(id.lon) - margin, east: Double(id.lon + 1) + margin)
        let summits = peaks.compactMap { p in
            p.elevation.map { SummitBurnIn.Summit(coordinate: p.coordinate, elevation: $0) }
        }
        return SummitBurnIn.apply(to: tile, summits: summits)
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func evict() {
        for highDetail in [true, false] {
            let limit = highDetail ? capacity30 : capacity90
            while order.filter({ $0.highDetail == highDetail }).count > limit,
                  let oldest = order.firstIndex(where: { $0.highDetail == highDetail }) {
                cache[order.remove(at: oldest)] = nil
            }
        }
    }

    func clear() {
        cache = [:]
        order = []
    }
}
