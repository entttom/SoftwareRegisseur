import Foundation

/// Block-Struktur für die Markdown-Vorschau. SwiftUI rendert nur Inline-Markdown; Überschriften, Listen,
/// Zitate und Codeblöcke werden hier erkannt und von der Vorschau eigens dargestellt.
enum MarkdownBlock: Hashable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(String, depth: Int)
    case numbered(String, number: Int)
    case task(String, checked: Bool)
    case quote(String)
    case code(String, language: String?)
    case rule
    /// YAML-Frontmatter (wird eingeklappt angezeigt).
    case frontmatter(String)

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")[...]
        var paragraph: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph.removeAll()
            }
        }

        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
            blocks.append(.frontmatter(lines[lines.index(after: lines.startIndex)..<end].joined(separator: "\n")))
            lines = lines[lines.index(after: end)...]
        }

        var iterator = lines.makeIterator()
        while let rawLine = iterator.next() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(line.prefix(3))
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                while let next = iterator.next() {
                    if next.trimmingCharacters(in: .whitespaces).hasPrefix(fence) { break }
                    code.append(next)
                }
                blocks.append(.code(code.joined(separator: "\n"), language: language.isEmpty ? nil : language))
                continue
            }
            if line.isEmpty {
                flushParagraph()
                continue
            }
            if let heading = headingLevel(line) {
                flushParagraph()
                blocks.append(.heading(level: heading, text: String(line.dropFirst(heading)).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if line == "---" || line == "***" || line == "___" {
                flushParagraph()
                blocks.append(.rule)
                continue
            }
            if line.hasPrefix(">") {
                flushParagraph()
                blocks.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if let item = bulletItem(line) {
                flushParagraph()
                let depth = rawLine.prefix { $0 == " " || $0 == "\t" }.count / 2
                if item.hasPrefix("[ ] ") {
                    blocks.append(.task(String(item.dropFirst(4)), checked: false))
                } else if item.lowercased().hasPrefix("[x] ") {
                    blocks.append(.task(String(item.dropFirst(4)), checked: true))
                } else {
                    blocks.append(.bullet(item, depth: depth))
                }
                continue
            }
            if let (number, item) = numberedItem(line) {
                flushParagraph()
                blocks.append(.numbered(item, number: number))
                continue
            }
            paragraph.append(line)
        }
        flushParagraph()
        return blocks
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func bulletItem(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func numberedItem(_ line: String) -> (Int, String)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 4, let number = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (number, String(rest.dropFirst(2)))
    }
}

/// Zeile einer Diff-Darstellung.
struct DiffLine: Hashable, Sendable, Identifiable {
    enum Kind: Hashable, Sendable {
        case context
        case added
        case removed
        case hunk
        case header
    }

    var id: Int
    var kind: Kind
    var text: String
}

/// Unified-Diff (vom Dienst oder `git diff`) in klassifizierte Zeilen zerlegen.
enum UnifiedDiff {
    static func lines(_ diff: String, limit: Int = 20_000) -> [DiffLine] {
        var result: [DiffLine] = []
        for (index, line) in diff.components(separatedBy: "\n").prefix(limit).enumerated() {
            let kind: DiffLine.Kind
            if line.hasPrefix("@@") {
                kind = .hunk
            } else if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") {
                kind = .header
            } else if line.hasPrefix("+") {
                kind = .added
            } else if line.hasPrefix("-") {
                kind = .removed
            } else {
                kind = .context
            }
            result.append(DiffLine(id: index, kind: kind, text: line))
        }
        return result
    }

    static func stats(_ lines: [DiffLine]) -> (added: Int, removed: Int) {
        (lines.filter { $0.kind == .added }.count, lines.filter { $0.kind == .removed }.count)
    }
}

/// Zeilenweiser Vergleich zweier Texte nebeneinander (Dateikonflikte, N2: beide Stände sichtbar).
struct SideBySideRow: Hashable, Sendable, Identifiable {
    enum Change: Hashable, Sendable {
        case same
        case changed
        case onlyLeft
        case onlyRight
    }

    var id: Int
    var left: String?
    var right: String?
    var change: Change
}

enum SideBySideDiff {
    static func rows(left: String, right: String) -> [SideBySideRow] {
        let leftLines = left.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let rightLines = right.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let difference = rightLines.difference(from: leftLines)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        var rows: [SideBySideRow] = []
        var leftIndex = 0
        var rightIndex = 0
        while leftIndex < leftLines.count || rightIndex < rightLines.count {
            let leftRemoved = leftIndex < leftLines.count && removed.contains(leftIndex)
            let rightInserted = rightIndex < rightLines.count && inserted.contains(rightIndex)
            if leftRemoved && rightInserted {
                rows.append(SideBySideRow(id: rows.count, left: leftLines[leftIndex], right: rightLines[rightIndex], change: .changed))
                leftIndex += 1
                rightIndex += 1
            } else if leftRemoved {
                rows.append(SideBySideRow(id: rows.count, left: leftLines[leftIndex], right: nil, change: .onlyLeft))
                leftIndex += 1
            } else if rightInserted {
                rows.append(SideBySideRow(id: rows.count, left: nil, right: rightLines[rightIndex], change: .onlyRight))
                rightIndex += 1
            } else if leftIndex < leftLines.count, rightIndex < rightLines.count {
                rows.append(SideBySideRow(id: rows.count, left: leftLines[leftIndex], right: rightLines[rightIndex], change: .same))
                leftIndex += 1
                rightIndex += 1
            } else if leftIndex < leftLines.count {
                rows.append(SideBySideRow(id: rows.count, left: leftLines[leftIndex], right: nil, change: .onlyLeft))
                leftIndex += 1
            } else {
                rows.append(SideBySideRow(id: rows.count, left: nil, right: rightLines[rightIndex], change: .onlyRight))
                rightIndex += 1
            }
        }
        return rows
    }
}

/// JSON-Nutzdaten (Sync-Konflikte) lesbar formatieren.
enum PrettyJSON {
    static func format(_ data: Data?) -> String {
        guard let data else { return String(localized: "(gelöscht)") }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8)
        else { return String(decoding: data, as: UTF8.self) }
        return text
    }
}
