import Foundation
import Testing
@testable import PeakerKit

struct PeakSearchTests {
    private func peak(_ id: String, _ name: String, names: [String: String] = [:], importance: Double,
                      azimuth: Double = 0) -> VisiblePeak {
        VisiblePeak(peak: PeakInfo(id: id, name: name, names: names, coordinate: GeoCoordinate(latitude: 46, longitude: 7.7),
                                   elevation: 4000, importance: importance),
                    azimuth: azimuth, altitude: 5, distance: 10_000)
    }

    private var peaks: [VisiblePeak] {
        [
            peak("mh", "Matterhorn", names: ["it": "Monte Cervino", "fr": "Mont Cervin"], importance: 0.9),
            peak("dh", "Dent d'Hérens", importance: 0.6),
            peak("pp", "Piz Palü", importance: 0.5),
            peak("kl", "Klein Matterhorn", importance: 0.4),
            peak("bt", "Breithorn", importance: 0.7),
        ]
    }

    @Test func prefixBeatsWordBeatsInside() {
        let ids = PeakSearch.search("matter", in: peaks, language: nil).map(\.id)
        #expect(ids == ["mh", "kl"])
        // "horn": a suffix inside words only; ranked by importance.
        #expect(PeakSearch.search("horn", in: peaks, language: nil).map(\.id) == ["mh", "bt", "kl"])
    }

    @Test func ignoresCaseAndAccents() {
        #expect(PeakSearch.search("PALU", in: peaks, language: nil).map(\.id) == ["pp"])
        #expect(PeakSearch.search("herens", in: peaks, language: nil).map(\.id) == ["dh"])
    }

    @Test func otherLanguagesMatchAndAreShown() {
        let matches = PeakSearch.search("cervino", in: peaks, language: "de")
        #expect(matches.map(\.id) == ["mh"])
        #expect(matches.first?.name == "Matterhorn")
        #expect(matches.first?.matchedAlternative == "Monte Cervino")
        // Matching the shown name has no second line.
        #expect(PeakSearch.search("matterhorn", in: peaks, language: nil).first?.matchedAlternative == nil)
    }

    @Test func emptyQueryListsMostImportant() {
        #expect(PeakSearch.search("  ", in: peaks, language: nil, limit: 2).map(\.id) == ["mh", "bt"])
        #expect(PeakSearch.search("xyz", in: peaks, language: nil).isEmpty)
    }

    // MARK: Edge marker

    private let pose = CameraPose(yaw: 0, pitch: 0, focalLength: 500, centerX: 200, centerY: 400)

    @Test func noMarkerWhenOnScreen() {
        #expect(PeakSearch.edgeMarker(azimuth: 5, altitude: 2, pose: pose, width: 400, height: 800) == nil)
    }

    @Test func markerOnTheSideOfThePeak() throws {
        let right = try #require(PeakSearch.edgeMarker(azimuth: 60, altitude: 0, pose: pose, width: 400, height: 800))
        #expect(right.x == 364)
        #expect(abs(right.y - 400) < 1)
        #expect(abs(right.angle) < 0.01)
        let left = try #require(PeakSearch.edgeMarker(azimuth: 300, altitude: 0, pose: pose, width: 400, height: 800))
        #expect(left.x == 36)
    }

    @Test func peakBehindPointsTheShorterWay() throws {
        let m = try #require(PeakSearch.edgeMarker(azimuth: 170, altitude: 0, pose: pose, width: 400, height: 800))
        #expect(m.x == 364)
        let n = try #require(PeakSearch.edgeMarker(azimuth: 190, altitude: 0, pose: pose, width: 400, height: 800))
        #expect(n.x == 36)
    }

    @Test func markerFollowsRoll() throws {
        // Rolled 90°: the world's "right" is screen "down" or "up"; the marker must not sit on a side edge.
        let rolled = CameraPose(yaw: 0, pitch: 0, roll: 90, focalLength: 500, centerX: 200, centerY: 400)
        let m = try #require(PeakSearch.edgeMarker(azimuth: 60, altitude: 0, pose: rolled, width: 400, height: 800))
        #expect(m.y == 36 || m.y == 764)
    }

    @Test func barsKeepTheMarkerAway() throws {
        // Peak far below: the marker sits above the bottom bar, not under it.
        let m = try #require(PeakSearch.edgeMarker(azimuth: 0, altitude: -60, pose: pose, width: 400, height: 800,
                                                   topInset: 150, bottomInset: 160))
        #expect(m.y == 640)
        #expect(abs(m.x - 200) < 1)
    }
}
