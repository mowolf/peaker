import Testing
@testable import PeakerKit

@Test func recomputeOnMovementOrBetterAccuracy() {
    let policy = RecomputePolicy()
    let here = GeoCoordinate(latitude: 27.9958, longitude: 86.8285)
    let near = Geo.destination(from: here, bearing: 90, distance: 40)
    let far = Geo.destination(from: here, bearing: 90, distance: 120)

    #expect(policy.shouldRecompute(from: here, oldAccuracy: 5, to: far, newAccuracy: 5))  // moved 120 m
    #expect(!policy.shouldRecompute(from: here, oldAccuracy: 5, to: near, newAccuracy: 5))  // jitter
    // Rough first fix (±300 m), then a precise one 40 m away: recompute.
    #expect(policy.shouldRecompute(from: here, oldAccuracy: 300, to: near, newAccuracy: 8))
    // Small improvement only: no.
    #expect(!policy.shouldRecompute(from: here, oldAccuracy: 300, to: near, newAccuracy: 200))
    // Already precise: further improvement doesn't matter.
    #expect(!policy.shouldRecompute(from: here, oldAccuracy: 15, to: near, newAccuracy: 4))
    // Fixed viewpoints (no accuracy): only movement counts.
    #expect(!policy.shouldRecompute(from: here, oldAccuracy: nil, to: near, newAccuracy: 5))
}
