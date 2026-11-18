import Dispatch
import Foundation

public struct HorizonSettings: Sendable, Hashable {
    /// How far to look (metres).
    public var maxDistance: Double = 250_000
    /// Angle between rays (degrees). 0.2° → 1800 rays.
    public var azimuthStep: Double = 0.2
    public var refraction: Double = Geo.defaultRefraction
    /// A silhouette counts as a ridge only if the terrain behind it drops at least this far (metres)
    /// below the line of sight. Filters out bumps on slopes.
    public var minRidgeDrop: Double = 20
    /// Sample spacing near the observer (metres); further out the spacing grows by `growth` per step.
    public var nearStep: Double = 25
    public var growth: Double = 0.006

    public init() {}

    public var azimuthCount: Int { Int((360 / azimuthStep).rounded()) }
}

/// A point on a visible ridge: where terrain stops rising in the view and the land behind it is hidden.
public struct RidgePoint: Sendable, Hashable {
    public var azimuth: Double  // degrees
    public var altitude: Double  // degrees above horizontal
    public var distance: Double  // metres
}

/// A ridge line: ridge points of neighbouring rays joined into a polyline.
public struct Ridge: Sendable, Identifiable {
    public let id: Int
    public let points: [RidgePoint]
    /// True if the line is (mostly) the skyline, the outermost silhouette against the sky.
    public let isSkyline: Bool
    /// Mean distance of the points (metres); stored, as drawing reads it every frame.
    public let meanDistance: Double

    init(id: Int, points: [RidgePoint], isSkyline: Bool) {
        self.id = id
        self.points = points
        self.isSkyline = isSkyline
        meanDistance = points.isEmpty ? 0 : points.reduce(0) { $0 + $1.distance } / Double(points.count)
    }

    /// Azimuth range the line covers (degrees): centre and half width. Points run clockwise from the first
    /// to the last ray (possibly across north), so this is O(1); drawing uses it to skip ridges out of view.
    public var azimuthRange: (center: Double, halfWidth: Double) {
        guard let first = points.first, let last = points.last else { return (0, 0) }
        let extent = Geo.normalizedDegrees(last.azimuth - first.azimuth)
        return (Geo.normalizedDegrees(first.azimuth + extent / 2), extent / 2)
    }
}

public struct PeakInfo: Sendable, Identifiable, Hashable {
    public let id: String
    public var name: String
    public var names: [String: String]
    public var coordinate: GeoCoordinate
    public var elevation: Double?
    public var importance: Double
    public var kind: String
    public var wikipedia: String?
    public var prominence: Double?

    public init(id: String, name: String, names: [String: String] = [:], coordinate: GeoCoordinate,
                elevation: Double?, importance: Double, kind: String = "peak", wikipedia: String? = nil,
                prominence: Double? = nil) {
        self.id = id; self.name = name; self.names = names; self.coordinate = coordinate
        self.elevation = elevation; self.importance = importance; self.kind = kind
        self.wikipedia = wikipedia; self.prominence = prominence
    }

    /// Name to show: the user's language if known, else a readable (Latin-script) name, else the local name.
    /// OSM's main name is in the local script (Everest: "珠穆朗玛峰 ཇོ་མོ་གླང་མ། सगरमाथा"), which most
    /// visitors can't read, so English or another Latin-script name wins over it.
    public func displayName(language: String?) -> String {
        if let language, let n = names[language], !n.isEmpty { return n }
        if Self.isLatinScript(name) { return name }
        if let en = names["en"], !en.isEmpty { return en }
        if let latin = names.keys.sorted().compactMap({ names[$0] }).first(where: { !$0.isEmpty && Self.isLatinScript($0) }) {
            return latin
        }
        return name
    }

    /// The peak the viewpoint is on: the closest within `radius` metres horizontally whose height (if known) is
    /// within `heightTolerance` of the ground there, i.e. standing on it rather than in a valley below it.
    public static func summit(at viewpoint: GeoCoordinate, ground: Double, in peaks: [PeakInfo],
                              radius: Double = 150, heightTolerance: Double = 80) -> PeakInfo? {
        peaks
            .map { ($0, Geo.distance(viewpoint, $0.coordinate)) }
            .filter { peak, distance in
                distance <= radius && abs((peak.elevation ?? ground) - ground) <= heightTolerance
            }
            .min { $0.1 < $1.1 }?.0
    }

    /// True if the text only uses Latin letters (incl. accents), digits and common punctuation.
    public static func isLatinScript(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { s in
            s.value < 0x0250 || (0x1E00...0x1EFF).contains(s.value) || (0x2000...0x206F).contains(s.value)
        }
    }
}

public struct VisiblePeak: Sendable, Identifiable, Hashable {
    public var peak: PeakInfo
    public var azimuth: Double
    public var altitude: Double
    public var distance: Double
    public var id: String { peak.id }

    public init(peak: PeakInfo, azimuth: Double, altitude: Double, distance: Double) {
        self.peak = peak; self.azimuth = azimuth; self.altitude = altitude; self.distance = distance
    }
}

public struct HorizonResult: Sendable {
    public let observer: GeoCoordinate
    /// Eye height above sea level (metres).
    public let observerHeight: Double
    public let settings: HorizonSettings
    /// Sample distances along every ray (metres).
    public let distances: [Double]
    public let azimuthCount: Int
    /// Running maximum of tan(elevation angle) along each ray: `[ray * distances.count + sample]`.
    public let cumulativeMaxTan: [Float]
    /// Skyline altitude (degrees) per ray; -90 where no terrain was found.
    public let skyline: [Double]
    /// Ridge lines, far-first (the order to draw them in, so near ridges end up on top).
    public let ridges: [Ridge]
    /// Fraction of samples without elevation data (tiles not downloaded).
    public let missingFraction: Double

    public func rayIndex(azimuth: Double) -> Int {
        Int((Geo.normalizedDegrees(azimuth) / settings.azimuthStep).rounded()) % azimuthCount
    }

    /// Skyline altitude at an azimuth (linear interpolation between rays).
    public func skylineAltitude(azimuth: Double) -> Double {
        let x = Geo.normalizedDegrees(azimuth) / settings.azimuthStep
        let i0 = Int(floor(x)) % azimuthCount, i1 = (i0 + 1) % azimuthCount
        let f = x - floor(x)
        return skyline[i0] * (1 - f) + skyline[i1] * f
    }

    /// Is a target at `height` visible, i.e. not hidden by terrain in front of it?
    /// `tolerance` metres of hiding are forgiven (DEM summits are too low, DEM pixels are coarse).
    public func visibility(of target: GeoCoordinate, height: Double, tolerance: Double = 25) -> VisiblePeakGeometry? {
        let d = Geo.distance(observer, target)
        guard d > 50, d <= settings.maxDistance else { return nil }
        let az = Geo.bearing(from: observer, to: target)
        let tanTarget = (height - Geo.curvatureDrop(distance: d, refraction: settings.refraction) - observerHeight) / d
        // Terrain right in front of the summit belongs to the mountain itself: ignore the last stretch.
        let j = lastSample(atMost: d - max(150, 0.015 * d))
        let altitude = degrees(atan(tanTarget))
        guard j >= 0 else { return VisiblePeakGeometry(azimuth: az, altitude: altitude, distance: d) }
        let ray = rayIndex(azimuth: az)
        let blocking = Double(cumulativeMaxTan[ray * distances.count + j])
        guard (tanTarget - blocking) * d >= -tolerance else { return nil }
        return VisiblePeakGeometry(azimuth: az, altitude: snappedAltitude(ray: ray, distance: d) ?? altitude,
                                   distance: d)
    }

    /// Index of the last sample along a ray at most `limit` metres away; -1 if there is none.
    func lastSample(atMost limit: Double) -> Int {
        var lo = 0, hi = distances.count - 1, j = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if distances[mid] <= limit { j = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return j
    }

    /// Altitude of the drawn terrain at a visible summit: the highest angle reached on this and the
    /// neighbouring rays up to slightly beyond the peak. Labels sit exactly on the rendered top instead of
    /// floating above it when the peak's coordinates are a little off (very noticeable for close peaks).
    func snappedAltitude(ray: Int, distance d: Double) -> Double? {
        let j = lastSample(atMost: d + max(300, 0.03 * d))
        guard j >= 0 else { return nil }
        var best = -Double.infinity
        for r in [ray - 1, ray, ray + 1] {
            let wrapped = (r + azimuthCount) % azimuthCount
            best = max(best, Double(cumulativeMaxTan[wrapped * distances.count + j]))
        }
        return best.isFinite ? degrees(atan(best)) : nil
    }

    public func visiblePeaks(_ peaks: [PeakInfo], tolerance: Double = 25) -> [VisiblePeak] {
        let visible = peaks.compactMap { p -> VisiblePeak? in
            guard let h = p.elevation, let g = visibility(of: p.coordinate, height: h, tolerance: tolerance) else {
                return nil
            }
            return VisiblePeak(peak: p, azimuth: g.azimuth, altitude: g.altitude, distance: g.distance)
        }
        return Self.removingNameDuplicates(visible)
    }

    /// Sources sometimes describe the same mountain twice with positions too far apart to merge (Annapurna I
    /// from OSM and Wikidata ~1 km apart). Keep the more important of two same-named peaks within `radius`.
    static func removingNameDuplicates(_ peaks: [VisiblePeak], radius: Double = 3000) -> [VisiblePeak] {
        var kept: [VisiblePeak] = []
        var byName: [String: [Int]] = [:]
        for v in peaks.sorted(by: { $0.peak.importance > $1.peak.importance }) {
            let key = v.peak.name.lowercased()
            let duplicate = (byName[key] ?? []).contains { i in
                Geo.distance(kept[i].peak.coordinate, v.peak.coordinate) < radius
            }
            if duplicate { continue }
            byName[key, default: []].append(kept.count)
            kept.append(v)
        }
        return kept
    }
}

public struct VisiblePeakGeometry: Sendable, Hashable {
    public var azimuth: Double, altitude: Double, distance: Double
}

/// Buffer shared by `concurrentPerform` workers that write disjoint indices.
struct SharedBuffer<T>: @unchecked Sendable {
    let base: UnsafeMutableBufferPointer<T>
    init(_ base: UnsafeMutableBufferPointer<T>) { self.base = base }
    subscript(i: Int) -> T {
        get { base[i] }
        nonmutating set { base[i] = newValue }
    }
}

public enum HorizonEngine {
    public static func sampleDistances(_ s: HorizonSettings) -> [Double] {
        var out: [Double] = []
        var d = s.nearStep
        while d <= s.maxDistance {
            out.append(d)
            d += max(s.nearStep, d * s.growth)
        }
        return out
    }

    struct RawRidgePoint: Sendable {
        var sample: Int
        var tan: Float
        var skyline: Bool
    }

    /// Radial sweep: for every azimuth, walk outwards and track the running maximum elevation angle.
    /// Terrain above it is visible; where a visible stretch ends behind closer terrain, that's a ridge.
    public static func compute(observer: GeoCoordinate, observerHeight: Double, terrain: TerrainModel,
                               settings: HorizonSettings = HorizonSettings()) -> HorizonResult {
        let distances = sampleDistances(settings)
        let n = distances.count
        let rays = settings.azimuthCount
        let r = Geo.earthRadius
        let lat1 = radians(observer.latitude), lon1 = radians(observer.longitude)
        let sinLat1 = sin(lat1), cosLat1 = cos(lat1)
        let sinD = distances.map { sin($0 / r) }, cosD = distances.map { cos($0 / r) }
        let drop = distances.map { Geo.curvatureDrop(distance: $0, refraction: settings.refraction) }

        var cumulative = [Float](repeating: -.infinity, count: rays * n)
        var skyline = [Double](repeating: -90, count: rays)
        var perRay = [[RawRidgePoint]](repeating: [], count: rays)
        var missing = [Int](repeating: 0, count: rays)

        cumulative.withUnsafeMutableBufferPointer { cumBuf in
            skyline.withUnsafeMutableBufferPointer { skyBuf in
                perRay.withUnsafeMutableBufferPointer { ridgeBuf in
                    missing.withUnsafeMutableBufferPointer { missBuf in
                        // Each ray writes only its own slots, so sharing the buffers across threads is safe.
                        let cum = SharedBuffer(cumBuf), sky = SharedBuffer(skyBuf)
                        let ridgeOut = SharedBuffer(ridgeBuf), miss = SharedBuffer(missBuf)
                        DispatchQueue.concurrentPerform(iterations: rays) { ray in
                            let theta = radians(Double(ray) * settings.azimuthStep)
                            let sinT = sin(theta), cosT = cos(theta)
                            var maxTan = -Double.infinity
                            var candidate: RawRidgePoint?
                            var ridges: [RawRidgePoint] = []
                            var missingHere = 0
                            for i in 0..<n {
                                let sinLat2 = sinLat1 * cosD[i] + cosLat1 * sinD[i] * cosT
                                let lat2 = asin(sinLat2)
                                let lon2 = lon1 + atan2(sinT * sinD[i] * cosLat1, cosD[i] - sinLat1 * sinLat2)
                                var lonDeg = degrees(lon2)
                                if lonDeg >= 180 { lonDeg -= 360 } else if lonDeg < -180 { lonDeg += 360 }
                                guard let h = terrain.height(latitude: degrees(lat2), longitude: lonDeg) else {
                                    missingHere += 1
                                    cum[ray * n + i] = Float(maxTan)
                                    continue
                                }
                                let d = distances[i]
                                let t = (Double(h) - drop[i] - observerHeight) / d
                                if t > maxTan {
                                    maxTan = t
                                    candidate = RawRidgePoint(sample: i, tan: Float(t), skyline: false)
                                } else if let c = candidate, (Double(c.tan) - t) * d >= settings.minRidgeDrop {
                                    ridges.append(c)
                                    candidate = nil
                                }
                                cum[ray * n + i] = Float(maxTan)
                            }
                            if let c = candidate { ridges.append(c) }
                            if !ridges.isEmpty {
                                ridges[ridges.count - 1].skyline = true  // highest angle = outermost silhouette
                            }
                            sky[ray] = maxTan.isFinite ? degrees(atan(maxTan)) : -90
                            ridgeOut[ray] = ridges
                            miss[ray] = missingHere
                        }
                    }
                }
            }
        }

        let ridges = link(perRay: perRay, distances: distances, step: settings.azimuthStep)
        return HorizonResult(observer: observer, observerHeight: observerHeight, settings: settings,
                             distances: distances, azimuthCount: rays, cumulativeMaxTan: cumulative,
                             skyline: skyline, ridges: ridges,
                             missingFraction: Double(missing.reduce(0, +)) / Double(max(1, rays * n)))
    }

    /// Join ridge points of neighbouring rays into polylines: a point continues a line from the previous
    /// ray if its distance is close (relative) and its angle is close. Lines that reach the last ray continue
    /// into lines starting at ray 0 (no break due north). Short fragments are dropped.
    /// Returned far-first (by mean distance), the order they are drawn in.
    static func link(perRay: [[RawRidgePoint]], distances: [Double], step: Double,
                     minPoints: Int = 4) -> [Ridge] {
        struct Line {
            var points: [RidgePoint]
            var skylineCount: Int
            var first: RawRidgePoint
            var last: RawRidgePoint
            var startRay: Int
        }
        func altitude(_ p: RawRidgePoint) -> Double { degrees(atan(Double(p.tan))) }
        /// Score for `next` continuing a line that ended in `previous` on the neighbouring ray; nil = no match.
        func continuation(_ previous: RawRidgePoint, _ next: RawRidgePoint) -> Double? {
            let dPrev = distances[previous.sample], d = distances[next.sample]
            let rel = abs(dPrev - d) / max(d, dPrev)
            let dAlt = abs(altitude(previous) - altitude(next))
            guard rel <= 0.08 || abs(dPrev - d) <= 250, dAlt <= 0.6 else { return nil }
            return rel + dAlt / 2
        }

        var open: [Line] = []
        var finished: [Line] = []
        for (ray, points) in perRay.enumerated() {
            let az = Double(ray) * step
            var used = [Bool](repeating: false, count: open.count)
            var next: [Line] = []
            for p in points {
                let point = RidgePoint(azimuth: az, altitude: altitude(p), distance: distances[p.sample])
                // Best continuation among open lines not yet continued in this ray.
                var best = -1
                var bestScore = Double.infinity
                for (k, o) in open.enumerated() where !used[k] {
                    if let score = continuation(o.last, p), score < bestScore { bestScore = score; best = k }
                }
                if best >= 0 {
                    used[best] = true
                    var o = open[best]
                    o.points.append(point)
                    o.skylineCount += p.skyline ? 1 : 0
                    o.last = p
                    next.append(o)
                } else {
                    next.append(Line(points: [point], skylineCount: p.skyline ? 1 : 0, first: p, last: p,
                                     startRay: ray))
                }
            }
            for (k, o) in open.enumerated() where !used[k] { finished.append(o) }
            open = next
        }

        // Wrap around north: lines still open at the last ray continue into lines that started at ray 0.
        var startsAtZero = finished.indices.filter { finished[$0].startRay == 0 }
        startsAtZero += open.indices.filter { open[$0].startRay == 0 }.map { finished.count + $0 }
        var all = finished + open
        var absorbed = Set<Int>()
        if perRay.count > 1 {
            for i in finished.count..<all.count where !absorbed.contains(i) {
                var best = -1
                var bestScore = Double.infinity
                for j in startsAtZero where j != i && !absorbed.contains(j) {
                    if let score = continuation(all[i].last, all[j].first), score < bestScore {
                        bestScore = score
                        best = j
                    }
                }
                guard best >= 0 else { continue }
                all[i].points += all[best].points
                all[i].skylineCount += all[best].skylineCount
                all[i].last = all[best].last
                absorbed.insert(best)
            }
        }

        let kept = all.indices.filter { !absorbed.contains($0) }.map { all[$0] }.filter { o in
            o.points.count >= minPoints || (o.skylineCount > 0 && o.points.count >= 2)
        }
        var ridges = kept.map { Ridge(id: 0, points: $0.points, isSkyline: $0.skylineCount * 2 >= $0.points.count) }
        ridges.sort { $0.meanDistance > $1.meanDistance }
        return ridges.enumerated().map { i, r in Ridge(id: i, points: r.points, isSkyline: r.isSkyline) }
    }
}
