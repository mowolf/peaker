import Foundation

/// The Markdown the peak book editor understands: block structure for the preview, and the toolbar's edits.
/// Inline formatting (bold, italics, links) is left to `AttributedString(markdown:)` per block.
public enum MarkdownBlock: Sendable, Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// One item; `marker` is "•" for bullets or "1." etc. for numbered lists.
    case listItem(marker: String, text: String)
    case quote(String)
    case rule
}

public enum Markdown {
    /// Split text into blocks. Consecutive plain lines form one paragraph; blank lines separate blocks.
    public static func blocks(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if let heading = heading(line) {
                flush(); blocks.append(heading)
            } else if ["---", "***", "___"].contains(line.replacingOccurrences(of: " ", with: "")) {
                flush(); blocks.append(.rule)
            } else if let item = bullet(line) {
                flush(); blocks.append(.listItem(marker: "•", text: item))
            } else if let (number, item) = numbered(line) {
                flush(); blocks.append(.listItem(marker: "\(number).", text: item))
            } else if line.hasPrefix(">") {
                flush(); blocks.append(.quote(line.dropFirst().trimmingCharacters(in: .whitespaces)))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        return .heading(level: hashes, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func bullet(_ line: String) -> String? {
        for marker in ["- [ ] ", "- [x] ", "- ", "* ", "+ "] where line.hasPrefix(marker) {
            let text = String(line.dropFirst(marker.count))
            return marker.contains("[x]") ? "✓ " + text : marker.contains("[ ]") ? "○ " + text : text
        }
        return nil
    }

    private static func numbered(_ line: String) -> (Int, String)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3, let n = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (n, String(rest.dropFirst(2)))
    }

    // MARK: - Editing

    /// Text and selection (character offsets) after an edit.
    public struct Edit: Sendable, Equatable {
        public var text: String
        public var selection: Range<Int>
    }

    /// Wrap the selection in `marker` (e.g. "**" for bold), or unwrap it if it already is. With nothing
    /// selected the markers are inserted with the cursor between them.
    public static func toggleWrap(_ text: String, selection: Range<Int>, marker: String) -> Edit {
        var chars = Array(text)
        let range = clamp(selection, chars.count)
        let m = Array(marker)
        let before = range.lowerBound >= m.count ? Array(chars[(range.lowerBound - m.count)..<range.lowerBound]) : []
        let after = range.upperBound + m.count <= chars.count ? Array(chars[range.upperBound..<(range.upperBound + m.count)]) : []
        if before == m && after == m {
            chars.removeSubrange(range.upperBound..<(range.upperBound + m.count))
            chars.removeSubrange((range.lowerBound - m.count)..<range.lowerBound)
            return Edit(text: String(chars), selection: (range.lowerBound - m.count)..<(range.upperBound - m.count))
        }
        chars.insert(contentsOf: m, at: range.upperBound)
        chars.insert(contentsOf: m, at: range.lowerBound)
        return Edit(text: String(chars), selection: (range.lowerBound + m.count)..<(range.upperBound + m.count))
    }

    /// Put `prefix` (e.g. "# " or "- ") at the start of every line the selection touches, or remove it if all of
    /// them have it. Another heading level is replaced rather than stacked ("## " → "# ").
    public static func toggleLinePrefix(_ text: String, selection: Range<Int>, prefix: String) -> Edit {
        var chars = Array(text)
        let range = clamp(selection, chars.count)
        var starts: [Int] = []
        var i = range.lowerBound
        while i > 0 && chars[i - 1] != "\n" { i -= 1 }
        starts.append(i)
        for j in range.lowerBound..<max(range.lowerBound, range.upperBound) where chars[j] == "\n" && j + 1 < chars.count {
            if j + 1 < range.upperBound || range.isEmpty { starts.append(j + 1) }
        }
        let p = Array(prefix)
        let isHeading = prefix.hasPrefix("#")
        func existing(_ start: Int) -> Int {
            // Length of the prefix of the same kind already there (any heading level for headings).
            if isHeading {
                let hashes = chars[start...].prefix { $0 == "#" }.count
                return hashes > 0 && start + hashes < chars.count && chars[start + hashes] == " " ? hashes + 1 : 0
            }
            return start + p.count <= chars.count && Array(chars[start..<(start + p.count)]) == p ? p.count : 0
        }
        let removing = starts.allSatisfy { start in
            let n = existing(start)
            return n == p.count && Array(chars[start..<(start + n)]) == p
        }
        var lower = range.lowerBound, upper = range.upperBound
        for start in starts.reversed() {
            let n = existing(start)
            chars.removeSubrange(start..<(start + n))
            if !removing { chars.insert(contentsOf: p, at: start) }
            let delta = (removing ? 0 : p.count) - n
            if start <= lower { lower = max(start, lower + delta) }
            if start <= upper { upper = max(start, upper + delta) }
        }
        return Edit(text: String(chars), selection: lower..<max(lower, upper))
    }

    private static func clamp(_ r: Range<Int>, _ count: Int) -> Range<Int> {
        let lower = min(max(0, r.lowerBound), count)
        return lower..<min(max(lower, r.upperBound), count)
    }
}
