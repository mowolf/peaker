import Foundation

/// Country outlines for the map (Natural Earth, simplified; written by the pipeline's `outlines` command).
public struct CountryOutlines: Sendable {
    public struct Country: Sendable {
        public var code: String
        /// Outer rings and holes alike; filled with the even-odd rule. Points are (longitude, latitude).
        public var rings: [[SIMD2<Float>]]
        public var west: Float, south: Float, east: Float, north: Float
    }

    public var countries: [Country]

    public enum DecodingError: Error { case badHeader, truncated }

    public init(countries: [Country]) { self.countries = countries }

    public init(data: Data) throws {
        let bytes = [UInt8](data)
        var pos = 0
        func u16() throws -> Int {
            guard pos + 2 <= bytes.count else { throw DecodingError.truncated }
            defer { pos += 2 }
            return Int(bytes[pos]) | Int(bytes[pos + 1]) << 8
        }
        func u32() throws -> Int {
            guard pos + 4 <= bytes.count else { throw DecodingError.truncated }
            defer { pos += 4 }
            return Int(bytes[pos]) | Int(bytes[pos + 1]) << 8 | Int(bytes[pos + 2]) << 16 | Int(bytes[pos + 3]) << 24
        }
        func f32() throws -> Float { Float(bitPattern: UInt32(try u32())) }
        guard bytes.count >= 8, Array(bytes[0..<4]) == Array("PKOL".utf8) else { throw DecodingError.badHeader }
        pos = 4
        guard try u16() == 1 else { throw DecodingError.badHeader }
        let count = try u16()
        var countries: [Country] = []
        countries.reserveCapacity(count)
        for _ in 0..<count {
            guard pos + 2 <= bytes.count else { throw DecodingError.truncated }
            let code = String(decoding: bytes[pos..<(pos + 2)], as: UTF8.self)
            pos += 2
            var rings: [[SIMD2<Float>]] = []
            var w = Float.infinity, s = Float.infinity, e = -Float.infinity, n = -Float.infinity
            for _ in 0..<(try u32()) {
                let points = try u32()
                var ring: [SIMD2<Float>] = []
                ring.reserveCapacity(points)
                for _ in 0..<points {
                    let p = SIMD2(try f32(), try f32())
                    ring.append(p)
                    w = min(w, p.x); e = max(e, p.x); s = min(s, p.y); n = max(n, p.y)
                }
                rings.append(ring)
            }
            countries.append(Country(code: code, rings: rings, west: w, south: s, east: e, north: n))
        }
        self.countries = countries
    }

    /// Which country each pixel of a `width`×`height` image lies in: index into `countries` + 1, 0 for sea.
    /// `pixel` maps a (longitude, latitude) to fractional pixel coordinates (x right, y down); the image covers
    /// `bounds` (west, south, east, north) so countries outside it are skipped.
    public func mask(width: Int, height: Int, bounds: (west: Double, south: Double, east: Double, north: Double),
                     pixel: (Double, Double) -> (x: Double, y: Double)) -> [UInt16] {
        var mask = [UInt16](repeating: 0, count: width * height)
        for (index, country) in countries.enumerated() {
            guard Double(country.east) >= bounds.west, Double(country.west) <= bounds.east,
                  Double(country.north) >= bounds.south, Double(country.south) <= bounds.north else { continue }
            let rings = country.rings.map { ring in ring.map { p in pixel(Double(p.x), Double(p.y)) } }
            Self.fill(rings, value: UInt16(index + 1), into: &mask, width: width, height: height)
        }
        return mask
    }

    /// Even-odd scanline fill at pixel centres.
    static func fill(_ rings: [[(x: Double, y: Double)]], value: UInt16, into mask: inout [UInt16], width: Int, height: Int) {
        var minY = Double.infinity, maxY = -Double.infinity
        for ring in rings { for p in ring { minY = min(minY, p.y); maxY = max(maxY, p.y) } }
        guard maxY >= 0, minY < Double(height) else { return }
        let firstRow = max(0, Int((minY - 0.5).rounded(.up))), lastRow = min(height - 1, Int((maxY - 0.5).rounded(.down)))
        guard firstRow <= lastRow else { return }
        var crossings: [Double] = []
        for row in firstRow...lastRow {
            let y = Double(row) + 0.5
            crossings.removeAll(keepingCapacity: true)
            for ring in rings where ring.count >= 3 {
                var a = ring[ring.count - 1]
                for b in ring {
                    if (a.y <= y) != (b.y <= y) {
                        crossings.append(a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x))
                    }
                    a = b
                }
            }
            crossings.sort()
            var i = 0
            while i + 1 < crossings.count {
                let from = max(0, Int((crossings[i] - 0.5).rounded(.up)))
                let to = min(width - 1, Int((crossings[i + 1] - 0.5).rounded(.down)))
                if from <= to {
                    let base = row * width
                    for col in from...to { mask[base + col] = value }
                }
                i += 2
            }
        }
    }
}

public extension MapStyle {
    /// Like `render`, plus the world around the data: land of countries without downloaded data in
    /// `unknownLand`, sea in `water`, and borders where neighbouring pixels belong to different countries.
    /// `mask` comes from `CountryOutlines.mask` for the same pixels as `grid`.
    func render(_ grid: HeightGrid, countries mask: [UInt16], exaggeration: Float = 1.5) -> [UInt8] {
        var out = render(grid, exaggeration: exaggeration)
        let w = grid.width, h = grid.height
        let land = unknownLand
        let border = contourColor
        for row in 0..<h {
            for col in 0..<w {
                let i = row * w + col
                let country = mask[i]
                var c: (r: Float, g: Float, b: Float)?
                if grid.heights[i].isNaN {
                    c = country == 0 ? water : land
                }
                // A border between two countries (coasts are clear enough from the colours).
                let right = col + 1 < w ? mask[i + 1] : country
                let below = row + 1 < h ? mask[i + w] : country
                if country != 0, (right != 0 && right != country) || (below != 0 && below != country) {
                    let base = c ?? (Float(out[i * 4]) / 255, Float(out[i * 4 + 1]) / 255, Float(out[i * 4 + 2]) / 255)
                    let a: Float = 0.7
                    c = (base.r + (border.r - base.r) * a, base.g + (border.g - base.g) * a, base.b + (border.b - base.b) * a)
                }
                if let c {
                    out[i * 4] = UInt8(max(0, min(255, c.r * 255)))
                    out[i * 4 + 1] = UInt8(max(0, min(255, c.g * 255)))
                    out[i * 4 + 2] = UInt8(max(0, min(255, c.b * 255)))
                }
            }
        }
        return out
    }
}

public extension ElevationTile {
    /// Every `step`-th sample (with the last row and column): an overview of the tile, e.g. 1201 → 101 samples
    /// (~1 km) for step 12, for maps of whole countries.
    func downsampled(step: Int) -> ElevationTile {
        let r = (rows - 1) / step + 1, c = (cols - 1) / step + 1
        var out = [Int16](repeating: 0, count: r * c)
        for row in 0..<r {
            let src = min(rows - 1, row * step) * cols
            for col in 0..<c { out[row * c + col] = heights[src + min(cols - 1, col * step)] }
        }
        return ElevationTile(id: id, rows: r, cols: c, heights: out)
    }
}
