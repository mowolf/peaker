import Foundation
import Testing
@testable import PeakerKit

struct PeakEntryTests {
    private let matterhorn = PeakEntry.Peak(id: "wd:Q1374", name: "Matterhorn", elevation: 4478,
                                            coordinate: GeoCoordinate(latitude: 45.9763, longitude: 7.6586))

    // MARK: Writing new entries

    @Test func newEntryFormat() {
        let entry = PeakEntry(date: DayDate("2026-08-14"), status: .summited, peaks: [matterhorn],
                              companions: ["Anna", "Ben, Jr."], body: "# Hörnli ridge\nText\n")
        #expect(entry.markdown() == """
            ---
            date: 2026-08-14
            status: summited
            peaks:
              - id: wd:Q1374
                name: Matterhorn
                elevation: 4478
                lat: 45.97630
                lon: 7.65860
            companions: [Anna, "Ben, Jr."]
            ---
            # Hörnli ridge
            Text

            """)
    }

    @Test func wishlistEntryHasNoDateAndNoBody() {
        let entry = PeakEntry(date: nil, status: .planned, peaks: [PeakEntry.Peak(id: "osm:n42", name: "Piz Palü")])
        #expect(entry.markdown() == "---\nstatus: planned\npeaks:\n  - id: osm:n42\n    name: Piz Palü\n---\n")
    }

    @Test func roundTrip() {
        let entry = PeakEntry(date: DayDate("2026-08-14"), status: .attempted,
                              peaks: [matterhorn, PeakEntry.Peak(id: nil, name: "Hörnli: hut")],
                              companions: ["Anna"], body: "\nSome *text*.\n")
        let read = PeakEntry(markdown: entry.markdown())
        #expect(read.date == entry.date)
        #expect(read.status == .attempted)
        #expect(read.peaks == entry.peaks)
        #expect(read.companions == ["Anna"])
        #expect(read.body == entry.body)
        // Writing what was read changes nothing.
        #expect(read.markdown() == entry.markdown())
    }

    // MARK: Reading hand-edited files

    @Test func keepsUnknownKeysCommentsAndUntouchedFields() {
        let text = """
            ---
            # my notes
            date: 2026-08-14   # a Friday
            weather: sunny
            status: summited
            peaks:
            - id: wd:Q1374
              name: "Matterhorn"
              lat: 45.9763
              lon: 7.6586
            gear:
              - rope
            ---
            Body

            """
        var entry = PeakEntry(markdown: text)
        #expect(entry.date == DayDate("2026-08-14"))
        #expect(entry.peaks.first?.name == "Matterhorn")
        #expect(entry.peaks.first?.coordinate?.latitude == 45.9763)
        #expect(entry.markdown() == text)  // nothing changed: byte for byte

        entry.status = .attempted
        entry.companions = ["Anna"]
        #expect(entry.markdown() == """
            ---
            # my notes
            date: 2026-08-14   # a Friday
            weather: sunny
            status: attempted
            peaks:
            - id: wd:Q1374
              name: "Matterhorn"
              lat: 45.9763
              lon: 7.6586
            companions: [Anna]
            gear:
              - rope
            ---
            Body

            """)
    }

    @Test func toleratesMissingAndBrokenFields() {
        let entry = PeakEntry(markdown: "---\ndate: someday\nstatus: done\npeaks:\n  - Matterhorn\n  - wd:Q1374\n---\nHi")
        #expect(entry.date == nil)
        #expect(entry.status == .planned)  // unknown status, no date: wishlist
        #expect(entry.peaks == [PeakEntry.Peak(id: nil, name: "Matterhorn"), PeakEntry.Peak(id: "wd:Q1374", name: nil)])
        #expect(entry.body == "Hi")
        // The unreadable lines are kept as they were.
        #expect(entry.markdown() == "---\ndate: someday\nstatus: done\npeaks:\n  - Matterhorn\n  - wd:Q1374\n---\nHi")

        let dated = PeakEntry(markdown: "---\ndate: 2026-08-14T09:30:00Z\n---\n")
        #expect(dated.date == DayDate("2026-08-14"))
        #expect(dated.status == .summited)  // a date without status: climbed
    }

    @Test func otherSpellings() {
        let entry = PeakEntry(markdown: """
            ---
            Date: 2026-08-14
            peaks: [wd:Q1374, "Dent d'Hérens"]
            companions: Anna, Ben
            ---
            """)
        // Keys are case-sensitive in YAML; "Date" is an unknown key and kept.
        #expect(entry.date == nil)
        #expect(entry.peaks.map(\.displayName) == ["wd:Q1374", "Dent d'Hérens"])
        #expect(entry.companions == ["Anna", "Ben"])

        let decimalComma = PeakEntry(markdown: "---\npeaks:\n  - name: X\n    elevation: 4478 m\n    latitude: 45,5\n    longitude: 7,25\n---\n")
        #expect(decimalComma.peaks.first?.elevation == 4478)
        #expect(decimalComma.peaks.first?.coordinate == GeoCoordinate(latitude: 45.5, longitude: 7.25))
    }

    @Test func windowsLineEndingsAndByteOrderMark() {
        let entry = PeakEntry(markdown: "\u{FEFF}---\r\ndate: 2026-08-14\r\npeaks:\r\n  - id: wd:Q1374\r\n---\r\nText\r\n")
        #expect(entry.date == DayDate("2026-08-14"))
        #expect(entry.peaks.first?.id == "wd:Q1374")
        #expect(entry.body == "Text\n")
    }

    @Test func fileWithoutFrontMatterIsUnlinked() {
        let entry = PeakEntry(markdown: "# Just notes\nNo header here.")
        #expect(!entry.isLinked)
        #expect(entry.body == "# Just notes\nNo header here.")
        #expect(entry.title == "Just notes")
        // An unclosed header is text too.
        #expect(PeakEntry(markdown: "---\ndate: 2026-08-14\nno end").body == "---\ndate: 2026-08-14\nno end")
    }

    @Test func removingAFieldDropsItsLines() {
        var entry = PeakEntry(markdown: "---\ndate: 2026-08-14\ncompanions:\n  - Anna\n  - Ben\nmood: great\n---\n")
        #expect(entry.companions == ["Anna", "Ben"])
        entry.companions = []
        entry.date = nil
        entry.status = .planned
        #expect(entry.markdown() == "---\nstatus: planned\nmood: great\n---\n")
    }

    @Test func quoting() {
        #expect(PeakEntry.quoted("Matterhorn") == "Matterhorn")
        #expect(PeakEntry.quoted("wd:Q1374") == "wd:Q1374")
        #expect(PeakEntry.quoted("Piz: Bernina") == "\"Piz: Bernina\"")
        #expect(PeakEntry.quoted("1234") == "\"1234\"")
        #expect(PeakEntry.quoted("yes") == "\"yes\"")
        #expect(PeakEntry.quoted("#1 \"peak\"") == "\"#1 \\\"peak\\\"\"")
        #expect(PeakEntry.scalar("\"#1 \\\"peak\\\"\"") == "#1 \"peak\"")
        #expect(PeakEntry.scalar("'it''s'") == "it's")
    }

    // MARK: Names and dates

    @Test func fileNames() {
        let entry = PeakEntry(date: DayDate("2026-08-14"), status: .summited, peaks: [matterhorn])
        #expect(entry.suggestedFileName == "2026-08-14 Matterhorn.md")
        let wish = PeakEntry(date: nil, status: .planned, peaks: [PeakEntry.Peak(id: nil, name: "Aiguille du Midi / Nord")])
        #expect(wish.suggestedFileName == "Aiguille du Midi - Nord.md")
        #expect(PeakEntry.uniqueFileName("A.md", existing: ["a.md", "A 2.md"]) == "A 3.md")
        #expect(PeakEntry.uniqueFileName("B.md", existing: ["a.md"]) == "B.md")
    }

    @Test func dayDates() {
        #expect(DayDate("2026-02-30") != nil)  // not checked per month; harmless
        #expect(DayDate("2026-13-01") == nil)
        #expect(DayDate("26-08-14") == nil)
        #expect(DayDate("2026-08-14x") == nil)
        #expect(DayDate("2026-08-14")! < DayDate("2026-09-01")!)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        #expect(DayDate(Date(timeIntervalSince1970: 0), calendar: utc).description == "1970-01-01")
    }
}
