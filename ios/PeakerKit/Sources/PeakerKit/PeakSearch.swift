import Foundation

/// Finding a peak among those visible from the viewpoint, and pointing at it when it is off screen.
public enum PeakSearch {
    public struct Match: Sendable, Identifiable {
        public var visible: VisiblePeak
        /// The name to show: the display name, or the other name that matched ("Monte Cervino").
        public var name: String
        /// The matched name when it isn't the display name, to show as a second line.
        public var matchedAlternative: String?
        public var id: String { visible.id }
    }

    /// Visible peaks whose name (in any language) contains the query, ignoring case and accents.
    /// Ranked: name starts with the query, then a word starts with it, then anywhere; within each, by importance.
    /// An empty query lists the most important visible peaks.
    public static func search(_ query: String, in peaks: [VisiblePeak], language: String?, limit: Int = 50) -> [Match] {
        let needle = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else {
            return peaks.sorted { $0.peak.importance > $1.peak.importance }.prefix(limit)
                .map { Match(visible: $0, name: $0.peak.displayName(language: language)) }
        }
        var ranked: [(match: Match, rank: Int)] = []
        for v in peaks {
            let display = v.peak.displayName(language: language)
            var best: (rank: Int, name: String)?
            for candidate in [display, v.peak.name] + v.peak.names.keys.sorted().compactMap({ v.peak.names[$0] }) {
                guard let rank = rank(of: needle, in: fold(candidate)) else { continue }
                if best == nil || rank < best!.rank { best = (rank, candidate) }
                if rank == 0 && candidate == display { break }
            }
            guard let best else { continue }
            let alternative = fold(best.name) == fold(display) ? nil : best.name
            ranked.append((Match(visible: v, name: display, matchedAlternative: alternative), best.rank))
        }
        ranked.sort {
            $0.rank != $1.rank ? $0.rank < $1.rank : $0.match.visible.peak.importance > $1.match.visible.peak.importance
        }
        return ranked.prefix(limit).map(\.match)
    }

    /// 0: the name starts with the query, 1: a word does, 2: it is somewhere inside; nil: no match.
    static func rank(of needle: String, in haystack: String) -> Int? {
        guard let range = haystack.range(of: needle) else { return nil }
        if range.lowerBound == haystack.startIndex { return 0 }
        let wordStarts = haystack.indices.filter { i in
            i != haystack.startIndex && !haystack[haystack.index(before: i)].isLetter && !haystack[haystack.index(before: i)].isNumber
        }
        return wordStarts.contains { haystack[$0...].hasPrefix(needle) } ? 1 : 2
    }

    /// Lowercased, without accents ("Piz Palü" → "piz palu"), so "palu" finds it.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    // MARK: - Off-screen marker

    public struct EdgeMarker: Sendable, Equatable {
        /// Where to draw the marker (inside the screen, `inset` from the edges).
        public var x: Double
        public var y: Double
        /// Screen direction towards the peak, radians (0 = right, π/2 = down).
        public var angle: Double
    }

    /// A marker at the screen edge pointing towards a peak that is off screen; nil when the peak is on screen.
    /// Works for any roll and for peaks behind the viewer (the marker then points the shorter way round).
    /// `topInset` / `bottomInset` keep the marker clear of the bars (default: `inset`).
    public static func edgeMarker(azimuth: Double, altitude: Double, pose: CameraPose,
                                  width: Double, height: Double, inset: Double = 36,
                                  topInset: Double? = nil, bottomInset: Double? = nil) -> EdgeMarker? {
        let minX = inset, maxX = width - inset, minY = topInset ?? inset, maxY = height - (bottomInset ?? inset)
        guard maxX > minX, maxY > minY else { return nil }
        if let p = pose.project(azimuth: azimuth, altitude: altitude),
           p.x >= 0, p.x <= width, p.y >= 0, p.y <= height { return nil }

        // Direction in the screen plane (screen y grows downwards).
        let direction = Vec3.direction(azimuth: azimuth, altitude: altitude)
        var dx = direction.dot(pose.right), dy = -direction.dot(pose.up)
        if direction.dot(pose.forward) <= 0 || hypot(dx, dy) < 1e-6 {
            // Behind the viewer: turn the shorter way, sideways.
            let turn = Geo.angleDifference(azimuth, pose.azimuth)
            let sideways = Vec3.direction(azimuth: pose.azimuth + (turn >= 0 ? 90 : -90), altitude: 0)
            dx = sideways.dot(pose.right)
            dy = -sideways.dot(pose.up)
            if hypot(dx, dy) < 1e-6 { dx = turn >= 0 ? 1 : -1; dy = 0 }
        }
        // From the screen centre along (dx, dy) to the inset rectangle.
        let cx = pose.centerX, cy = pose.centerY
        var t = Double.infinity
        if dx > 0 { t = min(t, (maxX - cx) / dx) }
        if dx < 0 { t = min(t, (minX - cx) / dx) }
        if dy > 0 { t = min(t, (maxY - cy) / dy) }
        if dy < 0 { t = min(t, (minY - cy) / dy) }
        guard t.isFinite, t >= 0 else { return nil }
        return EdgeMarker(x: min(max(cx + dx * t, minX), maxX), y: min(max(cy + dy * t, minY), maxY),
                          angle: atan2(dy, dx))
    }
}
