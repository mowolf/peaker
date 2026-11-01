import Foundation
import Testing
@testable import PeakerKit

/// N45E007 tile: plain at 500 m with a cone (summit 3000 m, 50 % slope) at 45.48°N 7.5°E.
func coneTerrain(summit: GeoCoordinate = GeoCoordinate(latitude: 45.48, longitude: 7.5), top: Double = 3000,
                 extra: [(GeoCoordinate, Double)] = []) -> TerrainModel {
    let n = 601
    var h = [Int16](repeating: 500, count: n * n)
    let cones = [(summit, top)] + extra
    for r in 0..<n {
        let lat = 46 - Double(r) / Double(n - 1)
        for c in 0..<n {
            let lon = 7 + Double(c) / Double(n - 1)
            var v = 500.0
            for (s, t) in cones {
                let dy = (lat - s.latitude) * 111_320
                let dx = (lon - s.longitude) * 111_320 * cos(radians(lat))
                v = max(v, t - 0.5 * (dx * dx + dy * dy).squareRoot())
            }
            h[r * n + c] = Int16(v)
        }
    }
    let tile = ElevationTile(id: TileID(lat: 45, lon: 7), rows: n, cols: n, heights: h)
    return TerrainModel(covering: [tile.id], tiles: [tile.id: tile]) { _ in true }
}

let observer = GeoCoordinate(latitude: 45.3, longitude: 7.5)

@Test func sampleDistancesGrow() {
    let d = HorizonEngine.sampleDistances(HorizonSettings())
    #expect(d.first == 25 && d.last! <= 250_000 && d.last! > 240_000)
    #expect(zip(d, d.dropFirst()).allSatisfy { $1 > $0 })
    #expect(d.count < 1200)
}

@Test func coneSkylineAndRidge() {
    var settings = HorizonSettings()
    settings.maxDistance = 60_000
    settings.azimuthStep = 0.5
    let result = HorizonEngine.compute(observer: observer, observerHeight: 502, terrain: coneTerrain(), settings: settings)
    let d = Geo.distance(observer, GeoCoordinate(latitude: 45.48, longitude: 7.5))
    let expected = Geo.elevationAngle(observerHeight: 502, targetHeight: 3000, distance: d)
    // Skyline towards the summit ≈ the summit's elevation angle (grid resolution ~170 m).
    #expect(abs(result.skylineAltitude(azimuth: 0) - expected) < 0.4)
    // Looking south over the plain: just below the horizontal.
    #expect(result.skylineAltitude(azimuth: 180) < 0.01 && result.skylineAltitude(azimuth: 180) > -0.2)
    // A skyline ridge spans the cone (± ~12° wide at 20 km for a 5 km radius at the base).
    let skyline = result.ridges.filter { $0.isSkyline && $0.meanDistance > 10_000 && $0.meanDistance < 25_000 }
    #expect(!skyline.isEmpty)
    let azimuths = skyline.flatMap { $0.points.map { Geo.angleDifference($0.azimuth, 0) } }
    #expect((azimuths.min() ?? 0) < -5 && (azimuths.max() ?? 0) > 5)
    // The tile only covers 45–46°N, 7–8°E, so long rays run out of data.
    #expect(result.missingFraction > 0)
}

@Test func peakVisibility() {
    var settings = HorizonSettings()
    settings.maxDistance = 80_000
    settings.azimuthStep = 0.5
    let summit = GeoCoordinate(latitude: 45.48, longitude: 7.5)
    let behindLow = GeoCoordinate(latitude: 45.7, longitude: 7.5)  // 1500 m peak hidden behind the cone
    // 5500 m, 36 km away: rises above the line of sight over the 3000 m cone (20 km away).
    let behindHigh = GeoCoordinate(latitude: 45.62, longitude: 7.5)
    let terrain = coneTerrain(extra: [(behindLow, 1500), (behindHigh, 5500)])
    let result = HorizonEngine.compute(observer: observer, observerHeight: 502, terrain: terrain, settings: settings)
    let peaks = [
        PeakInfo(id: "a", name: "Cone", coordinate: summit, elevation: 3000, importance: 1),
        PeakInfo(id: "b", name: "Hidden", coordinate: behindLow, elevation: 1500, importance: 1),
        PeakInfo(id: "c", name: "Tall", coordinate: behindHigh, elevation: 5500, importance: 1),
        PeakInfo(id: "d", name: "No height", coordinate: summit, elevation: nil, importance: 1),
    ]
    let visible = Set(result.visiblePeaks(peaks).map(\.id))
    #expect(visible == ["a", "c"])
    let cone = result.visiblePeaks(peaks).first { $0.id == "a" }!
    #expect(abs(cone.azimuth) < 0.01 || abs(cone.azimuth - 360) < 0.01)
}

@Test func linkJoinsNeighbouringRays() {
    let distances: [Double] = [1000, 2000, 10_000, 10_500, 50_000]
    typealias P = HorizonEngine.RawRidgePoint
    let rays: [[P]] = (0..<6).map { i in
        [P(sample: 2 + i % 2, tan: 0.05, skyline: false), P(sample: 4, tan: 0.06, skyline: true)]
    } + [[]]
    let ridges = HorizonEngine.link(perRay: rays, distances: distances, step: 1)
    #expect(ridges.count == 2)
    #expect(ridges.allSatisfy { $0.points.count == 6 })
    #expect(ridges.filter(\.isSkyline).count == 1)
}

@Test func performanceFullSweep() {
    // Full default sweep (1800 rays × ~880 samples) over the synthetic tile.
    let start = Date()
    let result = HorizonEngine.compute(observer: observer, observerHeight: 502, terrain: coneTerrain())
    let elapsed = Date().timeIntervalSince(start)
    print("full sweep: \(result.azimuthCount) rays × \(result.distances.count) samples in \(elapsed) s, \(result.ridges.count) ridges")
    #expect(result.azimuthCount == 1800)
}
