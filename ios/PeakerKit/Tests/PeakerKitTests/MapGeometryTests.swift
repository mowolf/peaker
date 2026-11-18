import Foundation
import Testing
@testable import PeakerKit

struct MapGeometryTests {
    let center = GeoCoordinate(latitude: 46, longitude: 7.7)

    @Test func framePointsAndBack() {
        let frame = MapFrame(center: center, exaggeration: 2)
        let p = frame.point(GeoCoordinate(latitude: 46 + 1000 / 111_320.0, longitude: 7.7), height: 500)
        #expect(abs(p.x) < 1e-4 && abs(p.z + 1) < 1e-4 && abs(p.y - 1) < 1e-4)  // 1 km north = −z, 500 m × 2 = 1 km up
        let back = frame.coordinate(x: 2, z: -3)
        let again = frame.point(back, height: 0)
        #expect(abs(again.x - 2) < 1e-4 && abs(again.z + 3) < 1e-4)
    }

    @Test func meshLayoutAndUpwardFaces() {
        // 3×3 grid, 1 km cells, a bump in the middle.
        let grid = HeightGrid(width: 3, height: 3, cellSize: 1000, center: center,
                              heights: [0, 0, 0, 0, 1000, 0, 0, 0, .nan])
        let mesh = TerrainMesh(grid: grid, frame: MapFrame(center: center, exaggeration: 1))
        #expect(mesh.positions.count == 9 && mesh.indices.count == 24)
        #expect(mesh.positions[0] == SIMD3(-1, 0, -1))  // north-west corner
        #expect(mesh.positions[4] == SIMD3(0, 1, 0))
        #expect(mesh.positions[8].y == 0)  // no data: flat
        #expect(mesh.uvs[8] == SIMD2(1, 1))
        #expect(mesh.normals[4] == SIMD3(0, 1, 0))  // top of the bump
        #expect(mesh.normals[3].x < 0)  // west of the bump: the slope faces west
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = mesh.positions[Int(mesh.indices[t])], b = mesh.positions[Int(mesh.indices[t + 1])],
                c = mesh.positions[Int(mesh.indices[t + 2])]
            let e1 = b - a, e2 = c - a
            let ny = e1.z * e2.x - e1.x * e2.z
            #expect(ny > 0)
        }
    }

    @Test func cameraLooksAndProjects() {
        let top = MapCamera(target: .zero, distance: 10, heading: 0, pitch: 90)
        #expect(abs(top.eye.y - 10) < 1e-4)
        // Straight down, north up: a point to the north is above the centre, east is to the right.
        let north = top.project(SIMD3(0, 0, -1), width: 400, height: 800)!
        let east = top.project(SIMD3(1, 0, 0), width: 400, height: 800)!
        #expect(north.y < 400 && abs(north.x - 200) < 1e-3)
        #expect(east.x > 200 && abs(east.y - 400) < 1e-3)
        // Heading 90: looking east; east is now at the top.
        let turned = MapCamera(target: .zero, distance: 10, heading: 90, pitch: 90)
        #expect(turned.project(SIMD3(1, 0, 0), width: 400, height: 800)!.y < 400)
        // Ground point under the centre is the target.
        let tilted = MapCamera(target: SIMD3(3, 0.5, -2), distance: 20, heading: 30, pitch: 40)
        let g = tilted.groundPoint(x: 200, y: 400, width: 400, height: 800, groundHeight: 0.5)!
        #expect(simd_distance(g, tilted.target) < 1e-3)
    }

    @Test func panMovesTheMapWithTheFinger() {
        let cam = MapCamera(target: .zero, distance: 10, heading: 0, pitch: 90)
        // Dragging the finger down shows what is north: the target moves north (−z).
        let moved = cam.panned(dx: 0, dy: 100, width: 400, height: 800)
        #expect(moved.target.z < 0 && abs(moved.target.x) < 1e-4)
        #expect(cam.clamped().pitch == 90 && MapCamera(target: .zero, distance: 500, heading: -30).clamped().heading == 330)
    }

    @Test func ridgesHidePeaksBehindThem() {
        // A west-east ridge (2 km high) across the middle of a 5×5 km grid.
        var heights = [Float](repeating: 0, count: 25)
        for c in 0..<5 { heights[2 * 5 + c] = 2000 }
        let grid = HeightGrid(width: 5, height: 5, cellSize: 1000, center: center, heights: heights)
        let eye = SIMD3<Float>(0, 0.5, 2)  // south, low
        #expect(!grid.isVisible(SIMD3(0, 0.2, -2), from: eye, exaggeration: 1))
        #expect(grid.isVisible(SIMD3(0, 2, 0), from: eye, exaggeration: 1))  // the ridge itself
        #expect(grid.isVisible(SIMD3(0, 0.2, -2), from: SIMD3(0, 8, 2), exaggeration: 1))  // from high above
    }
}

private func simd_distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { ((a - b) * (a - b)).sum().squareRoot() }
