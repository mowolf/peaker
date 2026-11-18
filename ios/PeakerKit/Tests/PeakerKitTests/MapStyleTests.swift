import Foundation
import Testing
@testable import PeakerKit

struct MapStyleTests {
    @Test func tintsInterpolateAndClamp() {
        let style = MapStyle(tints: [.init(0, 0, 0, 0), .init(1000, 1, 0.5, 0)], water: (0, 0, 1), noData: (0.5, 0.5, 0.5),
                             shading: 0, contourInterval: 100, indexContourEvery: 5, contourColor: (0, 0, 0), contourOpacity: 0)
        #expect(style.tint(500) == (0.5, 0.25, 0))
        #expect(style.tint(-10) == (0, 0, 0))
        #expect(style.tint(9000) == (1, 0.5, 0))
    }

    @Test func slopesFacingTheLightAreBrighter() {
        // Light from the north-west: a slope rising to the south-east faces it.
        let lit = MapStyle.shade(dzdx: 0.5, dzdy: -0.5)  // rises east and south
        let dark = MapStyle.shade(dzdx: -0.5, dzdy: 0.5)
        let flat = MapStyle.shade(dzdx: 0, dzdy: 0)
        #expect(dark < flat)
        #expect(dark < lit)
    }

    @Test func renderMarksWaterNoDataAndContours() {
        // 4×1: sea, 150 m, 250 m (a 200 m contour between), no data.
        let grid = HeightGrid(width: 4, height: 1, cellSize: 30, center: GeoCoordinate(latitude: 46, longitude: 7.7),
                              heights: [0, 150, 250, .nan])
        var style = MapStyle.alpine
        style.shading = 0
        let px = style.render(grid)
        #expect(px.count == 16)
        #expect(Array(px[0..<3]) == [153, 193, 224])  // water (0.60, 0.76, 0.88)
        #expect(Array(px[12..<15]) == [216, 216, 216])  // no data
        let plain = style.tint(150)
        #expect(Float(px[4]) < plain.r * 255)  // contour drawn darker over the 150 m sample
    }

    @Test func gridPositions() {
        let c = GeoCoordinate(latitude: 46, longitude: 7.7)
        let grid = HeightGrid.sample(center: c, size: 10_000, samples: 11) { _, _ in 100 }
        #expect(grid.cellSize == 1000)
        let p = grid.position(of: c)
        #expect(abs(p.row - 5) < 1e-6 && abs(p.col - 5) < 1e-6)
        let north = grid.position(of: GeoCoordinate(latitude: 46 + 5000 / 111_320.0, longitude: 7.7))
        #expect(abs(north.row) < 1e-6)
    }
}
