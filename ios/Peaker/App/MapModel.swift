import CoreGraphics
import Foundation
import Observation
import PeakerKit
import RealityKit

/// The 3D map's state: camera, the terrain layers and their RealityKit models, and what to highlight.
///
/// Two layers in one scene frame: an overview sized to the zoom (120 km to 1,800 km, from ~700 m overview tiles,
/// with countries without data in black) and, closer than 70 km, a detailed 40 km square on top of it, which
/// cuts a hole into the overview. Both are rebuilt around the view in the background when it moves or zooms
/// far enough; nothing is swapped until the new layer is ready.
@MainActor
@Observable
final class MapModel {
    var camera = MapCamera(target: .zero, distance: 16, heading: 0, pitch: 55)
    private(set) var frame: MapFrame?
    private(set) var detail: MapTerrain?
    private(set) var overview: MapTerrain?
    private(set) var detailEntity: ModelEntity?
    private(set) var overviewEntity: ModelEntity?
    private(set) var isBuilding = false
    /// Peak to highlight (search result, "Show on map").
    var highlightedPeakID: String?
    var filter: MapFilter = .all

    /// The detailed layer is shown (and kept up to date) closer than this (km).
    static let detailDistance: Float = 70
    /// Re-centre the frame when the view gets this far (km) from its centre.
    private static let frameRadius: Float = 1200

    var showsDetail: Bool { camera.distance < Self.detailDistance && detail != nil }

    /// Layers to label and test visibility against, detailed first.
    var layers: [MapTerrain] { [showsDetail ? detail : nil, overview].compactMap { $0 } }

    @ObservationIgnored private let loader = TileLoader()
    @ObservationIgnored private let overviewTiles = OverviewTiles()
    @ObservationIgnored private var outlines: CountryOutlines?
    /// The latest request per level and its build.
    @ObservationIgnored private var requested: [MapTerrain.Level: MapTerrain.Request] = [:]
    @ObservationIgnored private var tasks: [MapTerrain.Level: Task<Void, Never>] = [:]
    @ObservationIgnored private var holeFor: (overview: UUID, detail: UUID?)?
    @ObservationIgnored private var packs: PackSnapshot?

    enum MapFilter: String, CaseIterable, Identifiable {
        case all, peakBook
        var id: String { rawValue }
        var title: String { self == .all ? "All peaks" : "Peak book only" }
    }

    // MARK: - Showing places

    /// Show the area around `coordinate` (opening the map, "Show on map", a search result).
    func focus(on coordinate: GeoCoordinate, distance: Float? = nil, settings: AppSettings, packs: PackSnapshot,
               packVersion: Int) {
        let exaggeration = Float(settings.mapExaggeration)
        if frame == nil || frame?.exaggeration != exaggeration
            || length(frame!.point(coordinate, height: 0)) > Self.frameRadius {
            resetFrame(center: coordinate, exaggeration: exaggeration)
        }
        guard let frame else { return }
        var target = frame.point(coordinate, height: 0)
        target.y = groundHeight(x: target.x, z: target.z) ?? camera.target.y
        camera.target = target
        if let distance { camera.distance = distance }
        camera = camera.clamped()
        update(settings: settings, packs: packs, packVersion: packVersion)
    }

    /// After a gesture or a change of settings or packs: rebuild the layers that no longer fit the view.
    func update(settings: AppSettings, packs: PackSnapshot, packVersion: Int) {
        self.packs = packs
        guard var frame else { return }
        let exaggeration = Float(settings.mapExaggeration)
        let here = frame.coordinate(x: camera.target.x, z: camera.target.z)
        if frame.exaggeration != exaggeration || length(SIMD3(camera.target.x, 0, camera.target.z)) > Self.frameRadius {
            // New frame around the view: the target is its centre; its height follows when a layer is ready.
            resetFrame(center: here, exaggeration: exaggeration)
            frame = self.frame!
            camera.target = SIMD3(0, 0, 0)
        }
        func stale(_ layer: MapTerrain?) -> Bool {
            guard let layer else { return true }
            return layer.style != settings.mapStyle || layer.packVersion != packVersion || layer.frame != frame
        }
        // Overview: about 4.5× the camera distance across (zoomed out the view looks down steeply, so that covers
        // the screen), rebuilt when the view leaves its middle or the zoom changed a lot.
        let wanted = Double(min(1800, max(120, camera.distance * 4.5))) * 1000
        if stale(overview) || overview!.offCentre(camera.target) > 0.25
            || !(0.55...1.8).contains(overview!.size / wanted) {
            build(.init(level: .overview, frame: frame, center: here, size: wanted, style: settings.mapStyle,
                        packVersion: packVersion))
        }
        if camera.distance < Self.detailDistance, stale(detail) || detail!.offCentre(camera.target) > 0.3 {
            build(.init(level: .detail, frame: frame, center: here, size: MapTerrain.detailSize, style: settings.mapStyle,
                        packVersion: packVersion))
        }
        updateHole()
    }

    private func resetFrame(center: GeoCoordinate, exaggeration: Float) {
        for task in tasks.values { task.cancel() }
        tasks = [:]
        requested = [:]
        isBuilding = false
        frame = MapFrame(center: center, exaggeration: exaggeration)
        detail = nil
        overview = nil
        detailEntity = nil
        overviewEntity = nil
        holeFor = nil
    }

    /// Ground height under a scene position from the finest layer that covers it.
    func groundHeight(x: Float, z: Float) -> Float? {
        for layer in [detail, overview].compactMap({ $0 }) {
            if let h = layer.groundHeight(x: x, z: z) { return h }
        }
        return nil
    }

    // MARK: - Building

    /// Start building a layer. A newer request for the same level cancels the older build instead of waiting
    /// behind it, and only the latest request's result is shown: an abandoned or slow build can never block
    /// the map.
    private func build(_ request: MapTerrain.Request) {
        let level = request.level
        if requested[level] == request { return }  // already building (or built) exactly this
        guard let packs else { return }
        requested[level] = request
        tasks[level]?.cancel()
        isBuilding = true
        let loader = loader, overviewTiles = overviewTiles
        tasks[level] = Task {
            let outlines = await self.loadOutlines()
            let work = Task.detached(priority: level == .detail ? .userInitiated : .utility) {
                await MapTerrain.build(request, packs: packs, loader: loader, overview: overviewTiles, outlines: outlines)
            }
            let terrain = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            var entity: ModelEntity?
            if let terrain, !Task.isCancelled {
                entity = try? await Self.makeEntity(terrain, indices: terrain.mesh.indices)
            }
            guard self.requested[level] == request else { return }  // superseded meanwhile
            if let terrain, terrain.frame == self.frame { self.install(terrain, entity: entity) }
            self.tasks[level] = nil
            self.isBuilding = !self.tasks.isEmpty
        }
    }

    private func install(_ terrain: MapTerrain, entity: ModelEntity?) {
        let hadGround = groundHeight(x: camera.target.x, z: camera.target.z) != nil
        switch terrain.level {
        case .detail:
            detail = terrain
            detailEntity = entity
        case .overview:
            overview = terrain
            overviewEntity = entity
            holeFor = nil
        }
        if !hadGround, let h = groundHeight(x: camera.target.x, z: camera.target.z) { camera.target.y = h }
        updateHole()
    }

    /// The overview leaves out the cells under the shown detailed layer.
    private func updateHole() {
        guard let overview, let overviewEntity else { return }
        let detailID = showsDetail ? detail?.id : nil
        if let holeFor, holeFor.overview == overview.id, holeFor.detail == detailID { return }
        holeFor = (overview.id, detailID)
        let indices = (showsDetail ? detail : nil).map {
            overview.mesh.indices(width: overview.grid.width, height: overview.grid.height, excluding: $0.sceneRect)
        } ?? overview.mesh.indices
        if let mesh = try? Self.makeMesh(overview.mesh, indices: indices) {
            overviewEntity.model?.mesh = mesh
        }
    }

    /// Called when the camera distance crosses the detail threshold, to cut or close the overview's hole.
    func cameraDidChange() { updateHole() }

    private func loadOutlines() async -> CountryOutlines? {
        if let outlines { return outlines }
        let loaded = await Task.detached(priority: .utility) { () -> CountryOutlines? in
            guard let url = Bundle.main.url(forResource: "CountryOutlines", withExtension: "bin"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? CountryOutlines(data: data)
        }.value
        outlines = loaded
        return loaded
    }

    // MARK: - RealityKit

    private static func makeMesh(_ mesh: TerrainMesh, indices: [UInt32]) throws -> MeshResource {
        var descriptor = MeshDescriptor(name: "terrain")
        descriptor.positions = MeshBuffers.Positions(mesh.positions)
        descriptor.normals = MeshBuffers.Normals(mesh.normals)
        // RealityKit's texture coordinates start at the bottom; the texture's first row is the north edge.
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(mesh.uvs.map { SIMD2($0.x, 1 - $0.y) })
        descriptor.primitives = .triangles(indices)
        return try MeshResource.generate(from: [descriptor])
    }

    /// The layer as a RealityKit model: the style texture already has light and shade, so it is unlit.
    private static func makeEntity(_ terrain: MapTerrain, indices: [UInt32]) async throws -> ModelEntity {
        let mesh = try makeMesh(terrain.mesh, indices: indices)
        let size = terrain.textureSize
        guard let provider = CGDataProvider(data: Data(terrain.texture) as CFData),
              let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw CocoaError(.coderInvalidValue) }
        let texture = try await TextureResource(image: image, options: .init(semantic: .color,
                                                                              mipmapsMode: .allocateAndGenerateAll))
        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture))
        return ModelEntity(mesh: mesh, materials: [material])
    }
}

private func length(_ v: SIMD3<Float>) -> Float { (v * v).sum().squareRoot() }
