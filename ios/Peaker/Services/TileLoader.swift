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
    ///   - peaks: all peaks on the requested tiles (and a little around them); their official heights are
    ///     burned into the tiles. Must cover whole tiles: loaded tiles are cached and reused.
    ///   - version: installed-packs version; a change (new peaks, new tiles) empties the cache.
    func tiles(_ ids: [TileID], near: Set<TileID>, files: [TileID: URL], files30: [TileID: URL],
               peaks: [PeakInfo], version: Int) async -> [TileID: ElevationTile] {
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
        let summits = toLoad.isEmpty ? [] : peaks.compactMap { p in
            p.elevation.map { SummitBurnIn.Summit(coordinate: p.coordinate, elevation: $0) }
        }
        // Decode in parallel: inflate + predictor take ~20 ms per 90 m tile, ~100–200 ms per 30 m tile.
        // A 30 m tile needs ~55 MB while decoding (inflated bytes + heights), so only two at a time.
        let cores = max(2, ProcessInfo.processInfo.activeProcessorCount)
        let loaded = await Self.load(toLoad.filter { !$0.0.highDetail }, window: cores, summits: summits)
            + Self.load(toLoad.filter { $0.0.highDetail }, window: 2, summits: summits)
        for (key, tile) in loaded {
            guard let tile else { continue }
            out[key.id] = tile
            cache[key] = tile
            touch(key)
        }
        evict()
        return out
    }

    /// Margin (degrees) around a tile for summits to burn in: a summit's cone can reach over the tile edge.
    static let summitMargin = 0.01

    /// Load tiles with at most `window` decodes running at once.
    private static func load(_ items: [(Key, URL)], window: Int,
                             summits: [SummitBurnIn.Summit]) async -> [(Key, ElevationTile?)] {
        await withTaskGroup(of: (Key, ElevationTile?).self) { group in
            var pending = items.makeIterator()
            for _ in 0..<window {
                guard let (key, url) = pending.next() else { break }
                group.addTask { (key, load(key.id, from: url, summits: summits)) }
            }
            var result: [(Key, ElevationTile?)] = []
            for await r in group {
                result.append(r)
                if let (key, url) = pending.next() {
                    group.addTask { (key, load(key.id, from: url, summits: summits)) }
                }
            }
            return result
        }
    }

    private static func load(_ id: TileID, from url: URL, summits: [SummitBurnIn.Summit]) -> ElevationTile? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              var tile = try? TileCodec.decode(data) else { return nil }
        let m = summitMargin
        let south = Double(id.lat) - m, north = Double(id.lat + 1) + m
        let centerLon = Double(id.lon) + 0.5
        let near = summits.filter { s in
            s.coordinate.latitude >= south && s.coordinate.latitude <= north
                && abs(Geo.angleDifference(s.coordinate.longitude, centerLon)) <= 0.5 + m
        }
        SummitBurnIn.apply(near, to: &tile)  // in place: no second copy of the heights
        return tile
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func evict() {
        for highDetail in [true, false] {
            let limit = highDetail ? capacity30 : capacity90
            var count = order.reduce(0) { $0 + ($1.highDetail == highDetail ? 1 : 0) }
            while count > limit, let oldest = order.firstIndex(where: { $0.highDetail == highDetail }) {
                cache[order.remove(at: oldest)] = nil
                count -= 1
            }
        }
    }

    func clear() {
        cache = [:]
        order = []
    }
}
