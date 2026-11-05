import CoreLocation
import UIKit
import Foundation
import Observation
import PeakerKit
import SwiftUI

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

    /// Current interface orientation (portrait, or landscape for the wide panorama view).
    private(set) var interfaceOrientation: UIInterfaceOrientation = .portrait

    /// Read the orientation from the window scene (called when the view's size changes).
    func updateInterfaceOrientation() {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let orientation = scene?.effectiveGeometry.interfaceOrientation ?? .portrait
        if orientation != .unknown { interfaceOrientation = orientation }
    }

    /// The screen's top edge in device coordinates, for turning the device attitude into the view.
    private var screenUp: Vec3 {
        switch interfaceOrientation {
        case .landscapeRight: Vec3(1, 0, 0)  // home side right: the device's +x points up
        case .landscapeLeft: Vec3(-1, 0, 0)
        case .portraitUpsideDown: Vec3(0, -1, 0)
        default: Vec3(0, 1, 0)
        }
    }

    /// Rotation for the camera preview so the image is upright in the current orientation.
    var cameraRotationAngle: CGFloat {
        switch interfaceOrientation {
        case .landscapeRight: 0
        case .landscapeLeft: 180
        case .portraitUpsideDown: 270
        default: 90
        }
    }

    /// Direction follows the device (gyro + compass). Off = the user drags the view.
    private(set) var isFollowingDevice = false
    /// Live camera behind the lines (only while following the device).
    private(set) var showsCamera = false

    // Result of the last horizon computation.
    private(set) var observer: GeoCoordinate?
    private(set) var observerGround: Double?
    private(set) var horizon: HorizonResult?
    private(set) var visiblePeaks: [VisiblePeak] = []
    private(set) var isComputing = false
    private(set) var noDataHere = false

    // Manual view direction.
    var touchYaw: Double = 255
    var touchPitch: Double = 3
    /// Zoom, shared by the drawn and the camera view: field of view across the screen's long side (degrees).
    /// In portrait that's the height, in landscape the width, so rotating keeps the same scale.
    /// Starts at the camera's native angle so both views show the same framing; pinch changes it.
    /// While the camera is shown it is limited to what the lens can do (no wider than its native angle).
    private(set) var fieldOfView: Double = 65
    /// The user pinched: don't reset the zoom to the camera's native angle any more.
    var hasZoomed = false

    /// Hand alignment on top of the sensors (compass error); drag while the camera is shown.
    var headingOffset: Double = 0
    var pitchOffset: Double = 0
    var isAlignedByHand: Bool { headingOffset != 0 || pitchOffset != 0 }

    /// Today's sun path with rise/set over the terrain; refreshed with the horizon and at midnight.
    private(set) var sunDay: Sun.Day?
    private var sunDayStart: Date?

    var selectedPeak: VisiblePeak?
    var showDownloads = false

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
    /// Increases with every computation started; only the newest one's result is applied (GPS updates arrive
    /// about once a second, a computation with 30 m terrain can take longer).
    private var computeGeneration = 0

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
        // Configure the camera ahead of time so switching it on is quick; once the real lens angle is
        // known, start with exactly the camera's framing (and keep zoom/camera in sync).
        camera.onConfigured = { [weak self] in
            guard let self else { return }
            if !self.hasZoomed { self.fieldOfView = self.camera.fieldOfView }
            self.setFieldOfView(self.fieldOfView)
        }
        camera.prepare()
        setFollowing(true)  // start with automatic direction when the device has the sensors
        await recompute(force: true)
        await packs.refreshCatalog()
    }

    /// Turn automatic direction (gyro + compass) on or off. Turning it off keeps the current view.
    func setFollowing(_ on: Bool) {
        guard on != isFollowingDevice else { return }
        if on {
            guard motion.isAvailable else { return }
            motion.start()
            isFollowingDevice = true
        } else {
            if let pose = currentDevicePose(size: CGSize(width: 400, height: 800)) {
                touchYaw = pose.azimuth
                touchPitch = max(-45, min(45, pose.pitch))
            }
            setCamera(false)
            isFollowingDevice = false
            motion.stop()
        }
    }

    /// Show or hide the live camera. The camera needs automatic direction, so it turns that on.
    func setCamera(_ on: Bool) {
        guard on != showsCamera else { return }
        if on {
            setFollowing(true)
            guard isFollowingDevice else { return }
            showsCamera = true
            setFieldOfView(fieldOfView)  // clamp to the lens and apply the matching camera zoom
            camera.start()
        } else {
            camera.stop()
            showsCamera = false
        }
    }

    /// Range of fields of view the camera can show: its native angle down to its maximum zoom.
    var cameraFieldOfViewRange: ClosedRange<Double> {
        let base = camera.fieldOfView
        let narrowest = 2 * atan(tan(base * Double.pi / 360) / max(1, camera.maxZoom)) * 180 / Double.pi
        return narrowest...base
    }

    /// Set the zoom (field of view across the screen's long side, degrees) for whichever view is showing.
    func setFieldOfView(_ value: Double) {
        if showsCamera {
            let range = cameraFieldOfViewRange
            fieldOfView = min(max(value, range.lowerBound), range.upperBound)
            let factor = tan(range.upperBound * Double.pi / 360) / tan(fieldOfView * Double.pi / 360)
            camera.setZoom(factor)
        } else {
            fieldOfView = min(max(value, 10), 120)
        }
    }

    /// App became active / inactive: pause or resume camera and motion sensors without changing the modes.
    func setActive(_ active: Bool) {
        if active {
            if isFollowingDevice { motion.start() }
            if showsCamera { camera.start() }
            refreshSun()
        } else {
            camera.stop()
            motion.stop()
        }
    }

    /// Compass button: look north (stops following the device).
    func faceNorth() {
        setFollowing(false)
        touchYaw = 0
    }

    func resetAlignment() {
        headingOffset = 0
        pitchOffset = 0
    }

    // MARK: - Camera pose

    func cameraPose(size: CGSize) -> CameraPose {
        if isFollowingDevice, let pose = currentDevicePose(size: size) {
            return pose
        }
        let focal = CameraPose.focalLength(fieldOfView: fieldOfView, pixelsAcross: max(size.width, size.height))
        return CameraPose(yaw: touchYaw, pitch: touchPitch, focalLength: focal,
                          centerX: size.width / 2, centerY: size.height / 2)
    }

    private func currentDevicePose(size: CGSize) -> CameraPose? {
        guard let q = motion.attitude else { return nil }
        // Same projection for both views. The aspect-filled camera preview puts the sensor's long side (the lens
        // angle, narrowed by the zoom factor set in setFieldOfView) along the screen's long side.
        let focal = CameraPose.focalLength(fieldOfView: fieldOfView, pixelsAcross: max(size.width, size.height))
        return CameraPose(deviceAttitude: q, screenUp: screenUp, focalLength: focal, centerX: size.width / 2, centerY: size.height / 2)
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
        computeGeneration += 1
        let generation = computeGeneration
        isComputing = true

        let snapshot = packs.snapshot()
        let eyeHeight = settings.eyeHeight
        let loader = tileLoader
        let output = await Task.detached(priority: .userInitiated) { () -> ComputeOutput? in
            var horizonSettings = HorizonSettings()
            horizonSettings.maxDistance = maxDistance
            let ids = TileID.covering(center: target, radius: maxDistance)
            // High-detail (30 m) terrain where it matters: within ~35 km of the viewer.
            let near = Set(TileID.covering(center: target, radius: 35_000))
            let tiles = await loader.tiles(ids, near: near, files: snapshot.tileFiles, files30: snapshot.tileFiles30,
                                           peakDatabases: snapshot.peakDatabases, version: packVersion)
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

        // A newer computation started meanwhile: its result wins, don't show this older one.
        guard generation == computeGeneration else { return }
        isComputing = false
        observer = target
        if let output {
            noDataHere = false
            observerGround = output.ground
            horizon = output.horizon
            visiblePeaks = output.visible
            refreshSun(force: true)
        } else {
            noDataHere = true
            observerGround = nil
            horizon = nil
            visiblePeaks = []
        }
    }

    /// Recompute the sun's day when the horizon changed (`force`) or a new day began.
    func refreshSun(force: Bool = false) {
        guard let horizon else { sunDay = nil; return }
        var calendar = Calendar.current
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: Date())
        guard force || sunDayStart != today else { return }
        sunDayStart = today
        sunDay = Sun.day(containing: Date(), at: horizon.observer, timeZone: .current, horizon: horizon,
                         observerHeight: horizon.observerHeight)
    }

    private struct ComputeOutput: Sendable {
        var ground: Double
        var horizon: HorizonResult
        var visible: [VisiblePeak]
    }
}
