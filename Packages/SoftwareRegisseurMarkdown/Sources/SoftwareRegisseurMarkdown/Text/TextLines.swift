/// Line ending style of a text file. Edits reuse the file's own style (spec F3: no destructive reformatting).
public enum LineEnding: String, Sendable, Hashable, Codable {
    case lf = "\n"
    case crlf = "\r\n"

    /// Detects the style from the first line terminator; defaults to LF for single-line text.
    public static func detect(in text: String) -> LineEnding {
        var previousWasCR = false
        for byte in text.utf8 {
            if byte == 0x0A { return previousWasCR ? .crlf : .lf }
            previousWasCR = byte == 0x0D
        }
        return .lf
    }
}

/// One physical line including its original terminator ("" for the last line without newline).
struct TextLine: Sendable, Hashable {
    var content: String
    var terminator: String

    var raw: String { content + terminator }

    /// Content with trailing spaces/tabs removed; used for marker comparisons.
    var trimmedContent: String { content.trimmingWhitespace() }
}

enum TextLines {
    /// Splits on LF, keeping "\r\n" / "\n" as terminators. Works on UTF-8 so "\r\n" (a single Character) never
    /// confuses the split. `split(text).map(\.raw).joined() == text` holds byte for byte.
    static func split(_ text: String) -> [TextLine] {
        var lines: [TextLine] = []
        let utf8 = text.utf8
        var lineStart = utf8.startIndex
        var index = utf8.startIndex
        while index != utf8.endIndex {
            if utf8[index] == 0x0A {
                var contentEnd = index
                if contentEnd > lineStart {
                    let previous = utf8.index(before: contentEnd)
                    if utf8[previous] == 0x0D { contentEnd = previous }
                }
                let next = utf8.index(after: index)
                lines.append(TextLine(
                    content: slice(text, lineStart, contentEnd),
                    terminator: slice(text, contentEnd, next)
                ))
                lineStart = next
            }
            index = utf8.index(after: index)
        }
        if lineStart != utf8.endIndex {
            lines.append(TextLine(content: slice(text, lineStart, utf8.endIndex), terminator: ""))
        }
        return lines
    }

    /// Scalar-exact slice (String subscripts may round to Character boundaries).
    static func slice(_ text: String, _ from: String.Index, _ to: String.Index) -> String {
        String(Substring(text.unicodeScalars[from..<to]))
    }

    /// What to append so that new content starts after exactly one blank line ("" if one already exists).
    static func blankLineSeparator(after text: String, lineEnding: LineEnding) -> String {
        let lines = split(text)
        guard let last = lines.last, !lines.allSatisfy({ $0.content.isBlankLine }) else { return "" }
        if last.terminator.isEmpty { return lineEnding.rawValue + lineEnding.rawValue }
        return last.content.isBlankLine ? "" : lineEnding.rawValue
    }

    static func join(_ lines: [TextLine]) -> String {
        lines.map(\.raw).joined()
    }
}

extension String {
    func trimmingWhitespace() -> String {
        var scalars = Substring(self).unicodeScalars
        while let first = scalars.first, first == " " || first == "\t" { scalars.removeFirst() }
        while let last = scalars.last, last == " " || last == "\t" { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }

    var isBlankLine: Bool { trimmingWhitespace().isEmpty }

    /// Byte-wise equality (Swift `==` uses canonical equivalence, which is too lenient for lossless checks).
    func isByteIdentical(to other: String) -> Bool {
        utf8.elementsEqual(other.utf8)
    }
}

/// Tracks fenced code blocks (``` or ~~~) so markers/headings inside examples are ignored.
struct FenceTracker {
    private var openFence: (character: Character, count: Int)?

    var isInsideFence: Bool { openFence != nil }

    /// Feeds one line; returns true if the line is part of a fenced block (including the fence lines).
    mutating func consume(_ content: String) -> Bool {
        let stripped = content.drop { $0 == " " }
        guard content.count - stripped.count <= 3, let first = stripped.first, first == "`" || first == "~" else {
            return isInsideFence
        }
        let run = stripped.prefix { $0 == first }.count
        guard run >= 3 else { return isInsideFence }
        if let open = openFence {
            if open.character == first, run >= open.count,
               stripped.dropFirst(run).allSatisfy({ $0 == " " || $0 == "\t" }) {
                openFence = nil
            }
            return true
        }
        openFence = (first, run)
        return true
    }
}
