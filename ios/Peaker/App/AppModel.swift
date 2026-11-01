import CoreLocation
import Foundation
import Observation
import PeakerKit
import SwiftUI

enum ViewMode: String {
    case camera, touch
}

/// A fixed viewpoint used when there is no GPS fix (or by choice): Gornergrat above Zermatt,
/// inside the bundled demo pack.
enum DemoViewpoint {
    static let name = "Gornergrat"
    static let coordinate = GeoCoordinate(latitude: 45.9832, longitude: 7.7849)
}

@MainActor
@Observable
final class AppModel {
    let settings = AppSettings()
    let packs = PackStore()
    let location = LocationService()
    let motion = MotionService()
    let camera = CameraService()

    var mode: ViewMode = .touch

    // Result of the last horizon computation.
    private(set) var observer: GeoCoordinate?
    private(set) var observerGround: Double?
    private(set) var horizon: HorizonResult?
    private(set) var visiblePeaks: [VisiblePeak] = []
    private(set) var isComputing = false
    private(set) var noDataHere = false

    // Touch mode: virtual camera.
    var touchYaw: Double = 255
    var touchPitch: Double = 3
    var touchFieldOfView: Double = 55

    // Camera mode: compass calibration.
    var headingOffset: Double = 0
    var pitchOffset: Double = 0
    var isCalibrating = false

    var selectedPeak: VisiblePeak?
    var showDownloads = false
    var showSettings = false

    private struct ComputeKey: Equatable {
        var viewpoint: GeoCoordinate
        var maxDistance: Double
        var packVersion: Int
    }
    private var computedFor: ComputeKey?
    private let tileLoader = TileLoader()

    var isUsingDemoViewpoint: Bool { settings.useDemoViewpoint || location.location == nil }

    var viewpointName: String {
        if isUsingDemoViewpoint { return "\(DemoViewpoint.name) · demo" }
        guard let c = observer else { return "Locating…" }
        return String(format: "%.4f°, %.4f°", c.latitude, c.longitude)
    }

    func start() async {
        location.onUpdate = { [weak self] _ in
            Task { @MainActor in await self?.recompute() }
        }
        location.requestAndStart()
        if camera.isAuthorized {
            setMode(.camera)
        }
        await recompute(force: true)
        await packs.refreshCatalog()
    }

    func setMode(_ newMode: ViewMode) {
        mode = newMode
        isCalibrating = false
        switch newMode {
        case .camera:
            motion.start()
            camera.start()
        case .touch:
            camera.stop()
            motion.stop()
            // Continue in touch mode where the camera was pointing.
            if let pose = currentDevicePose(size: CGSize(width: 400, height: 800)) {
                touchYaw = pose.azimuth
                touchPitch = max(-30, min(30, pose.pitch))
            }
        }
    }

    // MARK: - Camera pose

    func cameraPose(size: CGSize) -> CameraPose {
        if mode == .camera, let pose = currentDevicePose(size: size) {
            return pose
        }
        let focal = CameraPose.focalLength(fieldOfView: touchFieldOfView, pixelsAcross: size.width)
        return CameraPose(yaw: touchYaw, pitch: touchPitch, focalLength: focal,
                          centerX: size.width / 2, centerY: size.height / 2)
    }

    private func currentDevicePose(size: CGSize) -> CameraPose? {
        guard let q = motion.attitude else { return nil }
        // Preview is aspect-filled in portrait: the camera's long side (videoFieldOfView) spans the screen height.
        let focal = CameraPose.focalLength(fieldOfView: camera.fieldOfView, pixelsAcross: size.height)
        return CameraPose(deviceAttitude: q, focalLength: focal, centerX: size.width / 2, centerY: size.height / 2)
            .rotatedYaw(by: headingOffset)
            .pitched(by: pitchOffset)
    }

    // MARK: - Horizon

    var currentViewpoint: GeoCoordinate {
        if isUsingDemoViewpoint { return DemoViewpoint.coordinate }
        let c = location.location!.coordinate
        return GeoCoordinate(latitude: c.latitude, longitude: c.longitude)
    }

    /// Recompute when the viewpoint moved > 75 m, the view distance changed, or packs changed.
    func recompute(force: Bool = false) async {
        let target = currentViewpoint
        let maxDistance = settings.maxDistanceKm * 1000
        let packVersion = packs.version
        if !force, let last = computedFor, last.maxDistance == maxDistance, last.packVersion == packVersion,
           Geo.distance(last.viewpoint, target) < 75 {
            return
        }
        computedFor = ComputeKey(viewpoint: target, maxDistance: maxDistance, packVersion: packVersion)
        isComputing = true
        defer { isComputing = false }

        let snapshot = packs.snapshot()
        let eyeHeight = settings.eyeHeight
        let loader = tileLoader
        let output = await Task.detached(priority: .userInitiated) { () -> ComputeOutput? in
            var horizonSettings = HorizonSettings()
            horizonSettings.maxDistance = maxDistance
            let ids = TileID.covering(center: target, radius: maxDistance)
            let tiles = await loader.tiles(ids, files: snapshot.tileFiles)
            let terrain = TerrainModel(covering: ids, tiles: tiles) { id in
                snapshot.landTiles?.contains(id)
            }
            guard let ground = terrain.height(latitude: target.latitude, longitude: target.longitude) else {
                return nil
            }
            let horizon = HorizonEngine.compute(observer: target, observerHeight: Double(ground) + eyeHeight,
                                                terrain: terrain, settings: horizonSettings)
            let peaks = PeakDatabase.peaks(in: snapshot.peakDatabases, center: target, radius: maxDistance)
            return ComputeOutput(ground: Double(ground), horizon: horizon, visible: horizon.visiblePeaks(peaks))
        }.value

        observer = target
        if let output {
            noDataHere = false
            observerGround = output.ground
            horizon = output.horizon
            visiblePeaks = output.visible
        } else {
            noDataHere = true
            observerGround = nil
            horizon = nil
            visiblePeaks = []
        }
    }

    private struct ComputeOutput: Sendable {
        var ground: Double
        var horizon: HorizonResult
        var visible: [VisiblePeak]
    }
}
