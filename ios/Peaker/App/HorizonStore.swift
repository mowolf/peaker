import Foundation
import Observation
import PeakerKit

/// What the viewer shows for the current viewpoint: horizon and ridges, visible peaks, and the sun's day.
///
/// Computes in the background, one computation at a time. While one runs, newer requests are coalesced:
/// only the latest waits and runs next (moving in a car or train would otherwise start a new full sweep every
/// few seconds while older ones are still busy).
@MainActor
@Observable
final class HorizonStore {
    /// Inputs of a computation; a new request is computed only if it differs enough from the last one.
    struct Request: Equatable {
        var viewpoint: GeoCoordinate
        /// Horizontal accuracy of the GPS fix used (metres); nil for fixed viewpoints.
        var accuracy: Double?
        var maxDistance: Double
        var eyeHeight: Double
        var packVersion: Int
    }

    private(set) var observer: GeoCoordinate?
    /// DEM height at the viewpoint (metres).
    private(set) var observerGround: Double?
    private(set) var horizon: HorizonResult?
    private(set) var visiblePeaks: [VisiblePeak] = []
    /// The summit the viewpoint is on, if any (see `PeakInfo.summit(at:ground:in:)`).
    private(set) var summit: PeakInfo?
    private(set) var isComputing = false
    /// No elevation data at the viewpoint (pack not downloaded).
    private(set) var noDataHere = false
    /// Today's sun path with rise/set over the terrain; refreshed with the horizon and at midnight.
    private(set) var sunDay: Sun.Day?
    /// Increases whenever a new result is shown; views key caches of per-result work on it.
    private(set) var resultID = 0

    @ObservationIgnored private var sunDayStart: Date?
    @ObservationIgnored private let policy = RecomputePolicy()
    @ObservationIgnored private var computedFor: Request?
    @ObservationIgnored private let tileLoader = TileLoader()
    /// A computation is running; new requests go to `pending`.
    @ObservationIgnored private var isRunning = false
    /// The latest request that arrived while computing (older ones are dropped).
    @ObservationIgnored private var pending: (request: Request, packs: PackSnapshot)?

    /// Recompute when the viewpoint moved > 75 m or became much more accurate, or any other input changed.
    /// Returns once the request's result is shown, or right away if it was queued behind a running one.
    func update(_ request: Request, packs: @autoclosure () -> PackSnapshot, force: Bool = false) async {
        if !force, let last = computedFor, !needsRecompute(from: last, to: request) { return }
        computedFor = request
        isComputing = true
        if isRunning {
            pending = (request, packs())
            return
        }
        isRunning = true
        var next: (request: Request, packs: PackSnapshot)? = (request, packs())
        while let job = next {
            pending = nil
            let loader = tileLoader
            let output = await Task.detached(priority: .userInitiated) {
                await Self.compute(job.request, packs: job.packs, loader: loader)
            }.value
            // Always newer than what's on screen, so show it even if another request is waiting.
            apply(output, for: job.request)
            next = pending
        }
        isRunning = false
        isComputing = false
    }

    private func apply(_ output: Output?, for request: Request) {
        resultID += 1
        observer = request.viewpoint
        if let output {
            noDataHere = false
            observerGround = output.ground
            horizon = output.horizon
            visiblePeaks = output.visible
            summit = output.summit
            refreshSun(force: true)
        } else {
            noDataHere = true
            observerGround = nil
            horizon = nil
            visiblePeaks = []
            summit = nil
            sunDay = nil
        }
    }

    private func needsRecompute(from last: Request, to new: Request) -> Bool {
        guard last.maxDistance == new.maxDistance, last.eyeHeight == new.eyeHeight,
              last.packVersion == new.packVersion else { return true }
        return policy.shouldRecompute(from: last.viewpoint, oldAccuracy: last.accuracy,
                                      to: new.viewpoint, newAccuracy: new.accuracy)
    }

    /// Recompute the sun's day when the horizon changed (`force`) or a new day began.
    func refreshSun(force: Bool = false) {
        guard let horizon else { sunDay = nil; return }
        let today = Calendar.current.startOfDay(for: Date())
        guard force || sunDayStart != today else { return }
        sunDayStart = today
        sunDay = Sun.day(containing: Date(), at: horizon.observer, timeZone: .current, horizon: horizon,
                         observerHeight: horizon.observerHeight)
    }

    // MARK: - Computation (background)

    private struct Output: Sendable {
        var ground: Double
        var horizon: HorizonResult
        var visible: [VisiblePeak]
        var summit: PeakInfo?
    }


    nonisolated private static func compute(_ request: Request, packs: PackSnapshot, loader: TileLoader) async -> Output? {
        let target = request.viewpoint
        var settings = HorizonSettings()
        settings.maxDistance = request.maxDistance
        let ids = TileID.covering(center: target, radius: request.maxDistance)
        // High-detail (30 m) terrain where it matters: within ~35 km of the viewer.
        let near = Set(TileID.covering(center: target, radius: 35_000))
        // All peaks on the covered tiles in one query per database: their heights are burned into the tiles,
        // and the same list gives the labels (peaks beyond the view distance are dropped by visibility).
        let peaks = PeakDatabase.peaks(in: packs.peakDatabases,
                                       boxes: GeoBox.covering(ids, margin: TileLoader.summitMargin))
        let tiles = await loader.tiles(ids, near: near, files: packs.tileFiles, files30: packs.tileFiles30,
                                       peaks: peaks, version: request.packVersion)
        let terrain = TerrainModel(covering: ids, tiles: tiles) { id in packs.landTiles?.contains(id) }
        guard let ground = terrain.height(latitude: target.latitude, longitude: target.longitude) else { return nil }
        let horizon = HorizonEngine.compute(observer: target, observerHeight: Double(ground) + request.eyeHeight,
                                            terrain: terrain, settings: settings)
        return Output(ground: Double(ground), horizon: horizon, visible: horizon.visiblePeaks(peaks),
                      summit: PeakInfo.summit(at: target, ground: Double(ground), in: peaks))
    }
}
