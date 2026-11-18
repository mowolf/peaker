import Foundation
import PeakerKit

/// One layer of the map: a square of terrain with its style texture, the heights behind both (for label
/// visibility) and the peaks on it. Built off the main thread; the RealityKit model is made on the main actor.
///
/// Two levels share one scene frame:
/// - `detail`: 40 km around the view from the full-resolution tiles (30 m where downloaded);
/// - `overview`: up to ~1,800 km from ~700 m overview tiles, with the world around the downloaded data:
///   countries without data in black, sea, borders.
struct MapTerrain: Sendable {
    enum Level: Sendable { case detail, overview }

    /// Changes with every build, so the scene knows when to swap its model.
    let id = UUID()
    let level: Level
    let frame: MapFrame
    let center: GeoCoordinate
    /// Side of the square (metres).
    let size: Double
    let grid: HeightGrid
    let mesh: TerrainMesh
    let texture: [UInt8]
    let textureSize: Int
    /// Most important first.
    let peaks: [PeakInfo]
    let style: MapStyleChoice
    let packVersion: Int
    /// Some downloaded terrain lies in the square.
    let hasData: Bool

    struct Request: Equatable, Sendable {
        var level: Level
        var frame: MapFrame
        var center: GeoCoordinate
        var size: Double
        var style: MapStyleChoice
        var packVersion: Int
    }

    static let detailSize = 40_000.0

    static func build(_ request: Request, packs: PackSnapshot, loader: TileLoader, overview: OverviewTiles,
                      outlines: CountryOutlines?) async -> MapTerrain? {
        let center = request.center
        let ids = TileID.covering(center: center, radius: request.size * 0.75)
        let boxes = GeoBox.covering(ids, margin: TileLoader.summitMargin)
        let tiles: [TileID: ElevationTile]
        let peaks: [PeakInfo]
        let meshSamples: Int
        switch request.level {
        case .detail:
            peaks = PeakDatabase.peaks(in: packs.peakDatabases, boxes: boxes)
            tiles = await loader.tiles(ids, near: Set(ids), files: packs.tileFiles, files30: packs.tileFiles30,
                                       peaks: peaks, version: request.packVersion)
            meshSamples = 513
        case .overview:
            peaks = PeakDatabase.peaks(in: packs.peakDatabases, boxes: boxes, limit: 400)
            tiles = await overview.tiles(ids, files: packs.tileFiles)
            meshSamples = 513
        }
        // Stop early when a newer request replaced this one (checked between the expensive steps).
        if Task.isCancelled { return nil }
        let textureSamples = 2048
        // Where no tile is downloaded there is no height: the texture then shows the country (black) or the sea.
        let heightAt: (Double, Double) -> Float? = { lat, lon in
            tiles[TileID.containing(latitude: lat, longitude: lon)]?.height(latitude: lat, longitude: lon)
        }
        let grid = HeightGrid.sample(center: center, size: request.size, samples: meshSamples, heightAt: heightAt)
        let textureGrid = HeightGrid.sample(center: center, size: request.size, samples: textureSamples, heightAt: heightAt)
        if Task.isCancelled { return nil }
        let mask = outlines.map { countryMask($0, for: textureGrid) }
        let style = request.style.style
        let texture = mask.map { style.render(textureGrid, countries: $0, exaggeration: request.frame.exaggeration) }
            ?? style.render(textureGrid, exaggeration: request.frame.exaggeration)
        // The overview lies a little under the detailed layer, so the two never flicker where they overlap.
        let lowered: Float = request.level == .overview ? 0.08 * request.frame.exaggeration : 0
        let half = request.size / 2
        let inside = peaks.filter { p in
            let n = (p.coordinate.latitude - center.latitude) * 111_320
            let e = (p.coordinate.longitude - center.longitude) * 111_320 * cos(center.latitude * .pi / 180)
            return abs(n) < half && abs(e) < half
        }
        return MapTerrain(level: request.level, frame: request.frame, center: center, size: request.size, grid: grid,
                          mesh: TerrainMesh(grid: grid, frame: request.frame, lowered: lowered), texture: texture,
                          textureSize: textureSamples, peaks: inside.sorted { $0.importance > $1.importance },
                          style: request.style, packVersion: request.packVersion, hasData: !tiles.isEmpty)
    }

    /// Country of each texture pixel (see `CountryOutlines.mask`).
    private static func countryMask(_ outlines: CountryOutlines, for grid: HeightGrid) -> [UInt16] {
        let nw = grid.coordinate(row: 0, col: 0)
        let se = grid.coordinate(row: Double(grid.height - 1), col: Double(grid.width - 1))
        return outlines.mask(width: grid.width, height: grid.height,
                             bounds: (west: nw.longitude, south: se.latitude, east: se.longitude, north: nw.latitude)) { lon, lat in
            let p = grid.position(of: GeoCoordinate(latitude: lat, longitude: lon))
            return (p.col + 0.5, p.row + 0.5)
        }
    }

    /// Scene position of a peak's summit.
    func point(of peak: PeakInfo) -> SIMD3<Float> {
        if let elevation = peak.elevation { return frame.point(peak.coordinate, height: elevation) }
        var p = frame.point(peak.coordinate, height: 0)
        p.y = groundHeight(x: p.x, z: p.z) ?? 0
        return p
    }

    /// Ground height (scene units) under a scene position; nil outside this layer.
    func groundHeight(x: Float, z: Float) -> Float? {
        grid.sceneHeight(x: x, z: z, frame: frame)
    }

    /// Scene rectangle (x, z) the layer covers, slightly inset: the hole a detailed layer cuts into the overview.
    var sceneRect: (minX: Float, minZ: Float, maxX: Float, maxZ: Float) {
        let a = frame.point(grid.coordinate(row: 0, col: 0), height: 0)
        let b = frame.point(grid.coordinate(row: Double(grid.height - 1), col: Double(grid.width - 1)), height: 0)
        let inset: Float = 0.3
        return (min(a.x, b.x) + inset, min(a.z, b.z) + inset, max(a.x, b.x) - inset, max(a.z, b.z) - inset)
    }

    /// Distance (km) from the layer's centre to a scene position, as a fraction of its side.
    func offCentre(_ target: SIMD3<Float>) -> Float {
        let c = frame.point(center, height: 0)
        return max(abs(target.x - c.x), abs(target.z - c.z)) / Float(size / 1000)
    }
}
