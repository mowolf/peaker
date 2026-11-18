import Foundation

/// Front matter of an entry file, split into top-level blocks (a key with its indented lines, or comment/blank
/// lines), plus the known fields as they were read. Writing re-emits a block unchanged unless the app changed
/// that field, so hand edits, comments and unknown keys survive.
struct FrontMatter: Sendable, Equatable {
    struct Block: Sendable, Equatable {
        /// Top-level key; nil for comments and blank lines.
        var key: String?
        var lines: [String]
    }

    var blocks: [Block]
    /// Known fields as read (after defaults), to tell which ones the app changed.
    var date: DayDate?
    var status: PeakEntry.Status
    var peaks: [PeakEntry.Peak]
    var companions: [String]
}

extension PeakEntry {
    static let knownKeys = ["date", "status", "peaks", "companions"]

    // MARK: - Reading

    /// Read an entry file. Never fails: see the type's documentation.
    public init(markdown text: String) {
        var text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        guard let (header, body) = Self.splitFrontMatter(text) else {
            self.init(date: nil, status: .planned, peaks: [], body: text)
            return
        }
        let blocks = Self.blocks(header)
        let byKey = Dictionary(blocks.compactMap { b in b.key.map { ($0, b) } }, uniquingKeysWith: { first, _ in first })

        let date = byKey["date"].flatMap { DayDate(Self.scalar(Self.inlineValue($0))) }
        let statusText = byKey["status"].map { Self.scalar(Self.inlineValue($0)).lowercased() }
        let status = statusText.flatMap(Status.init(rawValue:)) ?? (date == nil ? .planned : .summited)
        let peaks = byKey["peaks"].map(Self.peaks) ?? []
        let companions = byKey["companions"].map(Self.stringList) ?? []

        self.init(date: date, status: status, peaks: peaks, companions: companions, body: body)
        source = FrontMatter(blocks: blocks, date: date, status: status, peaks: peaks, companions: companions)
    }

    /// Front matter lines and the body, if the text starts with a `---` line and has a closing `---`/`...` line.
    private static func splitFrontMatter(_ text: String) -> (header: [String], body: String)? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        lines.removeFirst()
        guard let end = lines.firstIndex(where: { ["---", "..."].contains($0.trimmingCharacters(in: .whitespaces)) })
        else { return nil }
        let body = lines[(end + 1)...].joined(separator: "\n")
        return (Array(lines[..<end]), body)
    }

    /// Top-level blocks: a line `key:` at column 0 starts a block; indented lines and list items belong to it.
    private static func blocks(_ lines: [String]) -> [FrontMatter.Block] {
        var blocks: [FrontMatter.Block] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let key = topLevelKey(line) {
                blocks.append(.init(key: key, lines: [line]))
            } else if trimmed.isEmpty || (trimmed.hasPrefix("#") && line.first == "#") {
                blocks.append(.init(key: nil, lines: [line]))
            } else if let last = blocks.indices.last, blocks[last].key != nil {
                blocks[last].lines.append(line)
            } else if let last = blocks.indices.last(where: { blocks[$0].key != nil }),
                      blocks[(last + 1)...].allSatisfy({ $0.lines.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }),
                      line.first == " " || line.first == "\t" || trimmed.hasPrefix("- ") {
                // A list item after a blank line still belongs to the key above.
                blocks[last].lines.append(line)
            } else {
                blocks.append(.init(key: nil, lines: [line]))
            }
        }
        return blocks
    }

    private static func topLevelKey(_ line: String) -> String? {
        guard let first = line.unicodeScalars.first, CharacterSet.letters.contains(first) || first == "_",
              let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon]
        guard key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return nil }
        let after = line[line.index(after: colon)...]
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        return String(key)
    }

    /// Text after `key:` on the block's first line.
    private static func inlineValue(_ block: FrontMatter.Block) -> String {
        guard let line = block.lines.first, let colon = line.firstIndex(of: ":") else { return "" }
        return String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }

    /// A plain, single- or double-quoted scalar, without a trailing ` # comment`.
    static func scalar(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("\"") {
            var out = "", escaped = false
            for ch in text.dropFirst() {
                if escaped {
                    switch ch {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    default: out.append(ch)
                    }
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    return out
                } else {
                    out.append(ch)
                }
            }
            return out
        }
        if text.hasPrefix("'") {
            var out = ""
            var rest = Substring(text.dropFirst())
            while let ch = rest.first {
                rest = rest.dropFirst()
                if ch == "'" {
                    if rest.first == "'" { out.append("'"); rest = rest.dropFirst() } else { return out }
                } else {
                    out.append(ch)
                }
            }
            return out
        }
        var plain = text
        if plain.hasPrefix("#") { return "" }
        if let comment = plain.range(of: " #") ?? plain.range(of: "\t#") { plain = String(plain[..<comment.lowerBound]) }
        return plain.trimmingCharacters(in: .whitespaces)
    }

    /// `[a, "b, c"]` → ["a", "b, c"].
    private static func flowList(_ text: String) -> [String] {
        var inner = text.trimmingCharacters(in: .whitespaces)
        inner.removeFirst()
        if let close = inner.lastIndex(of: "]") { inner = String(inner[..<close]) }
        var items: [String] = [], current = ""
        var quote: Character?
        for ch in inner {
            if let q = quote {
                current.append(ch)
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                current.append(ch)
            } else if ch == "," {
                items.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        items.append(current)
        return items.map(scalar).filter { !$0.isEmpty }
    }

    /// A list of strings: flow (`[a, b]`), block (`- a`), or a single comma-separated scalar.
    private static func stringList(_ block: FrontMatter.Block) -> [String] {
        let inline = inlineValue(block)
        if inline.hasPrefix("[") { return flowList(inline) }
        if !inline.isEmpty {
            return scalar(inline).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return listItems(block).compactMap { item in
            item.fields.isEmpty ? (item.scalar.isEmpty ? nil : item.scalar) : nil
        }
    }

    private struct ListItem {
        var scalar: String
        var fields: [String: String]
    }

    /// Items of a block list: `- value`, or maps (`- id: x` followed by more indented `name: y` lines).
    private static func listItems(_ block: FrontMatter.Block) -> [ListItem] {
        var items: [ListItem] = []
        for line in block.lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed == "-" || trimmed.hasPrefix("- ") {
                let content = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                if let (key, value) = field(content) {
                    items.append(ListItem(scalar: "", fields: [key: value]))
                } else {
                    items.append(ListItem(scalar: scalar(content), fields: [:]))
                }
            } else if let (key, value) = field(trimmed), let last = items.indices.last {
                if items[last].fields[key] == nil { items[last].fields[key] = value }
            }
        }
        return items
    }

    /// `key: value` (the key is lowercased; the value is an unquoted scalar).
    private static func field(_ text: String) -> (String, String)? {
        guard let key = topLevelKey(text) else { return nil }
        let value = String(text[text.index(after: text.firstIndex(of: ":")!)...])
        return (key.lowercased(), scalar(value))
    }

    private static func peaks(_ block: FrontMatter.Block) -> [Peak] {
        let inline = inlineValue(block)
        if inline.hasPrefix("[") { return flowList(inline).map(peak(fromScalar:)) }
        if !inline.isEmpty, !scalar(inline).isEmpty { return [peak(fromScalar: scalar(inline))] }
        return listItems(block).compactMap { item in
            if item.fields.isEmpty { return item.scalar.isEmpty ? nil : peak(fromScalar: item.scalar) }
            let f = item.fields
            let id = f["id"].flatMap { $0.isEmpty ? nil : $0 }
            let name = f["name"].flatMap { $0.isEmpty ? nil : $0 }
            var coordinate: GeoCoordinate?
            if let lat = number(f["lat"] ?? f["latitude"]), let lon = number(f["lon"] ?? f["longitude"]),
               (-90...90).contains(lat), (-180...180).contains(lon) {
                coordinate = GeoCoordinate(latitude: lat, longitude: lon)
            }
            guard id != nil || name != nil || coordinate != nil else { return nil }
            return Peak(id: id, name: name, elevation: number(f["elevation"] ?? f["ele"]), coordinate: coordinate)
        }
    }

    /// A list item that is just text: a peak ID (`wd:Q1374`) or a name typed by hand.
    private static func peak(fromScalar text: String) -> Peak {
        let isID = ["wd:", "osm:", "gn:"].contains { text.lowercased().hasPrefix($0) } && !text.contains(" ")
        return isID ? Peak(id: text, name: nil) : Peak(id: nil, name: text)
    }

    /// The leading number of `4478`, `4478 m` or `45,9763` (decimal comma).
    private static func number(_ text: String?) -> Double? {
        guard let text else { return nil }
        let normalized = text.replacingOccurrences(of: ",", with: ".")
        let prefix = normalized.prefix { $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }
        return Double(prefix)
    }

    // MARK: - Writing

    /// The file's text. Fields the app didn't change are written exactly as they were read.
    public func markdown() -> String {
        var lines = ["---"]
        let fresh = Self.knownKeys.compactMap { key in serialized(key).map { (key, $0) } }
        if let source {
            var written = Set<String>()
            var lastKnown: Int?
            var out: [String] = []
            for block in source.blocks {
                guard let key = block.key, Self.knownKeys.contains(key), !written.contains(key) else {
                    out += block.lines
                    continue
                }
                written.insert(key)
                if isUnchanged(key, in: source) {
                    out += block.lines
                } else if let value = fresh.first(where: { $0.0 == key })?.1 {
                    out += value
                }
                lastKnown = out.count
            }
            // Fields that weren't in the file, after the last known field (or at the top).
            let added = fresh.filter { !written.contains($0.0) && !isUnchanged($0.0, in: source) }.flatMap { $0.1 }
            out.insert(contentsOf: added, at: lastKnown ?? 0)
            lines += out
        } else {
            lines += fresh.flatMap { $0.1 }
        }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n" + body
    }

    private func isUnchanged(_ key: String, in source: FrontMatter) -> Bool {
        switch key {
        case "date": date == source.date
        case "status": status == source.status
        case "peaks": peaks == source.peaks
        case "companions": companions == source.companions
        default: true
        }
    }

    /// Lines for a known field, or nil when it has nothing to say (no date, no peaks, no companions).
    private func serialized(_ key: String) -> [String]? {
        switch key {
        case "date":
            return date.map { ["date: \($0)"] }
        case "status":
            return ["status: \(status.rawValue)"]
        case "peaks":
            guard !peaks.isEmpty else { return nil }
            var out = ["peaks:"]
            for p in peaks {
                var fields: [String] = []
                if let id = p.id { fields.append("id: \(Self.quoted(id))") }
                if let name = p.name { fields.append("name: \(Self.quoted(name))") }
                if let e = p.elevation { fields.append("elevation: \(Self.format(e, decimals: 1))") }
                if let c = p.coordinate {
                    fields.append(String(format: "lat: %.5f", c.latitude))
                    fields.append(String(format: "lon: %.5f", c.longitude))
                }
                guard let first = fields.first else { continue }
                out.append("  - " + first)
                out += fields.dropFirst().map { "    " + $0 }
            }
            return out
        case "companions":
            guard !companions.isEmpty else { return nil }
            return ["companions: [" + companions.map { Self.quoted($0, inFlowList: true) }.joined(separator: ", ") + "]"]
        default:
            return nil
        }
    }

    /// A YAML scalar, quoted only when a plain one would be misread.
    static func quoted(_ text: String, inFlowList: Bool = false) -> String {
        let special = CharacterSet(charactersIn: "#&*!|>'\"%@`{}[]")
        let reserved = ["true", "false", "yes", "no", "on", "off", "null", "~"]
        let needsQuotes = text.isEmpty || text != text.trimmingCharacters(in: .whitespaces)
            || text.contains(": ") || text.hasSuffix(":") || text.contains(" #") || text.contains("\n")
            || (text.unicodeScalars.first.map { special.contains($0) || $0 == "-" || $0 == "?" } ?? false)
            || (inFlowList && text.contains(","))
            || reserved.contains(text.lowercased()) || Double(text) != nil
        guard needsQuotes else { return text }
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    /// 4478 → "4478", 4478.25 → "4478.3".
    private static func format(_ value: Double, decimals: Int) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.\(decimals)f", value)
    }
}
