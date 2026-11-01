import CoreLocation
import Foundation
import Observation
import PeakerKit
import SwiftUI

enum ViewMode: String {
    case camera, touch
}

/// Fixed viewpoints inside the bundled packs, for trying the app anywhere (and as fallback without GPS).
struct Viewpoint: Identifiable, Hashable {
    let id: String
    let name: String
    let region: String
    let coordinate: GeoCoordinate
    /// Direction the touch-mode view starts in (towards the famous view).
    let initialYaw: Double

    static let gornergrat = Viewpoint(id: "gornergrat", name: "Gornergrat", region: "Zermatt, Switzerland",
                                      coordinate: GeoCoordinate(latitude: 45.9832, longitude: 7.7849), initialYaw: 255)
    static let kalaPatthar = Viewpoint(id: "kala-patthar", name: "Kala Patthar", region: "Everest, Nepal",
                                       coordinate: GeoCoordinate(latitude: 27.9958, longitude: 86.8285), initialYaw: 85)
    static let poonHill = Viewpoint(id: "poon-hill", name: "Poon Hill", region: "Annapurna, Nepal",
                                    coordinate: GeoCoordinate(latitude: 28.4005, longitude: 83.6969), initialYaw: 10)
    static let all = [gornergrat, kalaPatthar, poonHill]

    static func with(id: String) -> Viewpoint? { all.first { $0.id == id } }
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
        /// Horizontal accuracy of the GPS fix used (metres); nil for fixed viewpoints.
        var accuracy: Double?
        var maxDistance: Double
        var packVersion: Int
    }
    private let recomputePolicy = RecomputePolicy()
    private var computedFor: ComputeKey?
    private let tileLoader = TileLoader()

    /// The fixed viewpoint in use: the chosen one, or Gornergrat while there's no GPS fix.
    var fixedViewpoint: Viewpoint? {
        if let chosen = Viewpoint.with(id: settings.fixedViewpointID) { return chosen }
        return location.location == nil ? .gornergrat : nil
    }

    var isUsingDemoViewpoint: Bool { fixedViewpoint != nil }

    var viewpointName: String {
        if let v = fixedViewpoint { return v.name }
        guard let c = observer else { return "Locating…" }
        return String(format: "%.4f°, %.4f°", c.latitude, c.longitude)
    }

    /// Accuracy (metres) of the GPS position in use; nil for fixed viewpoints.
    var positionAccuracy: Double? {
        fixedViewpoint == nil ? location.location?.horizontalAccuracy : nil
    }

    /// GPS position is still rough (typical right after launch); the view updates once it improves.
    var isPositionRough: Bool { (positionAccuracy ?? 0) > 50 }

    /// Second line of the location chip.
    var viewpointDetail: String? {
        let height = observerGround.map { settings.elevation($0) }
        if let v = fixedViewpoint {
            let parts: [String?] = [v.region, height]
            return parts.compactMap { $0 }.joined(separator: " · ")
        }
        guard let accuracy = positionAccuracy else { return height }
        let precision = "±" + settings.elevation(accuracy)
        let parts: [String?] = [height, precision]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    /// Get a fresh GPS fix and recompute from it, even if the position barely changed.
    func updatePositionNow() {
        location.refresh()
        Task { await recompute(force: true) }
    }

    func choose(_ viewpoint: Viewpoint?) {
        if let viewpoint {
            settings.fixedViewpointID = viewpoint.id
            touchYaw = viewpoint.initialYaw
            touchPitch = 3
        } else {
            settings.fixedViewpointID = ""
            location.requestAndStart()
        }
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
        if let v = fixedViewpoint { return v.coordinate }
        guard let c = location.location?.coordinate else { return Viewpoint.gornergrat.coordinate }
        return GeoCoordinate(latitude: c.latitude, longitude: c.longitude)
    }

    /// Recompute when the viewpoint moved > 75 m, the view distance changed, or packs changed.
    func recompute(force: Bool = false) async {
        let target = currentViewpoint
        let accuracy = positionAccuracy
        let maxDistance = settings.maxDistanceKm * 1000
        let packVersion = packs.version
        if !force, let last = computedFor, last.maxDistance == maxDistance, last.packVersion == packVersion,
           !recomputePolicy.shouldRecompute(from: last.viewpoint, oldAccuracy: last.accuracy,
                                            to: target, newAccuracy: accuracy) {
            return
        }
        computedFor = ComputeKey(viewpoint: target, accuracy: accuracy, maxDistance: maxDistance,
                                 packVersion: packVersion)
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
