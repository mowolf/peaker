import Foundation
import PeakerKit

/// Everything the map shows for one area: terrain mesh, style texture, the heights behind both (for label
/// visibility) and the peaks. Built off the main thread; RealityKit resources are made from it on the main actor.
struct MapTerrain: Sendable {
    /// Changes with every build, so the scene knows when to swap its model.
    let id = UUID()
    let frame: MapFrame
    /// Side of the square area (metres).
    let size: Double
    let grid: HeightGrid
    let mesh: TerrainMesh
    let texture: [UInt8]
    let textureSize: Int
    let peaks: [PeakInfo]
    let style: MapStyleChoice
    /// Installed-packs version the area was built from.
    let packVersion: Int
    /// False when no installed tile covers the area (the map then says so instead of showing a flat plain).
    let hasData: Bool

    struct Request: Equatable, Sendable {
        var center: GeoCoordinate
        var style: MapStyleChoice
        var exaggeration: Float
        var packVersion: Int
    }

    /// Side of the area around the centre (metres). A rebuild is due when the view leaves the middle of it.
    static let areaSize = 40_000.0
    /// Mesh vertices per side (~78 m apart) and texture pixels per side (~20 m, near the 30 m data).
    static let meshSamples = 513
    static let textureSamples = 2048

    static func build(_ request: Request, packs: PackSnapshot, loader: TileLoader) async -> MapTerrain {
        let center = request.center
        let ids = TileID.covering(center: center, radius: areaSize * 0.75)
        let peaks = PeakDatabase.peaks(in: packs.peakDatabases, boxes: GeoBox.covering(ids, margin: TileLoader.summitMargin))
        let tiles = await loader.tiles(ids, near: Set(ids), files: packs.tileFiles, files30: packs.tileFiles30,
                                       peaks: peaks, version: request.packVersion)
        let terrain = TerrainModel(covering: ids, tiles: tiles) { id in packs.landTiles?.contains(id) }
        let heightAt: (Double, Double) -> Float? = { terrain.height(latitude: $0, longitude: $1) }
        let grid = HeightGrid.sample(center: center, size: areaSize, samples: meshSamples, heightAt: heightAt)
        let textureGrid = HeightGrid.sample(center: center, size: areaSize, samples: textureSamples, heightAt: heightAt)
        let frame = MapFrame(center: center, exaggeration: request.exaggeration)
        let half = areaSize / 2
        let inside = peaks.filter { p in
            let pos = frame.point(p.coordinate, height: 0)
            return abs(Double(pos.x) * 1000) < half && abs(Double(pos.z) * 1000) < half
        }
        return MapTerrain(frame: frame, size: areaSize, grid: grid, mesh: TerrainMesh(grid: grid, frame: frame),
                          texture: request.style.style.render(textureGrid, exaggeration: request.exaggeration),
                          textureSize: textureSamples,
                          peaks: inside.sorted { $0.importance > $1.importance }, style: request.style,
                          packVersion: request.packVersion, hasData: !tiles.isEmpty)
    }

    /// Scene position of a peak's summit.
    func point(of peak: PeakInfo) -> SIMD3<Float> {
        if let elevation = peak.elevation { return frame.point(peak.coordinate, height: elevation) }
        var p = frame.point(peak.coordinate, height: 0)
        p.y = groundHeight(x: p.x, z: p.z)
        return p
    }

    /// Ground height (scene units) under a scene position, 0 outside.
    func groundHeight(x: Float, z: Float) -> Float {
        grid.sceneHeight(x: x, z: z, exaggeration: frame.exaggeration) ?? 0
    }

    /// The target has moved far enough from the centre that the next area should be built around it.
    func needsRecentre(target: SIMD3<Float>) -> Bool {
        let limit = Float(size / 1000) * 0.3
        return abs(target.x) > limit || abs(target.z) > limit
    }
}
