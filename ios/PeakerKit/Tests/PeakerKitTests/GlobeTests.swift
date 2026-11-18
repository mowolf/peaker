import Foundation
import Testing
@testable import PeakerKit

struct GlobeTests {
    @Test func meshFacesOutwardAndWrapsTheTexture() {
        let mesh = Globe.mesh(columns: 8, rows: 4)
        #expect(mesh.positions.count == 9 * 5)
        #expect(mesh.uvs.first == SIMD2(0, 0) && mesh.uvs.last == SIMD2(1, 1))
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = mesh.positions[Int(mesh.indices[t])], b = mesh.positions[Int(mesh.indices[t + 1])],
                c = mesh.positions[Int(mesh.indices[t + 2])]
            let e1 = b - a, e2 = c - a
            let n = SIMD3(e1.y * e2.z - e1.z * e2.y, e1.z * e2.x - e1.x * e2.z, e1.x * e2.y - e1.y * e2.x)
            let centre = (a + b + c) / 3
            // Degenerate triangles at the poles have no direction; all others point outwards.
            if (n * n).sum() > 1 { #expect((n * centre).sum() > 0) }
        }
        // Zermatt: north-east of (0, 0) → +x (east), +y (north).
        let z = Globe.point(GeoCoordinate(latitude: 46, longitude: 7.7))
        #expect(z.x > 0 && z.y > 0 && z.z > 0 && abs((z * z).sum().squareRoot() - Globe.radius) < 0.5)
    }

    @Test func cameraLooksDownWithNorthUp() {
        let cam = GlobeCamera(center: GeoCoordinate(latitude: 46, longitude: 8), altitude: 2000)
        let below = Globe.point(cam.center)
        let s = cam.project(below, width: 400, height: 800)!
        #expect(abs(s.x - 200) < 0.01 && abs(s.y - 400) < 0.01)
        // Further north is higher on the screen, further east is to the right.
        let north = cam.project(Globe.point(GeoCoordinate(latitude: 48, longitude: 8)), width: 400, height: 800)!
        let east = cam.project(Globe.point(GeoCoordinate(latitude: 46, longitude: 11)), width: 400, height: 800)!
        #expect(north.y < 400 && abs(north.x - 200) < 1)
        #expect(east.x > 200)
        // The other side of the Earth is hidden.
        #expect(cam.project(Globe.point(GeoCoordinate(latitude: -46, longitude: -172)), width: 400, height: 800) == nil)
    }

    @Test func dragFollowsTheFinger() {
        let cam = GlobeCamera(center: GeoCoordinate(latitude: 46, longitude: 8), altitude: 2000)
        let down = cam.panned(dx: 0, dy: 100, height: 800)
        #expect(down.center.latitude > 46 && abs(down.center.longitude - 8) < 1e-9)  // shows what was north
        let right = cam.panned(dx: 100, dy: 0, height: 800)
        #expect(right.center.longitude < 8)  // shows what was west
        // Turned to face east (east at the top): dragging down moves the view east.
        var turned = cam
        turned.heading = 90
        #expect(turned.panned(dx: 0, dy: 100, height: 800).center.longitude > 8)
        #expect(GlobeCamera(center: GeoCoordinate(latitude: 89, longitude: 190), altitude: 1).clamped()
            == GlobeCamera(center: GeoCoordinate(latitude: 85, longitude: -170), altitude: 300))
    }

    @Test func worldImage() throws {
        let outlines = try CountryOutlines(data: Data(contentsOf: CountryOutlinesTests.shipped))
        let width = 360
        var heights = [Float](repeating: .nan, count: width * width / 2)
        // "Downloaded": one pixel at 46.5° N 7.5° E.
        heights[(90 - 47) * width + (180 + 7)] = 2500
        let px = MapStyle.dusk.renderWorld(width: width, outlines: outlines, heights: heights)
        #expect(px.count == width * width / 2 * 4)
        func color(_ lat: Double, _ lon: Double) -> [UInt8] {
            let i = (Int(90 - lat) * width + Int(180 + lon)) * 4
            return Array(px[i..<(i + 3)])
        }
        #expect(color(10, -30) == [7, 20, 61])  // Atlantic: sea
        #expect(color(20, 20) == [0, 0, 0])  // Sahara (no data): black land
        #expect(color(46.5, 7.5) != [0, 0, 0] && color(46.5, 7.5) != [7, 20, 61])  // the downloaded pixel
    }
}
