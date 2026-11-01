import Foundation

/// Heights around the observer, assembled from tiles into a dense lookup for the horizon sweep.
public struct TerrainModel: Sendable {
    public enum TileStatus: Sendable { case loaded, ocean, missing }

    let latStart: Int, latCount: Int
    let lonStart: Int, lonCount: Int
    let tiles: [ElevationTile?]
    let status: [TileStatus]

    /// - Parameters:
    ///   - tiles: decoded tiles that are available
    ///   - isLand: whether a tile has elevation data at all; tiles that aren't land are sea level.
    ///     Return nil when unknown (no catalog yet): such tiles count as missing.
    public init(covering ids: [TileID], tiles: [TileID: ElevationTile], isLand: (TileID) -> Bool?) {
        let lats = ids.map(\.lat)
        latStart = lats.min() ?? 0
        latCount = (lats.max() ?? 0) - latStart + 1
        // Longitudes may wrap around the antimeridian: store them as offsets from the first west edge.
        let lons = ids.map(\.lon)
        if let minLon = lons.min(), let maxLon = lons.max(), maxLon - minLon > 180 {
            let east = lons.filter { $0 >= 0 }.min() ?? minLon
            lonStart = east
            lonCount = (lons.map { ($0 - east + 360) % 360 }.max() ?? 0) + 1
        } else {
            lonStart = lons.min() ?? 0
            lonCount = (lons.max() ?? 0) - lonStart + 1
        }
        var t = [ElevationTile?](repeating: nil, count: latCount * lonCount)
        var s = [TileStatus](repeating: .missing, count: latCount * lonCount)
        for la in 0..<latCount {
            for lo in 0..<lonCount {
                let id = TileID(lat: latStart + la, lon: Int(Geo.normalizedLongitude(Double(lonStart + lo))))
                let i = la * lonCount + lo
                if let tile = tiles[id] {
                    t[i] = tile
                    s[i] = .loaded
                } else if isLand(id) == false {
                    s[i] = .ocean
                }
            }
        }
        self.tiles = t
        self.status = s
    }

    /// Height in metres, 0 at sea, nil where data is missing.
    @inline(__always)
    public func height(latitude: Double, longitude: Double) -> Float? {
        let fl = floor(latitude)
        let la = Int(fl) - latStart
        guard la >= 0, la < latCount else { return nil }
        var lo = (Int(floor(longitude)) - lonStart) % 360
        if lo < 0 { lo += 360 }
        guard lo < lonCount else { return nil }
        let i = la * lonCount + lo
        if let tile = tiles[i] {
            // Use the tile-local longitude so wrapped tiles sample correctly.
            let localLon = longitude - floor(longitude) + Double(tile.id.lon)
            return tile.height(latitude: latitude, longitude: localLon)
        }
        return status[i] == .ocean ? 0 : nil
    }

    public var loadedTileCount: Int { status.filter { $0 == .loaded }.count }
    public var missingTileCount: Int { status.filter { $0 == .missing }.count }
}
