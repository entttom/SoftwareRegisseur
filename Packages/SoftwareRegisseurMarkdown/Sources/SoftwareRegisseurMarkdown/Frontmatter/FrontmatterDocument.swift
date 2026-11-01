import Foundation
import Yams

/// Whether and how a document carries a `---` frontmatter block.
public enum FrontmatterState: Sendable, Hashable {
    case absent
    case present
    /// Opening `---` without closing delimiter; the whole text is treated as body.
    case unterminated
}

public enum FrontmatterDiagnostic: Sendable, Hashable {
    case missingFrontmatter
    case unterminatedFrontmatter
    case malformedYAML(message: String)
    case frontmatterNotAMapping
    case duplicateKey(String)
}

public enum FrontmatterError: Error, Sendable, Hashable {
    case invalidUTF8
    case frontmatterUnterminated
    case frontmatterMalformed(message: String)
    case duplicateKey(String)
    case invalidKey(String)
}

/// Markdown file with optional YAML frontmatter that supports lossless, line-surgical edits (spec F3:
/// "Keine destruktive Formatierung ganzer Dateien beim reinen Statuswechsel"; ADR-0004).
///
/// Invariant: `text` re-serialises the parsed input byte for byte until an edit touches specific lines.
public struct FrontmatterDocument: Sendable, Hashable {
    public private(set) var hasByteOrderMark: Bool
    public private(set) var state: FrontmatterState
    /// Line ending used for newly written lines (detected from the file).
    public let lineEnding: LineEnding
    /// Everything after the closing delimiter (or the whole text when there is no frontmatter).
    public var body: String

    private var openingLine: TextLine?
    private var yamlLines: [TextLine]
    private var closingLine: TextLine?

    public private(set) var values: [String: FrontmatterValue] = [:]
    /// Top-level keys in file order.
    public private(set) var keys: [String] = []
    public private(set) var diagnostics: [FrontmatterDiagnostic] = []

    private static let byteOrderMark: Unicode.Scalar = "\u{FEFF}"

    // MARK: Parsing

    public init(text: String) {
        var remainder = text
        hasByteOrderMark = text.unicodeScalars.first == Self.byteOrderMark
        if hasByteOrderMark {
            remainder = String(Substring(text.unicodeScalars.dropFirst()))
        }
        lineEnding = LineEnding.detect(in: remainder)
        let lines = TextLines.split(remainder)
        yamlLines = []
        body = remainder
        state = .absent

        if let first = lines.first, first.trimmedContent == "---" {
            if let closeIndex = lines.indices.dropFirst().first(where: {
                let trimmed = lines[$0].trimmedContent
                return trimmed == "---" || trimmed == "..."
            }) {
                openingLine = first
                yamlLines = Array(lines[1..<closeIndex])
                closingLine = lines[closeIndex]
                body = TextLines.join(Array(lines[(closeIndex + 1)...]))
                state = .present
            } else {
                state = .unterminated
            }
        }
        reparse()
    }

    /// Decodes UTF-8 data (with or without BOM).
    public init(data: Data) throws(FrontmatterError) {
        guard let text = String(validating: data, as: UTF8.self) else { throw .invalidUTF8 }
        self.init(text: text)
    }

    /// Exact serialisation.
    public var text: String {
        var result = hasByteOrderMark ? String(Self.byteOrderMark) : ""
        if state == .present, let openingLine, let closingLine {
            result += openingLine.raw + TextLines.join(yamlLines) + closingLine.raw
        }
        return result + body
    }

    public var data: Data { Data(text.utf8) }

    /// Raw YAML between the delimiters.
    public var frontmatterText: String? {
        state == .present ? TextLines.join(yamlLines) : nil
    }

    public subscript(key: String) -> FrontmatterValue? { values[key] }

    public var isEditable: Bool {
        !diagnostics.contains { diagnostic in
            switch diagnostic {
            case .unterminatedFrontmatter, .malformedYAML, .frontmatterNotAMapping, .duplicateKey: true
            case .missingFrontmatter: false
            }
        }
    }

    private mutating func reparse() {
        values = [:]
        keys = []
        diagnostics = []
        switch state {
        case .absent:
            diagnostics.append(.missingFrontmatter)
            return
        case .unterminated:
            diagnostics.append(.unterminatedFrontmatter)
            return
        case .present:
            break
        }
        let entries = Self.scanEntries(yamlLines)
        var seen = Set<String>()
        for entry in entries where !seen.insert(entry.key).inserted {
            diagnostics.append(.duplicateKey(entry.key))
        }
        let yaml = TextLines.join(yamlLines)
        do {
            guard let root = try Yams.compose(yaml: yaml) else { return }  // empty frontmatter
            guard case let .mapping(mapping) = root else {
                diagnostics.append(.frontmatterNotAMapping)
                return
            }
            for pair in mapping {
                let key = pair.key.scalar?.string ?? ""
                if values[key] == nil { keys.append(key) }
                values[key] = FrontmatterValue(node: pair.value)
            }
        } catch {
            if !diagnostics.contains(where: { if case .duplicateKey = $0 { true } else { false } }) {
                diagnostics.append(.malformedYAML(message: String(describing: error)))
            }
        }
    }

    // MARK: Editing

    /// Sets a top-level scalar. Existing quoting style and inline comment are kept when possible;
    /// only the key's own line(s) change.
    public mutating func setScalar(key: String, value: String, style: ScalarStyle? = nil) throws(FrontmatterError) {
        try prepareForEdit(key: key)
        let entries = Self.scanEntries(yamlLines)
        if let entry = entries.first(where: { $0.key == key }) {
            let keyLine = yamlLines[entry.lines.lowerBound]
            let parts = Self.splitValue(of: keyLine.content, valueOffset: entry.valueOffset)
            let resolvedStyle: ScalarStyle?
            var allowAmbiguous = false
            if let style {
                resolvedStyle = style
                allowAmbiguous = style == .plain
            } else {
                switch parts.existingStyle {
                case .doubleQuoted?: resolvedStyle = .doubleQuoted
                case .singleQuoted?: resolvedStyle = .singleQuoted
                case .plain?:
                    resolvedStyle = .plain
                    // Keep plain dates/numbers plain (e.g. `date: 2026-10-30`, `adr: 0004`).
                    let oldKind = YAMLScalarFormatter.plainKind(parts.value.trimmingWhitespace())
                    allowAmbiguous = oldKind != .string && oldKind == YAMLScalarFormatter.plainKind(value)
                case nil: resolvedStyle = nil
                }
            }
            let rendered = YAMLScalarFormatter.render(value, style: resolvedStyle, allowAmbiguousPlain: allowAmbiguous)
            let comment = entry.lines.count == 1 ? parts.comment : ""
            let newLine = TextLine(content: parts.prefix + rendered + comment, terminator: keyLine.terminator)
            yamlLines.replaceSubrange(entry.lines, with: [newLine])
        } else {
            let rendered = YAMLScalarFormatter.render(value, style: style, allowAmbiguousPlain: style == .plain)
            appendLine(Self.renderKey(key) + ": " + rendered)
        }
        reparse()
    }

    /// Sets a top-level list of strings, keeping the existing flow/block style and item indentation.
    public mutating func setList(key: String, values items: [String], style: ListStyle? = nil) throws(FrontmatterError) {
        try prepareForEdit(key: key)
        let entries = Self.scanEntries(yamlLines)
        if let entry = entries.first(where: { $0.key == key }) {
            let keyLine = yamlLines[entry.lines.lowerBound]
            let parts = Self.splitValue(of: keyLine.content, valueOffset: entry.valueOffset)
            let blockItemLine = yamlLines[entry.lines].dropFirst().first {
                $0.content.trimmingWhitespace().hasPrefix("-")
            }
            let existingIsBlock = parts.value.isBlankLine && blockItemLine != nil
            let resolved = style ?? (existingIsBlock ? .block : .flow)
            // The closing delimiter follows, so every YAML line has a terminator; reuse the key line's.
            let terminator = keyLine.terminator.isEmpty ? lineEnding.rawValue : keyLine.terminator
            var newLines: [TextLine]
            if resolved == .block, !items.isEmpty {
                let itemPrefix = blockItemLine.map(Self.blockItemPrefix) ?? "  - "
                newLines = [TextLine(content: parts.prefix.trimmingTrailingWhitespace() + parts.comment,
                                     terminator: terminator)]
                newLines += items.map {
                    TextLine(content: itemPrefix + YAMLScalarFormatter.render($0), terminator: terminator)
                }
            } else {
                let comment = entry.lines.count == 1 ? parts.comment : ""
                newLines = [TextLine(content: parts.prefix + Self.renderFlowList(items) + comment,
                                     terminator: terminator)]
            }
            yamlLines.replaceSubrange(entry.lines, with: newLines)
        } else if style == .block, !items.isEmpty {
            appendLine(Self.renderKey(key) + ":")
            for item in items { appendLine("  - " + YAMLScalarFormatter.render(item)) }
        } else {
            appendLine(Self.renderKey(key) + ": " + Self.renderFlowList(items))
        }
        reparse()
    }

    /// Removes a top-level key and its continuation lines. Returns false if the key does not exist.
    @discardableResult
    public mutating func remove(key: String) throws(FrontmatterError) -> Bool {
        guard state == .present else {
            if state == .unterminated { throw .frontmatterUnterminated }
            return false
        }
        try checkEditable()
        guard let entry = Self.scanEntries(yamlLines).first(where: { $0.key == key }) else { return false }
        yamlLines.removeSubrange(entry.lines)
        reparse()
        return true
    }

    /// Replaces a full-line YAML comment that equals `comment` (trimmed) with `key: value` (ADR template
    /// `# supersedes: 0000`). Returns false when no such comment exists.
    mutating func replaceComment(matching predicate: (String) -> Bool, withLine content: String) -> Bool {
        guard let index = yamlLines.firstIndex(where: {
            let trimmed = $0.content.trimmingWhitespace()
            return trimmed.hasPrefix("#") && predicate(trimmed)
        }) else { return false }
        yamlLines[index].content = content
        reparse()
        return true
    }

    private mutating func prepareForEdit(key: String) throws(FrontmatterError) {
        guard !key.isEmpty, !key.contains(where: \.isNewline) else { throw .invalidKey(key) }
        switch state {
        case .unterminated:
            throw .frontmatterUnterminated
        case .absent:
            // Create a frontmatter block at the top; the body stays untouched.
            openingLine = TextLine(content: "---", terminator: lineEnding.rawValue)
            closingLine = TextLine(content: "---", terminator: lineEnding.rawValue)
            yamlLines = []
            state = .present
            reparse()
        case .present:
            try checkEditable()
        }
    }

    private func checkEditable() throws(FrontmatterError) {
        for diagnostic in diagnostics {
            switch diagnostic {
            case let .duplicateKey(key): throw .duplicateKey(key)
            case let .malformedYAML(message): throw .frontmatterMalformed(message: message)
            case .frontmatterNotAMapping: throw .frontmatterMalformed(message: "frontmatter is not a mapping")
            case .unterminatedFrontmatter: throw .frontmatterUnterminated
            case .missingFrontmatter: break
            }
        }
    }

    private mutating func appendLine(_ content: String) {
        if let last = yamlLines.indices.last, yamlLines[last].terminator.isEmpty {
            yamlLines[last].terminator = lineEnding.rawValue
        }
        yamlLines.append(TextLine(content: content, terminator: lineEnding.rawValue))
    }

    // MARK: Line scanning

    struct Entry {
        var key: String
        var lines: Range<Int>
        /// Offset (in unicode scalars) right after the `:` of the key line.
        var valueOffset: Int
    }

    /// Finds top-level `key:` entries and their continuation lines. Comments/blank lines belong to an entry only
    /// when more continuation lines follow, so trailing comments stay where they are.
    static func scanEntries(_ lines: [TextLine]) -> [Entry] {
        var entries: [Entry] = []
        for (index, line) in lines.enumerated() {
            let content = line.content
            guard let first = content.unicodeScalars.first else { continue }
            if first == " " || first == "\t" || first == "-" {
                if !entries.isEmpty, !content.isBlankLine, !content.trimmingWhitespace().hasPrefix("#") {
                    entries[entries.count - 1].lines = entries[entries.count - 1].lines.lowerBound..<(index + 1)
                }
                continue
            }
            if first == "#" { continue }
            if let parsed = parseKey(content) {
                entries.append(Entry(key: parsed.key, lines: index..<(index + 1), valueOffset: parsed.valueOffset))
            } else if !entries.isEmpty {
                entries[entries.count - 1].lines = entries[entries.count - 1].lines.lowerBound..<(index + 1)
            }
        }
        return entries
    }

    /// Parses `key:` / `"key":` / `'key':` at column 0.
    static func parseKey(_ content: String) -> (key: String, valueOffset: Int)? {
        let scalars = Array(content.unicodeScalars)
        guard let first = scalars.first else { return nil }
        var key = ""
        var index = 0
        if first == "\"" || first == "'" {
            index = 1
            var closed = false
            while index < scalars.count {
                let scalar = scalars[index]
                if first == "\"", scalar == "\\", index + 1 < scalars.count {
                    key.unicodeScalars.append(scalars[index + 1])
                    index += 2
                    continue
                }
                if scalar == first {
                    if first == "'", index + 1 < scalars.count, scalars[index + 1] == "'" {
                        key += "'"
                        index += 2
                        continue
                    }
                    closed = true
                    index += 1
                    break
                }
                key.unicodeScalars.append(scalar)
                index += 1
            }
            guard closed else { return nil }
            while index < scalars.count, scalars[index] == " " { index += 1 }
            guard index < scalars.count, scalars[index] == ":" else { return nil }
            let after = index + 1
            guard after == scalars.count || scalars[after] == " " || scalars[after] == "\t" else { return nil }
            return (key, after)
        }
        if "[]{}&*!|>%@`?,".unicodeScalars.contains(first) { return nil }
        while index < scalars.count {
            if scalars[index] == ":" {
                let after = index + 1
                if after == scalars.count || scalars[after] == " " || scalars[after] == "\t" {
                    let trimmed = String(String.UnicodeScalarView(scalars[0..<index])).trimmingWhitespace()
                    return trimmed.isEmpty ? nil : (trimmed, after)
                }
            }
            if scalars[index] == "#", index > 0, scalars[index - 1] == " " || scalars[index - 1] == "\t" {
                return nil
            }
            index += 1
        }
        return nil
    }

    struct ValueParts {
        /// `key:` plus the whitespace before the value.
        var prefix: String
        var value: String
        /// Whitespace + `# comment`, or "".
        var comment: String
        var existingStyle: ScalarStyle?
    }

    static func splitValue(of content: String, valueOffset: Int) -> ValueParts {
        let scalars = Array(content.unicodeScalars)
        var valueStart = valueOffset
        while valueStart < scalars.count, scalars[valueStart] == " " || scalars[valueStart] == "\t" {
            valueStart += 1
        }
        if valueStart == scalars.count || scalars[valueStart] == "#" {
            // `key:` or `key:   # comment` – no value yet.
            return ValueParts(
                prefix: String(String.UnicodeScalarView(scalars[0..<valueOffset])) + " ",
                value: "",
                comment: String(String.UnicodeScalarView(scalars[valueOffset..<scalars.count])),
                existingStyle: nil
            )
        }
        let prefix = String(String.UnicodeScalarView(scalars[0..<valueStart]))
        // Find an inline comment outside quotes.
        var commentStart = scalars.count
        var quote: Unicode.Scalar?
        var index = valueStart
        while index < scalars.count {
            let scalar = scalars[index]
            if let open = quote {
                if open == "\"", scalar == "\\" { index += 2; continue }
                if scalar == open {
                    if open == "'", index + 1 < scalars.count, scalars[index + 1] == "'" { index += 2; continue }
                    quote = nil
                }
            } else if scalar == "\"" || scalar == "'" {
                let previous = index > valueStart ? scalars[index - 1] : " "
                if previous == " " || previous == "\t" || previous == "[" || previous == "," || previous == "{" {
                    quote = scalar
                }
            } else if scalar == "#", index > valueStart, scalars[index - 1] == " " || scalars[index - 1] == "\t" {
                commentStart = index
                while commentStart > valueStart, scalars[commentStart - 1] == " " || scalars[commentStart - 1] == "\t" {
                    commentStart -= 1
                }
                break
            }
            index += 1
        }
        let value = String(String.UnicodeScalarView(scalars[valueStart..<commentStart]))
        let comment = String(String.UnicodeScalarView(scalars[commentStart..<scalars.count]))
        let style: ScalarStyle? = switch value.unicodeScalars.first {
        case "\""?: .doubleQuoted
        case "'"?: .singleQuoted
        case "["?, "{"?, "|"?, ">"?, nil: nil
        default: .plain
        }
        return ValueParts(prefix: prefix, value: value, comment: comment, existingStyle: style)
    }

    static func blockItemPrefix(_ line: TextLine) -> String {
        let scalars = Array(line.content.unicodeScalars)
        var index = 0
        while index < scalars.count, scalars[index] == " " || scalars[index] == "\t" { index += 1 }
        guard index < scalars.count, scalars[index] == "-" else { return "  - " }
        index += 1
        while index < scalars.count, scalars[index] == " " { index += 1 }
        let prefix = String(String.UnicodeScalarView(scalars[0..<index]))
        return prefix.hasSuffix(" ") ? prefix : prefix + " "
    }

    static func renderKey(_ key: String) -> String {
        if parseKey(key + ":")?.key == key, YAMLScalarFormatter.isPlainSafe(key, context: .block) { return key }
        return YAMLScalarFormatter.doubleQuoted(key)
    }

    static func renderFlowList(_ items: [String]) -> String {
        "[" + items.map { YAMLScalarFormatter.render($0, context: .flow) }.joined(separator: ", ") + "]"
    }
}

extension String {
    func trimmingTrailingWhitespace() -> String {
        var scalars = Substring(self).unicodeScalars
        while let last = scalars.last, last == " " || last == "\t" { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }
}
