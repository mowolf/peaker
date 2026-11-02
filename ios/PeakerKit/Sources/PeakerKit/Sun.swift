import Foundation

/// Sun position and the day's path, including when the sun really rises/sets behind the mountains.
public enum Sun {
    public struct Position: Sendable, Hashable {
        public var azimuth: Double  // degrees clockwise from north
        public var altitude: Double  // apparent altitude (refraction included), degrees
    }

    public struct Sample: Sendable, Hashable {
        public var date: Date
        public var position: Position
    }

    public struct Event: Sendable, Hashable {
        public enum Kind: Sendable { case rise, set }
        public var kind: Kind
        public var date: Date
        public var position: Position
    }

    public struct Day: Sendable {
        /// Path from local midnight to midnight every `step` seconds.
        public var samples: [Sample]
        /// Sun appearing / disappearing over the actual terrain horizon (top of the disc), in time order.
        /// There can be several (sun dipping behind a peak and coming out again).
        public var terrainEvents: [Event]
        /// Classic sunrise/sunset over a flat horizon (nil during polar day/night).
        public var astronomicalSunrise: Date?
        public var astronomicalSunset: Date?
    }

    /// Apparent radius of the sun disc (degrees).
    public static let semiDiameter = 0.267

    /// Low-precision solar position (Astronomical Almanac), accurate to ~0.01° for 1950–2050.
    public static func position(at date: Date, coordinate: GeoCoordinate) -> Position {
        let n = date.timeIntervalSince1970 / 86_400 + 2_440_587.5 - 2_451_545.0  // days since J2000.0
        let meanLongitude = Geo.normalizedDegrees(280.460 + 0.985_647_4 * n)
        let g = radians(Geo.normalizedDegrees(357.528 + 0.985_600_3 * n))  // mean anomaly
        let eclipticLongitude = radians(meanLongitude + 1.915 * sin(g) + 0.020 * sin(2 * g))
        let obliquity = radians(23.439 - 0.000_000_4 * n)
        let rightAscension = atan2(cos(obliquity) * sin(eclipticLongitude), cos(eclipticLongitude))
        let declination = asin(sin(obliquity) * sin(eclipticLongitude))
        let gmst = Geo.normalizedDegrees(280.460_618_37 + 360.985_647_366_29 * n)
        let hourAngle = radians(gmst + coordinate.longitude) - rightAscension
        let lat = radians(coordinate.latitude)
        let altitude = asin(sin(lat) * sin(declination) + cos(lat) * cos(declination) * cos(hourAngle))
        let azimuth = atan2(sin(hourAngle), cos(hourAngle) * sin(lat) - tan(declination) * cos(lat)) + .pi
        return Position(azimuth: Geo.normalizedDegrees(degrees(azimuth)),
                        altitude: degrees(altitude) + refraction(trueAltitude: degrees(altitude)))
    }

    /// Atmospheric refraction (Bennett/Saemundsson), degrees; lifts objects near the horizon by ~0.5°.
    static func refraction(trueAltitude h: Double) -> Double {
        guard h > -2 else { return 0 }
        return 1.02 / tan(radians(h + 10.3 / (h + 5.11))) / 60
    }

    /// The sun's day at a place.
    /// - Parameters:
    ///   - horizon: terrain horizon; nil (or no terrain in a direction) means a flat horizon at the dip angle.
    ///   - observerHeight: eye height above sea level, for the dip of the sea-level horizon.
    public static func day(containing date: Date, at coordinate: GeoCoordinate, timeZone: TimeZone,
                           horizon: HorizonResult?, observerHeight: Double = 0, step: TimeInterval = 300) -> Day {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)

        var samples: [Sample] = []
        var t = start
        while t <= end {
            samples.append(Sample(date: t, position: position(at: t, coordinate: coordinate)))
            t = t.addingTimeInterval(step)
        }

        let dip = -degrees(acos(Geo.earthRadius / (Geo.earthRadius + max(0, observerHeight))))
        func terrainAltitude(_ azimuth: Double) -> Double {
            guard let horizon else { return dip }
            return max(horizon.skylineAltitude(azimuth: azimuth), dip)
        }
        // > 0 while the top of the disc is above the terrain.
        func aboveTerrain(_ d: Date) -> Double {
            let p = position(at: d, coordinate: coordinate)
            return p.altitude + semiDiameter - terrainAltitude(p.azimuth)
        }
        // > 0 while the top of the disc is above a flat sea-level horizon (classic sunrise definition).
        func aboveFlat(_ d: Date) -> Double {
            position(at: d, coordinate: coordinate).altitude + semiDiameter
        }

        let terrain = crossings(of: aboveTerrain, from: start, to: end, step: 120)
            .map { Event(kind: $0.rising ? .rise : .set, date: $0.date, position: position(at: $0.date, coordinate: coordinate)) }
        let flat = crossings(of: aboveFlat, from: start, to: end, step: 600)
        return Day(samples: samples, terrainEvents: terrain,
                   astronomicalSunrise: flat.first { $0.rising }?.date,
                   astronomicalSunset: flat.last { !$0.rising }?.date)
    }

    /// Times where f changes sign (scan, then bisect to ~5 s).
    static func crossings(of f: (Date) -> Double, from start: Date, to end: Date,
                          step: TimeInterval) -> [(date: Date, rising: Bool)] {
        var out: [(Date, Bool)] = []
        var t0 = start, v0 = f(start)
        while t0 < end {
            let t1 = min(end, t0.addingTimeInterval(step))
            let v1 = f(t1)
            if (v0 <= 0) != (v1 <= 0) {
                var a = t0, b = t1, va = v0
                while b.timeIntervalSince(a) > 5 {
                    let m = a.addingTimeInterval(b.timeIntervalSince(a) / 2)
                    let vm = f(m)
                    if (va <= 0) == (vm <= 0) { a = m; va = vm } else { b = m }
                }
                out.append((b, v1 > 0))
            }
            t0 = t1
            v0 = v1
        }
        return out
    }
}
