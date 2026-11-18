import Foundation
import Testing
@testable import PeakerKit

struct PeakBookStatsTests {
    private func entry(_ status: PeakEntry.Status, _ date: String?, _ peaks: [(String?, String, Double?)]) -> PeakEntry {
        PeakEntry(date: date.flatMap(DayDate.init), status: status,
                  peaks: peaks.map { PeakEntry.Peak(id: $0.0, name: $0.1, elevation: $0.2) })
    }

    @Test func countsDistinctPeaksAndHighest() {
        let stats = PeakBookStats([
            (entry(.summited, "2025-07-01", [("wd:1", "Matterhorn", 4478), ("osm:n2", "Pic Tyndall", 4241)]), ["wd:1", "osm:n2"]),
            // Old ID, resolved to the same peak: counted once.
            (entry(.summited, "2026-08-14", [("osm:n9", "Matterhorn", 4478)]), ["wd:1"]),
            (entry(.attempted, "2026-07-01", [("wd:3", "Weisshorn", 4506)]), ["wd:3"]),
            (entry(.planned, nil, [("wd:3", "Weisshorn", 4506), ("wd:1", "Matterhorn", 4478)]), ["wd:3", "wd:1"]),
            // Typed by hand, no ID: matched by name.
            (entry(.summited, "2026-09-01", [(nil, "Hausberg", nil)]), [nil]),
            (entry(.summited, "2026-09-02", [(nil, "hausberg", nil)]), [nil]),
        ])
        #expect(stats.peaksClimbed == 3)
        #expect(stats.summits == 5)
        #expect(stats.highest?.name == "Matterhorn")  // the attempted Weisshorn doesn't count
        #expect(stats.peaksPerYear == [2025: 2, 2026: 2])
        #expect(stats.wishlist == 1)  // Matterhorn is climbed already
    }

    @Test func empty() {
        let stats = PeakBookStats([])
        #expect(stats.peaksClimbed == 0 && stats.highest == nil && stats.peaksPerYear.isEmpty)
    }
}

struct MarkdownTests {
    @Test func blocks() {
        let text = """
            # Matterhorn
            Left the hut at 4.
            Windy on the **ridge**.

            ## Gear
            - rope
            * crampons
            - [x] helmet
            1. Hörnli
            2) Solvay
            > Never again!
            ---
            #hashtag is text
            """
        #expect(Markdown.blocks(text) == [
            .heading(level: 1, text: "Matterhorn"),
            .paragraph("Left the hut at 4.\nWindy on the **ridge**."),
            .heading(level: 2, text: "Gear"),
            .listItem(marker: "•", text: "rope"),
            .listItem(marker: "•", text: "crampons"),
            .listItem(marker: "•", text: "✓ helmet"),
            .listItem(marker: "1.", text: "Hörnli"),
            .listItem(marker: "2.", text: "Solvay"),
            .quote("Never again!"),
            .rule,
            .paragraph("#hashtag is text"),
        ])
        #expect(Markdown.blocks("").isEmpty)
    }

    @Test func wrapAndUnwrap() {
        let bold = Markdown.toggleWrap("a ridge b", selection: 2..<7, marker: "**")
        #expect(bold == .init(text: "a **ridge** b", selection: 4..<9))
        #expect(Markdown.toggleWrap(bold.text, selection: bold.selection, marker: "**") == .init(text: "a ridge b", selection: 2..<7))
        // Nothing selected: markers with the cursor between them.
        #expect(Markdown.toggleWrap("ab", selection: 1..<1, marker: "*") == .init(text: "a**b", selection: 2..<2))
    }

    @Test func linePrefixes() {
        let text = "one\ntwo\nthree"
        // Cursor in "two": that line only.
        #expect(Markdown.toggleLinePrefix(text, selection: 5..<5, prefix: "- ") == .init(text: "one\n- two\nthree", selection: 7..<7))
        // Selection over "two" and "three": both, and back.
        let listed = Markdown.toggleLinePrefix(text, selection: 4..<13, prefix: "- ")
        #expect(listed.text == "one\n- two\n- three")
        #expect(Markdown.toggleLinePrefix(listed.text, selection: listed.selection, prefix: "- ").text == text)
        // A selection ending at the start of a line doesn't touch that line.
        #expect(Markdown.toggleLinePrefix(text, selection: 0..<4, prefix: "- ").text == "- one\ntwo\nthree")
        // Headings replace another level instead of stacking.
        #expect(Markdown.toggleLinePrefix("## Gear", selection: 3..<3, prefix: "# ").text == "# Gear")
        #expect(Markdown.toggleLinePrefix("# Gear", selection: 3..<3, prefix: "# ").text == "Gear")
        #expect(Markdown.toggleLinePrefix("", selection: 0..<0, prefix: "# ") == .init(text: "# ", selection: 2..<2))
    }
}
