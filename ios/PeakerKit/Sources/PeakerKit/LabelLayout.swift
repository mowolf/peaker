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
    public static func place(_ candidates: [Candidate], rowHeight: Double = 22, rows: Int = 4, gap: Double = 28,
                             spacing: Double = 6, minY: Double = 0, maxLabels: Int = 40) -> [Placed] {
        var placed: [Placed] = []
        for c in candidates.sorted(by: { $0.priority > $1.priority }) {
            if placed.count >= maxLabels { break }
            for row in 0..<rows {
                let y = c.y - gap - Double(row + 1) * rowHeight
                guard y >= minY else { break }
                let frame = (x: c.x - 4, y: y, w: c.width + 8, h: rowHeight)
                let collides = placed.contains { p in
                    frame.x < p.x + p.width + spacing && p.x - spacing < frame.x + frame.w
                        && frame.y < p.y + p.height && p.y < frame.y + frame.h
                }
                // Also keep labels off other labels' leader lines.
                let crossesLeader = placed.contains { p in
                    p.summitX > frame.x && p.summitX < frame.x + frame.w && frame.y + frame.h > p.y + p.height
                        && frame.y < p.summitY
                }
                if !collides && !crossesLeader {
                    placed.append(Placed(id: c.id, summitX: c.x, summitY: c.y, x: frame.x, y: frame.y,
                                         width: frame.w, height: frame.h, row: row))
                    break
                }
            }
        }
        return placed
    }
}
