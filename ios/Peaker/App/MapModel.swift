import CoreGraphics
import Foundation
import Observation
import PeakerKit
import RealityKit

/// The 3D map's state: camera, the area shown (terrain and its RealityKit model), and what to highlight.
///
/// An area is a 40 km square around a centre. When the view moves out of its middle, the next area is built
/// around the new position in the background; the camera switches over together with the new model, so
/// nothing jumps.
@MainActor
@Observable
final class MapModel {
    var camera = MapCamera(target: .zero, distance: 16, heading: 0, pitch: 55)
    private(set) var terrain: MapTerrain?
    /// The terrain's model, swapped by the scene when it changes.
    private(set) var terrainEntity: ModelEntity?
    private(set) var isBuilding = false
    /// Peak to highlight (search result, "Show on map").
    var highlightedPeakID: String?
    var filter: MapFilter = .all

    @ObservationIgnored private let loader = TileLoader()
    @ObservationIgnored private var building: MapTerrain.Request?
    @ObservationIgnored private var queued: (request: MapTerrain.Request, focus: Focus?)?

    /// Where to put the camera once an area is ready.
    struct Focus {
        var coordinate: GeoCoordinate
        var distance: Float?
    }

    enum MapFilter: String, CaseIterable, Identifiable {
        case all, peakBook
        var id: String { rawValue }
        var title: String { self == .all ? "All peaks" : "Peak book only" }
    }

    // MARK: - Areas

    /// Show the area around `coordinate` (opening the map, "Show on map", a search result).
    func focus(on coordinate: GeoCoordinate, distance: Float? = nil, settings: AppSettings, packs: PackSnapshot,
               packVersion: Int) {
        let request = Self.request(center: coordinate, settings: settings, packVersion: packVersion)
        if let terrain, terrain.matches(request), !terrain.needsRecentre(target: terrain.frame.point(coordinate, height: 0)) {
            moveCamera(to: coordinate, distance: distance, in: terrain)  // already in this area
            return
        }
        build(request, focus: Focus(coordinate: coordinate, distance: distance), packs: packs)
    }

    /// After a gesture, a settings change or new packs: rebuild if the style changed or the view left the middle.
    func refreshIfNeeded(settings: AppSettings, packs: PackSnapshot, packVersion: Int) {
        guard let terrain else { return }
        let target = terrain.frame.coordinate(x: camera.target.x, z: camera.target.z)
        let request = Self.request(center: target, settings: settings, packVersion: packVersion)
        guard !terrain.matches(request) || terrain.needsRecentre(target: camera.target) else { return }
        build(request, focus: Focus(coordinate: target, distance: nil), packs: packs)
    }

    private static func request(center: GeoCoordinate, settings: AppSettings, packVersion: Int) -> MapTerrain.Request {
        MapTerrain.Request(center: center, style: settings.mapStyle, exaggeration: Float(settings.mapExaggeration),
                           packVersion: packVersion)
    }

    private func build(_ request: MapTerrain.Request, focus: Focus?, packs: PackSnapshot) {
        // One build at a time; the latest request waits and replaces any older waiting one.
        guard building == nil else {
            queued = (request, focus)
            return
        }
        building = request
        isBuilding = true
        let loader = loader
        Task {
            let terrain = await Task.detached(priority: .userInitiated) {
                await MapTerrain.build(request, packs: packs, loader: loader)
            }.value
            let entity = try? await Self.makeEntity(terrain)
            self.install(terrain, entity: entity, focus: focus)
            self.building = nil
            if let next = self.queued {
                self.queued = nil
                self.build(next.request, focus: next.focus, packs: packs)
            } else {
                self.isBuilding = false
            }
        }
    }

    /// Switch to a new area: the camera keeps looking at the same place (or the focus), in the new frame.
    private func install(_ new: MapTerrain, entity: ModelEntity?, focus: Focus?) {
        let lookingAt = terrain.map { $0.frame.coordinate(x: camera.target.x, z: camera.target.z) }
        terrain = new
        terrainEntity = entity
        if let focus {
            moveCamera(to: focus.coordinate, distance: focus.distance, in: new)
        } else if let lookingAt {
            moveCamera(to: lookingAt, distance: nil, in: new)
        }
    }

    private func moveCamera(to coordinate: GeoCoordinate, distance: Float?, in terrain: MapTerrain) {
        var p = terrain.frame.point(coordinate, height: 0)
        p.y = terrain.groundHeight(x: p.x, z: p.z)
        camera.target = p
        if let distance { camera.distance = distance }
        camera = camera.clamped()
    }

    // MARK: - RealityKit

    /// The terrain as a RealityKit model: the style texture already has light and shade, so it is unlit.
    private static func makeEntity(_ terrain: MapTerrain) async throws -> ModelEntity {
        var descriptor = MeshDescriptor(name: "terrain")
        descriptor.positions = MeshBuffers.Positions(terrain.mesh.positions)
        descriptor.normals = MeshBuffers.Normals(terrain.mesh.normals)
        // RealityKit's texture coordinates start at the bottom; the texture's first row is the north edge.
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(terrain.mesh.uvs.map { SIMD2($0.x, 1 - $0.y) })
        descriptor.primitives = .triangles(terrain.mesh.indices)
        let mesh = try MeshResource.generate(from: [descriptor])

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

extension MapTerrain {
    /// Built for the same style, exaggeration and installed data as the request (the centre may differ).
    func matches(_ request: Request) -> Bool {
        style == request.style && frame.exaggeration == request.exaggeration && packVersion == request.packVersion
    }
}
