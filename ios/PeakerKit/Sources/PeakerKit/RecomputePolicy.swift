import Foundation

/// When a new position should trigger a new horizon computation.
///
/// Recompute when the viewpoint moved noticeably, or when the position became much more accurate
/// (the first fix after launch is often a rough ±100–500 m one, and the precise GPS fix that follows
/// may be close by, so movement alone would never correct it).
public struct RecomputePolicy: Sendable {
    /// Movement (metres) that always triggers a recompute.
    public var minMove: Double = 75
    /// Accuracy (metres) below which further improvements don't matter.
    public var goodEnough: Double = 20
    /// New accuracy must be at most this fraction of the old one to count as "much better".
    public var improvementFactor: Double = 0.5

    public init() {}

    /// - Parameters: accuracies are horizontal accuracy radii in metres; nil = fixed viewpoint (exact).
    public func shouldRecompute(from old: GeoCoordinate, oldAccuracy: Double?,
                                to new: GeoCoordinate, newAccuracy: Double?) -> Bool {
        if Geo.distance(old, new) >= minMove { return true }
        guard let oldAccuracy, let newAccuracy else { return false }
        return oldAccuracy > goodEnough && newAccuracy <= oldAccuracy * improvementFactor
    }
}
