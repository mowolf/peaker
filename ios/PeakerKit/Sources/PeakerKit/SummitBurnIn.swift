import Foundation

/// Raise the DEM to the official summit heights.
///
/// Copernicus is a radar surface model on a 90 m grid: sharp summits come out 50–200 m too low, so
/// ridges sit below their peak labels. For each peak with a known elevation, the highest grid point
/// next to the summit is lifted to the official height, with a steep cone around it (`slope` metres
/// per metre, 1 = 45°) blending into the original terrain. Terrain is only ever raised, never lowered.
/// Differences above `maxLift` are treated as bad data and skipped.
public enum SummitBurnIn {
    public struct Summit: Sendable {
        public var coordinate: GeoCoordinate
        public var elevation: Double
        public init(coordinate: GeoCoordinate, elevation: Double) {
            self.coordinate = coordinate
            self.elevation = elevation
        }
    }

    public static let slope: Double = 1.0
    public static let minLift: Double = 5
    public static let maxLift: Double = 400

    /// Returns the tile with summits burned in (or the same tile if nothing changed).
    public static func apply(to tile: ElevationTile, summits: [Summit]) -> ElevationTile {
        var out = tile
        apply(summits, to: &out)
        return out
    }

    /// Burn the summits into the tile in place: no copy of the heights when the tile is the only owner.
    public static func apply(_ summits: [Summit], to tile: inout ElevationTile) {
        let rows = tile.rows, cols = tile.cols
        let south = Double(tile.id.lat), west = Double(tile.id.lon)
        var highest = tile.maxHeight
        let metresPerRow = 111_320.0 / Double(rows - 1)

        for s in summits {
            let lat = s.coordinate.latitude
            var lon = s.coordinate.longitude
            if lon < west - 180 { lon += 360 } else if lon > west + 180 { lon -= 360 }
            guard lat >= south, lat <= south + 1, lon >= west, lon <= west + 1 else { continue }
            let r = (south + 1 - lat) * Double(rows - 1)
            let c = (lon - west) * Double(cols - 1)
            let metresPerCol = 111_320.0 * max(cos(lat * Double.pi / 180), 0.01) / Double(cols - 1)

            // Highest grid point among the nodes around the summit: the DEM's version of the top.
            // Ties (flat tops) go to the node closest to the given summit position.
            var bestR = Int(r.rounded()), bestC = Int(c.rounded()), best = Int16.min
            var bestDistance = Double.infinity
            for rr in max(0, Int(floor(r)) - 1)...min(rows - 1, Int(ceil(r)) + 1) {
                for cc in max(0, Int(floor(c)) - 1)...min(cols - 1, Int(ceil(c)) + 1) {
                    let h = tile.heights[rr * cols + cc]
                    let dy = (Double(rr) - r) * metresPerRow, dx = (Double(cc) - c) * metresPerCol
                    let distance = dx * dx + dy * dy
                    if h > best || (h == best && distance < bestDistance) {
                        best = h
                        bestR = rr
                        bestC = cc
                        bestDistance = distance
                    }
                }
            }
            let lift = s.elevation - Double(best)
            guard lift >= minLift, lift <= maxLift else { continue }

            // Cone of radius lift / slope around the summit node.
            let radius = lift / slope
            let dr = Int(ceil(radius / metresPerRow)), dc = Int(ceil(radius / metresPerCol))
            for rr in max(0, bestR - dr)...min(rows - 1, bestR + dr) {
                let y = Double(rr - bestR) * metresPerRow
                for cc in max(0, bestC - dc)...min(cols - 1, bestC + dc) {
                    let x = Double(cc - bestC) * metresPerCol
                    let target = s.elevation - slope * (x * x + y * y).squareRoot()
                    let i = rr * cols + cc
                    if target > Double(tile.heights[i]) {
                        let raised = Int16(clamping: Int(target.rounded()))
                        tile.heights[i] = raised
                        highest = max(highest, raised)
                    }
                }
            }
        }
        tile.maxHeight = highest
    }
}
