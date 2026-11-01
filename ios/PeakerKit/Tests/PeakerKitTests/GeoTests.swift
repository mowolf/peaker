import Foundation
import Testing
@testable import PeakerKit

let matterhorn = GeoCoordinate(latitude: 45.9763, longitude: 7.6586)
let dufourspitze = GeoCoordinate(latitude: 45.9369, longitude: 7.8668)

@Test func distanceAndBearing() {
    let d = Geo.distance(matterhorn, dufourspitze)
    #expect(d > 16_000 && d < 17_500)
    #expect(abs(Geo.bearing(from: GeoCoordinate(latitude: 0, longitude: 0), to: GeoCoordinate(latitude: 1, longitude: 0))) < 1e-9)
    #expect(abs(Geo.bearing(from: GeoCoordinate(latitude: 0, longitude: 0), to: GeoCoordinate(latitude: 0, longitude: 1)) - 90) < 1e-9)
    let b = Geo.bearing(from: matterhorn, to: dufourspitze)
    #expect(b > 100 && b < 110)  // east-south-east
}

@Test func destinationRoundTrip() {
    let p = Geo.destination(from: matterhorn, bearing: 123, distance: 87_000)
    #expect(abs(Geo.distance(matterhorn, p) - 87_000) < 1)
    #expect(abs(Geo.bearing(from: matterhorn, to: p) - 123) < 0.5)
    let wrap = Geo.destination(from: GeoCoordinate(latitude: 0, longitude: 179.9), bearing: 90, distance: 50_000)
    #expect(wrap.longitude < -179)
}

@Test func curvatureAndAngles() {
    // 100 km: geometric drop 785 m, with refraction 0.13 → 683 m
    #expect(abs(Geo.curvatureDrop(distance: 100_000) - 683) < 2)
    // Same height 100 km away appears below the horizontal
    #expect(Geo.elevationAngle(observerHeight: 3000, targetHeight: 3000, distance: 100_000) < -0.3)
    #expect(Geo.angleDifference(10, 350) == 20)
    #expect(Geo.angleDifference(350, 10) == -20)
    #expect(Geo.normalizedDegrees(-30) == 330)
    #expect(Geo.normalizedLongitude(190) == -170)
}
