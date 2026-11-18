import CoreLocation
import UIKit
import Foundation
import Observation
import PeakerKit

@MainActor
@Observable
final class AppModel {
    let settings = AppSettings()
    let packs = PackStore()
    let location = LocationService()
    let motion = MotionService()
    let camera = CameraService()
    let network = NetworkMonitor()
    let countryLocator = CountryLocator()
    /// Horizon, visible peaks and sun for the current viewpoint.
    let horizonStore = HorizonStore()
    /// Climbed peaks, wishlist and diary entries (Markdown files in Documents).
    let peakBook = PeakBook()
    /// The 3D map (kept while closed, so reopening shows the same place at once).
    let map = MapModel()

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

    var selectedPeak: VisiblePeak?
    var showDownloads = false
    var showSettings = false
    var showSearch = false
    var showPeakBook = false
    /// The app's two modes: the 3D map (start screen) and the peak finder (camera / panorama).
    enum Screen { case map, finder }
    var screen = Screen.map

    /// Country of the start view whose data isn't downloaded yet (the map offers the download).
    private(set) var missingCountry: Catalog.CountryEntry?
    @ObservationIgnored private var startViewShown = false

    /// Show a place on the map (a peak: highlighted). Closes sheets, switches to the map.
    func showOnMap(coordinate: GeoCoordinate, peakID: String?) {
        if let peakID { map.highlightedPeakID = peakID }
        selectedPeak = nil
        showPeakBook = false
        showSearch = false
        showSettings = false
        showDownloads = false
        screen = .map
        map.focus(on: coordinate, distance: peakID == nil ? nil : 9, settings: settings, packs: packs.snapshot(),
                  packVersion: packs.version)
    }

    /// The map around your position (or the start view, the first time).
    func openMap() {
        screen = .map
        if let here = currentViewpoint, startViewShown {
            map.focus(on: here, settings: settings, packs: packs.snapshot(), packVersion: packs.version)
        }
    }

    /// The start view: the camera circles your most recently climbed peak (wherever it is). Without climbs, the
    /// highest mountain of the country you are in, once its data is downloaded; without it, the map offers the
    /// download. Waits up to ~10 s for a first position; without one, the globe.
    func showStartView() async {
        guard !startViewShown else { return }
        startViewShown = true
        // The peak book must be read first, or the start view can't know your climbs.
        for _ in 0..<50 where !peakBook.isLoaded {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let snapshot = packs.snapshot()
        if let peak = lastClimbedPeak() {
            let code = await map.countryCode(at: peak.coordinate)
            missingCountry = code.flatMap { c in packs.isDownloaded(c) ? nil : catalogEntry(c) }
            map.startCinematic(around: peak, settings: settings, packs: snapshot, packVersion: packs.version)
            return
        }
        var here = currentViewpoint
        for _ in 0..<50 where here == nil {
            try? await Task.sleep(for: .milliseconds(200))
            here = currentViewpoint
        }
        guard let here else {
            map.showGlobe(center: GeoCoordinate(latitude: 46, longitude: 8), altitude: 6000, settings: settings,
                          packs: snapshot, packVersion: packs.version)
            return
        }
        var code = await map.countryCode(at: here)
        if code == nil { code = await countryLocator.countryCode(at: here) }
        guard let code = code?.uppercased(), packs.isDownloaded(code) else {
            missingCountry = code.flatMap(catalogEntry)
            map.focus(on: here, distance: 300, settings: settings, packs: snapshot, packVersion: packs.version)
            return
        }
        missingCountry = nil
        if let peak = await highestPeak(country: code, box: catalogEntry(code).flatMap(Self.box)) {
            map.startCinematic(around: peak, settings: settings, packs: snapshot, packVersion: packs.version)
        } else {
            map.focus(on: here, settings: settings, packs: snapshot, packVersion: packs.version)
        }
    }

    private func catalogEntry(_ code: String) -> Catalog.CountryEntry? {
        packs.catalog?.countries.first { $0.code.caseInsensitiveCompare(code) == .orderedSame }
    }

    /// The first peak of the most recent climb (from the peak database when installed, else the entry's own).
    private func lastClimbedPeak() -> PeakInfo? {
        let databases = packs.snapshot().peakDatabases
        for stored in peakBook.entries where stored.entry.status == .summited {  // newest first
            for (peak, resolved) in zip(stored.entry.peaks, stored.resolvedIDs) {
                guard let coordinate = peak.coordinate else { continue }
                if let id = resolved ?? peak.id, let info = PeakDatabase.peaks(ids: [id], in: databases)[id] { return info }
                return PeakInfo(id: peak.id ?? "entry:\(stored.fileName)", name: peak.displayName,
                                coordinate: coordinate, elevation: peak.elevation, importance: 1)
            }
        }
        return nil
    }

    /// The country's highest mountain (inside its outline, border summits included).
    private func highestPeak(country: String, box: GeoBox?) async -> PeakInfo? {
        guard let box else { return nil }
        let databases = packs.snapshot().peakDatabases
        let candidates = await Task.detached { PeakDatabase.highestPeaks(in: databases, box: box) }.value
        for peak in candidates {
            if await isIn(country, peak.coordinate) { return peak }
        }
        return nil
    }

    /// In the country, or within ~3 km of it: summits on a border (Everest, Matterhorn, Mont Blanc) belong to
    /// both countries, and the simplified outlines can put the summit point just across.
    private func isIn(_ country: String, _ c: GeoCoordinate) async -> Bool {
        let d = 0.03
        for (dLat, dLon) in [(0.0, 0.0), (d, 0), (-d, 0), (0, d), (0, -d)] {
            let p = GeoCoordinate(latitude: c.latitude + dLat, longitude: c.longitude + dLon / cos(c.latitude * .pi / 180))
            if await map.countryCode(at: p) == country { return true }
        }
        return false
    }

    private static func box(_ entry: Catalog.CountryEntry) -> GeoBox? {
        guard entry.bbox.count == 4 else { return nil }
        return GeoBox(south: entry.bbox[1], north: entry.bbox[3], west: entry.bbox[0], east: entry.bbox[2])
    }

    /// Packs were installed or removed: recompute the view, re-match the peak book, and show the start view's
    /// country once it is downloaded.
    func packsChanged() {
        Task { await recompute() }
        Task { await peakBook.setDatabases(packs.snapshot().peakDatabases) }
        countryDataChanged()
    }

    /// The missing country was downloaded: show the start view again with its data.
    func countryDataChanged() {
        guard let missing = missingCountry, packs.isDownloaded(missing.code) else { return }
        missingCountry = nil
        startViewShown = false
        Task { await showStartView() }
    }

    /// The peak picked in search: highlighted in the view, with a marker at the screen edge while it is off screen.
    private(set) var searchTarget: VisiblePeak?

    /// Highlight a peak found by search. In touch mode the view turns to it; while following the phone the
    /// marker shows which way to turn.
    func find(_ peak: VisiblePeak) {
        searchTarget = peak
        if !isFollowingDevice {
            touchYaw = peak.azimuth
            touchPitch = max(-45, min(45, peak.altitude))
        }
    }

    func clearSearchTarget() { searchTarget = nil }

    /// Peak details → binoculars: switch to the peak finder with the peak as search target, as if found by
    /// search. Uses the peak as seen from here when it is visible (its true direction and height).
    func findInPeakFinder(_ peak: VisiblePeak) {
        selectedPeak = nil
        screen = .finder
        find(horizonStore.visiblePeaks.first { $0.id == peak.id } ?? peak)
    }

    /// After a recompute: the target's new direction, or no target if it is no longer visible from here.
    func refreshSearchTarget() {
        guard let id = searchTarget?.id else { return }
        searchTarget = horizonStore.visiblePeaks.first { $0.id == id }
    }

    /// Degrees to turn right (negative: left) to face the search target.
    var turnToSearchTarget: Double? {
        searchTarget.map { Geo.angleDifference($0.azimuth, heading) }
    }

    /// The fixed viewpoint chosen in Settings, if any (else GPS).
    var fixedViewpoint: Viewpoint? { Viewpoint.with(id: settings.fixedViewpointID) }

    var isUsingDemoViewpoint: Bool { fixedViewpoint != nil }

    /// Top chip: the fixed viewpoint, else the summit you're on, else the coordinates.
    var viewpointName: String {
        if let v = fixedViewpoint { return v.name }
        if let summit = horizonStore.summit { return summit.displayName(language: settings.peakLanguage) }
        guard let c = horizonStore.observer else { return "Locating…" }
        return String(format: "%.4f°, %.4f°", c.latitude, c.longitude)
    }

    /// The viewpoint is a summit (fixed viewpoint or GPS on a peak): the chip shows a mountain.
    var isOnSummit: Bool { fixedViewpoint != nil || horizonStore.summit != nil }

    /// The summit you're standing on (GPS, not a fixed viewpoint), if it isn't recorded as climbed today and the
    /// prompt wasn't closed today: the viewer offers to mark it as climbed.
    var summitToRecord: PeakInfo? {
        guard fixedViewpoint == nil, let summit = horizonStore.summit else { return nil }
        let today = DayDate(Date())
        if settings.dismissedSummitPrompt == "\(summit.id)|\(today)" { return nil }
        let recorded = peakBook.entries(forPeak: summit.id).contains {
            $0.entry.status == .summited && $0.entry.date == today
        }
        return recorded ? nil : summit
    }

    func dismissSummitPrompt() {
        guard let summit = horizonStore.summit else { return }
        settings.dismissedSummitPrompt = "\(summit.id)|\(DayDate(Date()))"
    }

    /// Accuracy (metres) of the GPS position in use; nil for fixed viewpoints.
    var positionAccuracy: Double? {
        fixedViewpoint == nil ? location.location?.horizontalAccuracy : nil
    }

    /// GPS position is still rough (typical right after launch); the view updates once it improves.
    var isPositionRough: Bool { (positionAccuracy ?? 0) > 50 }

    /// Second line of the location chip.
    var viewpointDetail: String? {
        let height = horizonStore.observerGround.map { settings.elevation($0) }
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
            Task { await self?.recompute() }
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
        setFollowing(true)  // the peak finder starts with automatic direction when the device has the sensors
        setActive(screen == .finder)  // sensors run only in the peak finder (the app starts on the map)
        // Catalog and first view at the same time (the catalog only needs the network).
        async let catalog: Void = packs.refreshCatalog()
        async let book: Void = peakBook.setDatabases(packs.snapshot().peakDatabases)
        await recompute(force: true)
        await catalog
        await book
    }

    /// Turn automatic direction (gyro + compass) on or off. Turning it off keeps the current view.
    func setFollowing(_ on: Bool) {
        guard on != isFollowingDevice else { return }
        if on {
            guard motion.isAvailable else { return }
            motion.start()
            isFollowingDevice = true
        } else {
            if let pose = currentDevicePose(size: Self.headingProbeSize) {
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
            horizonStore.refreshSun()
            // Entries may have been edited in the Files app meanwhile.
            if peakBook.isLoaded { Task { await peakBook.reload() } }
        } else {
            camera.stop()
            motion.stop()
        }
    }

    func resetAlignment() {
        headingOffset = 0
        pitchOffset = 0
    }

    // MARK: - Camera pose

    /// Any screen size works for the direction alone (it doesn't depend on the screen's size).
    private static let headingProbeSize = CGSize(width: 400, height: 800)

    /// Compass heading of the view centre (degrees), for the compass ribbon.
    var heading: Double { cameraPose(size: Self.headingProbeSize).azimuth }

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

    /// The fixed viewpoint, else the GPS position; nil until the first fix.
    var currentViewpoint: GeoCoordinate? {
        if let v = fixedViewpoint { return v.coordinate }
        guard let c = location.location?.coordinate else { return nil }
        return GeoCoordinate(latitude: c.latitude, longitude: c.longitude)
    }

    /// Recompute when the viewpoint moved noticeably or any input changed (see `HorizonStore.update`).
    /// Nothing to compute before the first GPS fix (unless a fixed viewpoint is chosen).
    func recompute(force: Bool = false) async {
        guard let viewpoint = currentViewpoint else { return }
        let request = HorizonStore.Request(viewpoint: viewpoint, accuracy: positionAccuracy,
                                           maxDistance: settings.maxDistanceKm * 1000, eyeHeight: settings.eyeHeight,
                                           packVersion: packs.version)
        await horizonStore.update(request, packs: packs.snapshot(), force: force)
    }
}
