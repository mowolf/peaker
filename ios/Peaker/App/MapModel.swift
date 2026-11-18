import CoreGraphics
import Foundation
import Observation
import PeakerKit
import RealityKit

/// The 3D map's state: camera, the terrain layers and their RealityKit models, and what to highlight.
///
/// Two layers in one scene frame, the detailed one on top, cutting a hole into the other:
/// - detail: 40 km at full resolution (30 m where downloaded), closer than 70 km;
/// - regional: 80–2,000 km (growing with the zoom; the 90 m tiles up to 320 km, smaller versions beyond), with
///   countries without data in black.
/// Zoomed out further the map becomes the globe. Layers are rebuilt around the view in the background when it
/// moves or zooms far enough; nothing is swapped until the new layer is ready.
@MainActor
@Observable
final class MapModel {
    var camera = MapCamera(target: .zero, distance: 16, heading: 0, pitch: 55)
    private(set) var frame: MapFrame?
    /// Built layers and their models, by level.
    private(set) var terrains: [MapTerrain.Level: MapTerrain] = [:]
    private(set) var entities: [MapTerrain.Level: ModelEntity] = [:]
    private(set) var isBuilding = false

    var detail: MapTerrain? { terrains[.detail] }
    var regional: MapTerrain? { terrains[.regional] }
    /// Peak to highlight (search result, "Show on map").
    var highlightedPeakID: String?
    var filter: MapFilter = .all

    /// Flat map (terrain layers) or, zoomed out beyond the flat map's range, the globe.
    enum Mode { case flat, globe }
    private(set) var mode = Mode.flat
    var globe = GlobeCamera(center: GeoCoordinate(latitude: 46, longitude: 8), altitude: 3000)
    private(set) var globeEntity: ModelEntity?

    /// Zooming out past the flat map's farthest distance shows the globe; zooming in below this leaves it.
    static let globeExitAltitude: Float = 700

    /// Each level is shown (and kept up to date) closer than this camera distance (km).
    static func showDistance(_ level: MapTerrain.Level) -> Float {
        switch level {
        case .detail: 70
        case .regional: .infinity
        }
    }
    /// Re-centre the frame when the view gets this far (km) from its centre.
    private static let frameRadius: Float = 1200

    func shows(_ level: MapTerrain.Level) -> Bool {
        camera.distance < Self.showDistance(level) && terrains[level] != nil
    }

    /// Shown layers, finest first: to label, to test visibility against, and to draw.
    var layers: [MapTerrain] { MapTerrain.Level.allCases.filter(shows).compactMap { terrains[$0] } }

    /// Models of the shown layers.
    var sceneEntities: [ModelEntity] { MapTerrain.Level.allCases.filter(shows).compactMap { entities[$0] } }

    @ObservationIgnored private let loader = TileLoader()
    /// Smaller tiles for large regional squares and the globe's world image.
    @ObservationIgnored private let overviewTiles = OverviewTiles()
    @ObservationIgnored private var outlines: CountryOutlines?
    /// The latest request per level and its build.
    @ObservationIgnored private var requested: [MapTerrain.Level: MapTerrain.Request] = [:]
    @ObservationIgnored private var tasks: [MapTerrain.Level: Task<Void, Never>] = [:]
    /// Per layer: the finer layer its current hole was cut for (nil: no hole).
    @ObservationIgnored private var holeFor: [MapTerrain.Level: (layer: UUID, finer: UUID?)] = [:]
    @ObservationIgnored private var packs: PackSnapshot?
    @ObservationIgnored private var globeKey: (style: MapStyleChoice, packVersion: Int)?
    @ObservationIgnored private var globeTask: Task<Void, Never>?

    enum MapFilter: String, CaseIterable, Identifiable {
        case all, peakBook
        var id: String { rawValue }
        var title: String { self == .all ? "All peaks" : "Peak book only" }
    }

    // MARK: - Showing places

    /// Show the area around `coordinate` (opening the map, "Show on map", a search result).
    func focus(on coordinate: GeoCoordinate, distance: Float? = nil, settings: AppSettings, packs: PackSnapshot,
               packVersion: Int) {
        mode = .flat  // a place to look at closely: always on the flat map
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
        // Regional: 3.5× the camera distance across (zoomed out the view looks down steeply, so that covers the
        // screen), 80–2,000 km; rebuilt when the view leaves its middle or the zoom changed a lot.
        let regional = Double(min(2000, max(80, camera.distance * 3.5))) * 1000
        if stale(terrains[.regional]) || terrains[.regional]!.offCentre(camera.target) > 0.25
            || !(0.6...1.6).contains(terrains[.regional]!.size / regional) {
            build(.init(level: .regional, frame: frame, center: here, size: regional, style: settings.mapStyle,
                        packVersion: packVersion))
        }
        if camera.distance < Self.showDistance(.detail), stale(detail) || detail!.offCentre(camera.target) > 0.3 {
            build(.init(level: .detail, frame: frame, center: here, size: MapTerrain.detailSize, style: settings.mapStyle,
                        packVersion: packVersion))
        }
        updateHoles()
    }

    private func resetFrame(center: GeoCoordinate, exaggeration: Float) {
        for task in tasks.values { task.cancel() }
        tasks = [:]
        requested = [:]
        isBuilding = false
        frame = MapFrame(center: center, exaggeration: exaggeration)
        terrains = [:]
        entities = [:]
        holeFor = [:]
    }

    /// Ground height under a scene position from the finest layer that covers it.
    func groundHeight(x: Float, z: Float) -> Float? {
        for layer in MapTerrain.Level.allCases.compactMap({ terrains[$0] }) {
            if let h = layer.groundHeight(x: x, z: z) { return h }
        }
        return nil
    }

    // MARK: - Globe

    /// What the scene's camera does: the flat map's camera, or the globe's.
    var sceneCamera: SceneCamera {
        switch mode {
        case .flat:
            SceneCamera(eye: camera.eye, target: camera.target, up: camera.up, fieldOfView: camera.fieldOfView,
                        near: 0.05, far: 8000)
        case .globe:
            SceneCamera(eye: globe.eye, target: globe.target, up: globe.up, fieldOfView: globe.fieldOfView,
                        near: max(1, globe.altitude * 0.05), far: globe.altitude + 2 * Globe.radius)
        }
    }

    /// Switch to the globe above the place the flat map shows.
    func enterGlobe(settings: AppSettings, packs: PackSnapshot, packVersion: Int) {
        guard mode == .flat else { return }
        let center = frame?.coordinate(x: camera.target.x, z: camera.target.z) ?? globe.center
        globe = GlobeCamera(center: center, altitude: MapCamera.distanceRange.upperBound + 50, heading: camera.heading)
            .clamped()
        mode = .globe
        buildGlobe(style: settings.mapStyle, packs: packs, packVersion: packVersion)
    }

    /// Back to the flat map at the globe's centre.
    func leaveGlobe(settings: AppSettings, packs: PackSnapshot, packVersion: Int) {
        guard mode == .globe else { return }
        mode = .flat
        camera.heading = globe.heading
        focus(on: globe.center, distance: MapCamera.distanceRange.upperBound * 0.9, settings: settings, packs: packs,
              packVersion: packVersion)
    }

    /// The globe's model: built once per style and set of downloads.
    func buildGlobe(style: MapStyleChoice, packs: PackSnapshot, packVersion: Int) {
        if let globeKey, globeKey.style == style, globeKey.packVersion == packVersion, globeEntity != nil || globeTask != nil {
            return
        }
        globeKey = (style, packVersion)
        globeTask?.cancel()
        isBuilding = true
        let overviewTiles = overviewTiles
        globeTask = Task {
            let outlines = await self.loadOutlines()
            let work = Task.detached(priority: .userInitiated) {
                await WorldImage.build(style: style, packs: packs, overview: overviewTiles, outlines: outlines)
            }
            let image = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, let image else { return }
            let entity = try? await Self.makeEntity(mesh: Globe.mesh(), texture: image, width: WorldImage.width,
                                                    height: WorldImage.width / 2, indices: nil)
            guard self.globeKey?.style == style, self.globeKey?.packVersion == packVersion else { return }
            self.globeEntity = entity
            self.globeTask = nil
            self.isBuilding = !self.tasks.isEmpty
        }
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
        terrains[terrain.level] = terrain
        entities[terrain.level] = entity
        holeFor[terrain.level] = nil
        if !hadGround, let h = groundHeight(x: camera.target.x, z: camera.target.z) { camera.target.y = h }
        updateHoles()
    }

    /// Each shown layer leaves out the cells under the next finer shown layer.
    private func updateHoles() {
        let shown = MapTerrain.Level.allCases.filter(shows)
        for (index, level) in shown.enumerated() {
            guard let layer = terrains[level], let entity = entities[level] else { continue }
            let finer = index > 0 ? terrains[shown[index - 1]] : nil
            if let done = holeFor[level], done.layer == layer.id, done.finer == finer?.id { continue }
            holeFor[level] = (layer.id, finer?.id)
            let indices = finer.map {
                layer.mesh.indices(width: layer.grid.width, height: layer.grid.height, excluding: $0.sceneRect)
            } ?? layer.mesh.indices
            if let mesh = try? Self.makeMesh(layer.mesh, indices: indices) {
                entity.model?.mesh = mesh
            }
        }
    }

    /// Called while zooming, to cut or close holes when a layer appears or disappears.
    func cameraDidChange() { updateHoles() }

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
        try await makeEntity(mesh: terrain.mesh, texture: terrain.texture, width: terrain.textureSize,
                             height: terrain.textureSize, indices: indices)
    }

    private static func makeEntity(mesh source: TerrainMesh, texture pixels: [UInt8], width: Int, height: Int,
                                   indices: [UInt32]?) async throws -> ModelEntity {
        let mesh = try makeMesh(source, indices: indices ?? source.indices)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
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

/// Camera placement for the scene (flat map or globe).
struct SceneCamera: Equatable {
    var eye: SIMD3<Float>
    var target: SIMD3<Float>
    var up: SIMD3<Float>
    var fieldOfView: Float
    var near: Float
    var far: Float
}
