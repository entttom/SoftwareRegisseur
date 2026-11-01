import Foundation

/// Lossless split of a Markdown body into a preamble and ATX heading sections of one level (default `##`).
/// Headings inside fenced code blocks are ignored. `text` reproduces the input byte for byte (spec F3:
/// "unbekannte Felder und Benutzerabschnitte bewahren").
public struct MarkdownSections: Sendable, Hashable {
    public struct Section: Sendable, Hashable {
        /// Raw heading line including terminator, e.g. "## Ziel\n".
        public var headingLine: String
        /// Normalised heading text, e.g. "Ziel".
        public var title: String
        /// Everything after the heading line up to the next heading of the same level.
        public var content: String

        /// Content without leading/trailing blank lines, line endings normalised to LF.
        public var trimmedContent: String {
            MarkdownSections.normalized(content)
        }
    }

    public var preamble: String
    public var sections: [Section]
    public let level: Int
    public let lineEnding: LineEnding

    public init(parsing body: String, level: Int = 2) {
        self.level = level
        lineEnding = LineEnding.detect(in: body)
        var preambleLines: [TextLine] = []
        var parsed: [(heading: TextLine, title: String, content: [TextLine])] = []
        var fence = FenceTracker()
        for line in TextLines.split(body) {
            let inFence = fence.consume(line.content)
            if !inFence, let title = Self.headingTitle(line.content, level: level) {
                parsed.append((line, title, []))
            } else if parsed.isEmpty {
                preambleLines.append(line)
            } else {
                parsed[parsed.count - 1].content.append(line)
            }
        }
        preamble = TextLines.join(preambleLines)
        sections = parsed.map { Section(headingLine: $0.heading.raw, title: $0.title, content: TextLines.join($0.content)) }
    }

    public var text: String {
        preamble + sections.map { $0.headingLine + $0.content }.joined()
    }

    public var titles: [String] { sections.map(\.title) }

    public func section(titled title: String) -> Section? {
        sections.first { Self.matches($0.title, title) }
    }

    /// Normalised content of a section, nil if absent.
    public func content(of title: String) -> String? {
        section(titled: title)?.trimmedContent
    }

    /// Replaces the content of the first section with that title (or appends a new section). Only that section's
    /// bytes change. `content` may use any line ending; it is written with the body's style.
    public mutating func setContent(_ content: String, of title: String) {
        let le = lineEnding.rawValue
        var lines = TextLines.split(content).map(\.content)
        while let first = lines.first, first.isBlankLine { lines.removeFirst() }
        while let last = lines.last, last.isBlankLine { lines.removeLast() }
        let bodyText = lines.joined(separator: le)
        if let index = sections.firstIndex(where: { Self.matches($0.title, title) }) {
            var newContent = le + (bodyText.isEmpty ? "" : bodyText + le)
            if index != sections.count - 1 { newContent += le }
            sections[index].content = newContent
        } else {
            ensureTrailingBlankLine()
            let heading = String(repeating: "#", count: level) + " " + title + le
            sections.append(Section(headingLine: heading, title: title,
                                     content: le + (bodyText.isEmpty ? "" : bodyText + le)))
        }
    }

    /// Removes a section. Returns false if absent.
    @discardableResult
    public mutating func removeSection(titled title: String) -> Bool {
        guard let index = sections.firstIndex(where: { Self.matches($0.title, title) }) else { return false }
        sections.remove(at: index)
        return true
    }

    private mutating func ensureTrailingBlankLine() {
        let addition = TextLines.blankLineSeparator(after: text, lineEnding: lineEnding)
        guard !addition.isEmpty else { return }
        if sections.isEmpty {
            preamble += addition
        } else {
            sections[sections.count - 1].content += addition
        }
    }

    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingWhitespace().lowercased() == rhs.trimmingWhitespace().lowercased()
    }

    static func headingTitle(_ content: String, level: Int) -> String? {
        let stripped = content.drop { $0 == " " }
        guard content.count - stripped.count <= 3 else { return nil }
        let hashes = stripped.prefix { $0 == "#" }
        guard hashes.count == level else { return nil }
        let rest = stripped.dropFirst(level)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var title = String(rest).trimmingWhitespace()
        // Optional closing sequence: "## Title ##".
        if let range = title.range(of: #"\s+#+$"#, options: .regularExpression) {
            title.removeSubrange(range)
        } else if title.allSatisfy({ $0 == "#" }) {
            title = ""
        }
        return title
    }

    static func normalized(_ content: String) -> String {
        var lines = TextLines.split(content).map { $0.content.trimmingTrailingWhitespace() }
        while let first = lines.first, first.isEmpty { lines.removeFirst() }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
