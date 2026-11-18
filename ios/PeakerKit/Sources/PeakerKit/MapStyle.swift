import Foundation

/// Heights on a regular grid in local metres around a centre: the input for the map's terrain mesh and texture.
public struct HeightGrid: Sendable {
    public let width: Int
    public let height: Int
    /// Distance between neighbouring samples (metres), the same east-west and north-south.
    public let cellSize: Double
    public let center: GeoCoordinate
    /// Row-major, row 0 in the north. NaN where there is no data.
    public var heights: [Float]

    public init(width: Int, height: Int, cellSize: Double, center: GeoCoordinate, heights: [Float]) {
        precondition(heights.count == width * height)
        self.width = width; self.height = height; self.cellSize = cellSize; self.center = center; self.heights = heights
    }

    /// Sample `heightAt` on a `samples`×`samples` grid covering a square of `size` metres around `center`.
    public static func sample(center: GeoCoordinate, size: Double, samples: Int,
                              heightAt: (Double, Double) -> Float?) -> HeightGrid {
        let cell = size / Double(samples - 1)
        let metresPerDegreeLat = 111_320.0
        let metresPerDegreeLon = 111_320.0 * cos(center.latitude * .pi / 180)
        var heights = [Float](repeating: .nan, count: samples * samples)
        for row in 0..<samples {
            let north = size / 2 - Double(row) * cell
            let lat = center.latitude + north / metresPerDegreeLat
            for col in 0..<samples {
                let east = Double(col) * cell - size / 2
                let lon = center.longitude + east / metresPerDegreeLon
                heights[row * samples + col] = heightAt(lat, lon) ?? .nan
            }
        }
        return HeightGrid(width: samples, height: samples, cellSize: cell, center: center, heights: heights)
    }

    public subscript(row: Int, col: Int) -> Float {
        heights[min(max(row, 0), height - 1) * width + min(max(col, 0), width - 1)]
    }

    /// Grid position (fractional row, col) of a coordinate.
    public func position(of c: GeoCoordinate) -> (row: Double, col: Double) {
        let north = (c.latitude - center.latitude) * 111_320
        let east = (c.longitude - center.longitude) * 111_320 * cos(center.latitude * .pi / 180)
        let half = Double(width - 1) * cellSize / 2
        return ((half - north) / cellSize, (east + half) / cellSize)
    }
}

/// The map's look: colour by height, hill shading and contour lines, drawn into an RGBA image (one pixel per
/// grid sample) that is laid over the terrain mesh.
public struct MapStyle: Sendable {
    public struct Stop: Sendable {
        public var height: Float
        public var color: (r: Float, g: Float, b: Float)
        public init(_ height: Float, _ r: Float, _ g: Float, _ b: Float) { self.height = height; color = (r, g, b) }
    }

    /// Colour by height (between stops: interpolated).
    public var tints: [Stop]
    public var water: (r: Float, g: Float, b: Float)
    public var noData: (r: Float, g: Float, b: Float)
    /// Shading strength: 0 flat, 1 full.
    public var shading: Float
    public var contourInterval: Float
    /// Every n-th contour is drawn stronger.
    public var indexContourEvery: Int
    public var contourColor: (r: Float, g: Float, b: Float)
    public var contourOpacity: Float
    /// Land of countries without downloaded data.
    public var unknownLand: (r: Float, g: Float, b: Float)

    /// Light and classic: green valleys, ochre and grey rock, white snow.
    public static let alpine = MapStyle(
        tints: [Stop(0, 0.66, 0.77, 0.60), Stop(700, 0.72, 0.80, 0.62), Stop(1500, 0.86, 0.84, 0.66),
                Stop(2300, 0.80, 0.72, 0.60), Stop(2900, 0.72, 0.69, 0.67), Stop(3300, 0.93, 0.94, 0.96),
                Stop(4500, 1.00, 1.00, 1.00)],
        water: (0.60, 0.76, 0.88), noData: (0.85, 0.85, 0.85), shading: 0.85,
        contourInterval: 100, indexContourEvery: 5, contourColor: (0.35, 0.25, 0.18), contourOpacity: 0.28,
        unknownLand: (0.22, 0.23, 0.25))

    /// Dark blue like the app icon: the land glows brighter with height, white contours.
    public static let dusk = MapStyle(
        tints: [Stop(0, 0.03, 0.08, 0.22), Stop(1000, 0.05, 0.16, 0.42), Stop(2200, 0.10, 0.30, 0.65),
                Stop(3200, 0.32, 0.55, 0.88), Stop(4500, 0.85, 0.92, 1.00)],
        water: (0.01, 0.03, 0.10), noData: (0.02, 0.03, 0.06), shading: 0.9,
        contourInterval: 100, indexContourEvery: 5, contourColor: (0.85, 0.92, 1.0), contourOpacity: 0.22,
        unknownLand: (0.0, 0.0, 0.0))

    public init(tints: [Stop], water: (r: Float, g: Float, b: Float), noData: (r: Float, g: Float, b: Float),
                shading: Float, contourInterval: Float, indexContourEvery: Int,
                contourColor: (r: Float, g: Float, b: Float), contourOpacity: Float,
                unknownLand: (r: Float, g: Float, b: Float) = (0, 0, 0)) {
        self.tints = tints; self.water = water; self.noData = noData; self.shading = shading
        self.contourInterval = contourInterval; self.indexContourEvery = indexContourEvery
        self.contourColor = contourColor; self.contourOpacity = contourOpacity
        self.unknownLand = unknownLand
    }

    public func tint(_ h: Float) -> (r: Float, g: Float, b: Float) {
        guard let first = tints.first, let last = tints.last else { return noData }
        if h <= first.height { return first.color }
        if h >= last.height { return last.color }
        for (a, b) in zip(tints, tints.dropFirst()) where h <= b.height {
            let t = (h - a.height) / (b.height - a.height)
            return (a.color.r + (b.color.r - a.color.r) * t, a.color.g + (b.color.g - a.color.g) * t,
                    a.color.b + (b.color.b - a.color.b) * t)
        }
        return last.color
    }

    /// Hill shading (0…1, 1 = facing the light) for a slope, lit from the north-west, 45° high (the usual
    /// cartographic convention: shadows fall to the south-east, which reads as relief rather than as valleys).
    public static func shade(dzdx: Float, dzdy: Float) -> Float {
        let azimuth: Float = 315 * .pi / 180, altitude: Float = 45 * .pi / 180
        // dzdx: rise to the east, dzdy: rise to the north.
        let slope = atan(hypot(dzdx, dzdy))
        let aspect = atan2(-dzdx, -dzdy)  // direction the slope faces, clockwise from north
        let value = sin(altitude) * cos(slope) + cos(altitude) * sin(slope) * cos(azimuth - aspect)
        return max(0, min(1, value))
    }

    /// RGBA, 8 bits per channel, one pixel per grid sample.
    public func render(_ grid: HeightGrid, exaggeration: Float = 1.5) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: grid.width * grid.height * 4)
        let cell = Float(grid.cellSize)
        let flatShade = Self.shade(dzdx: 0, dzdy: 0)
        for row in 0..<grid.height {
            for col in 0..<grid.width {
                let h = grid[row, col]
                var c: (r: Float, g: Float, b: Float)
                if h.isNaN {
                    c = noData
                } else if h <= 0.5 {
                    c = water
                } else {
                    c = tint(h)
                    let dzdx = (grid[row, col + 1] - grid[row, col - 1]) / (2 * cell) * exaggeration
                    let dzdy = (grid[row - 1, col] - grid[row + 1, col]) / (2 * cell) * exaggeration
                    if !dzdx.isNaN && !dzdy.isNaN {
                        // Relative to flat ground, so plains keep their tint; shadows darken, lit slopes brighten.
                        let s = Self.shade(dzdx: dzdx, dzdy: dzdy) / flatShade
                        let factor = 1 + (s - 1) * shading * 0.6
                        c = (c.r * factor, c.g * factor, c.b * factor)
                    }
                    if let strength = contour(h, row: row, col: col, grid: grid) {
                        let a = contourOpacity * strength
                        c = (c.r + (contourColor.r - c.r) * a, c.g + (contourColor.g - c.g) * a,
                             c.b + (contourColor.b - c.b) * a)
                    }
                }
                let i = (row * grid.width + col) * 4
                out[i] = UInt8(max(0, min(255, c.r * 255)))
                out[i + 1] = UInt8(max(0, min(255, c.g * 255)))
                out[i + 2] = UInt8(max(0, min(255, c.b * 255)))
            }
        }
        return out
    }

    /// A contour crosses between this sample and its east or south neighbour: line strength (index contours 1,
    /// others 0.55), else nil.
    private func contour(_ h: Float, row: Int, col: Int, grid: HeightGrid) -> Float? {
        let level = (h / contourInterval).rounded(.down)
        for n in [grid[row, col + 1], grid[row + 1, col]] where !n.isNaN {
            let other = (n / contourInterval).rounded(.down)
            guard other != level else { continue }
            let crossed = max(level, other)
            return Int(crossed) % indexContourEvery == 0 ? 1 : 0.55
        }
        return nil
    }
}
