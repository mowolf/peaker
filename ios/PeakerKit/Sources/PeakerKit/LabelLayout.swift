import Foundation

/// Greedy label placement: most important first, each label takes the lowest free row above its peak.
public enum LabelLayout {
    public struct Candidate: Sendable {
        public var id: String
        /// Screen position of the summit.
        public var x: Double
        public var y: Double
        public var width: Double
        public var priority: Double
        public init(id: String, x: Double, y: Double, width: Double, priority: Double) {
            self.id = id; self.x = x; self.y = y; self.width = width; self.priority = priority
        }
    }

    public struct Placed: Sendable, Hashable {
        public var id: String
        public var summitX: Double
        public var summitY: Double
        /// Label frame (origin top-left). The label's leading edge sits on the summit's x.
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        public var row: Int
    }

    /// - Parameters:
    ///   - gap: vertical distance between summit and the first row
    ///   - maxLabels: stop after this many labels
    ///   - maxX: right screen edge; labels that would cross it flip to the left of their leader line
    ///   - previous: rows used in the previous frame (id → row). Those labels get a priority bonus and try
    ///     their old row first, so labels don't jump around or flicker while the view moves.
    public static func place(_ candidates: [Candidate], rowHeight: Double = 22, rows: Int = 4, gap: Double = 28,
                             spacing: Double = 6, minY: Double = 0, maxX: Double = .infinity, maxLabels: Int = 40,
                             previous: [String: Int] = [:], stickiness: Double = 0.25) -> [Placed] {
        var placed: [Placed] = []
        let ordered = candidates.sorted {
            ($0.priority + (previous[$0.id] != nil ? stickiness : 0)) > ($1.priority + (previous[$1.id] != nil ? stickiness : 0))
        }
        for c in ordered {
            if placed.count >= maxLabels { break }
            var rowOrder = Array(0..<rows)
            if let old = previous[c.id], old < rows {
                rowOrder.removeAll { $0 == old }
                rowOrder.insert(old, at: 0)
            }
            search: for row in rowOrder {
                let y = c.y - gap - Double(row + 1) * rowHeight
                guard y >= minY else { continue }
                // Label to the right of its leader line, or flipped to the left near the right edge / on collision.
                for x in [c.x - 4, c.x - c.width - 4] {
                    let frame = (x: x, y: y, w: c.width + 8, h: rowHeight)
                    guard frame.x >= 0 || x == c.x - 4, frame.x + frame.w <= maxX else { continue }
                    if fits(frame, summitX: c.x, summitY: c.y, among: placed, spacing: spacing) {
                        placed.append(Placed(id: c.id, summitX: c.x, summitY: c.y, x: frame.x, y: frame.y,
                                             width: frame.w, height: frame.h, row: row))
                        break search
                    }
                }
            }
        }
        return placed
    }

    private static func fits(_ frame: (x: Double, y: Double, w: Double, h: Double), summitX: Double, summitY: Double,
                             among placed: [Placed], spacing: Double) -> Bool {
        for p in placed {
            // Overlapping another label
            if frame.x < p.x + p.width + spacing && p.x - spacing < frame.x + frame.w
                && frame.y < p.y + p.height && p.y < frame.y + frame.h { return false }
            // Covering another label's leader line
            if p.summitX > frame.x && p.summitX < frame.x + frame.w && frame.y + frame.h > p.y + p.height
                && frame.y < p.summitY { return false }
            // Our leader line running through another label
            if summitX > p.x && summitX < p.x + p.width && p.y + p.height > frame.y + frame.h && p.y < summitY {
                return false
            }
        }
        return true
    }
}
