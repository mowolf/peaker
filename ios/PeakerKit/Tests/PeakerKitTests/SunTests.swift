import Foundation
import Testing
@testable import PeakerKit

private func utc(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

@Test func sunAtSolsticeNoonOnTheEquator() {
    // 21 June, 12:02 UTC (solar noon at 0°E): sun ~66.6° high, due north.
    let p = Sun.position(at: utc("2025-06-21T12:02:00Z"), coordinate: GeoCoordinate(latitude: 0, longitude: 0))
    #expect(abs(p.altitude - 66.56) < 0.3)
    #expect(abs(Geo.angleDifference(p.azimuth, 0)) < 2)
}

@Test func equinoxSunriseAndSunsetOnTheEquator() {
    let day = Sun.day(containing: utc("2025-03-20T12:00:00Z"), at: GeoCoordinate(latitude: 0, longitude: 0),
                      timeZone: TimeZone(identifier: "UTC")!, horizon: nil)
    let rise = try! #require(day.astronomicalSunrise), set = try! #require(day.astronomicalSunset)
    // Refraction and the disc radius make the day a few minutes longer than 12 h.
    #expect(abs(rise.timeIntervalSince(utc("2025-03-20T06:04:00Z"))) < 300)
    #expect(abs(set.timeIntervalSince(utc("2025-03-20T18:11:00Z"))) < 300)
    #expect(day.terrainEvents.map(\.kind) == [.rise, .set])
    #expect(day.samples.count == 289)  // every 5 min incl. both midnights
}

@Test func mountainsDelaySunrise() {
    // Kathmandu, observer at sea level with a 10° high wall all around: sunrise later, sunset earlier.
    let kathmandu = GeoCoordinate(latitude: 27.7, longitude: 85.3)
    let tz = TimeZone(identifier: "Asia/Kathmandu")!
    let flat = Sun.day(containing: utc("2026-11-02T06:00:00Z"), at: kathmandu, timeZone: tz, horizon: nil)
    var settings = HorizonSettings()
    settings.azimuthStep = 1
    let wall = HorizonResult(observer: kathmandu, observerHeight: 0, settings: settings, distances: [1000],
                             azimuthCount: 360, cumulativeMaxTan: [Float](repeating: Float(tan(radians(10))), count: 360),
                             skyline: [Double](repeating: 10, count: 360), ridges: [], missingFraction: 0)
    let walled = Sun.day(containing: utc("2026-11-02T06:00:00Z"), at: kathmandu, timeZone: tz, horizon: wall)
    let flatRise = try! #require(flat.terrainEvents.first), wallRise = try! #require(walled.terrainEvents.first)
    #expect(wallRise.kind == .rise && wallRise.date > flatRise.date.addingTimeInterval(30 * 60))
    #expect(abs(wallRise.position.altitude + Sun.semiDiameter - 10) < 0.05)
    #expect(walled.terrainEvents.last!.date < flat.terrainEvents.last!.date)
}

@Test func polarNightHasNoEvents() {
    let day = Sun.day(containing: utc("2025-12-21T12:00:00Z"), at: GeoCoordinate(latitude: 80, longitude: 15),
                      timeZone: TimeZone(identifier: "UTC")!, horizon: nil)
    #expect(day.terrainEvents.isEmpty && day.astronomicalSunrise == nil)
}

@Test func landscapeScreenUp() {
    // Landscape-right (home side right), back camera facing north: screen top = device +x = up in the world.
    // Device rotated from "upright facing north" by -90° around the viewing axis.
    let q = Quaternion(x: 0.5, y: -0.5, z: -0.5, w: 0.5)  // upright, portrait, facing north
    let portrait = CameraPose(deviceAttitude: q, focalLength: 500, centerX: 0, centerY: 0)
    #expect(abs(portrait.roll) < 1e-9)
    // In portrait the screen top is +y; using +x as "up" for the same attitude means the screen is rolled 90°.
    let sideways = CameraPose(deviceAttitude: q, screenUp: Vec3(1, 0, 0), focalLength: 500, centerX: 0, centerY: 0)
    #expect(abs(abs(sideways.roll) - 90) < 1e-6)
}
