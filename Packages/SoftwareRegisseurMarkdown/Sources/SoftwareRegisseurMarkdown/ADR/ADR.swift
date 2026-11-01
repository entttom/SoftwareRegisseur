import Foundation

/// ADR status (spec F4). `rejected` is accepted on read because MADR uses it.
public enum ADRStatus: String, Sendable, Hashable, Codable, CaseIterable {
    case proposed
    case accepted
    case deprecated
    case superseded
    case rejected

    /// Parses English and German status words ("Accepted", "angenommen", "superseded by ADR-0005").
    public init?(text: String) {
        let word = text.trimmingWhitespace().lowercased()
            .prefix { $0.isLetter }
        switch word {
        case "proposed", "vorgeschlagen", "draft", "entwurf": self = .proposed
        case "accepted", "angenommen", "akzeptiert": self = .accepted
        case "deprecated", "veraltet": self = .deprecated
        case "superseded", "ersetzt", "abgelöst": self = .superseded
        case "rejected", "abgelehnt": self = .rejected
        default: return nil
        }
    }
}

public enum ADRFormat: Sendable, Hashable {
    /// YAML frontmatter with `adr`, `title`, `status`, `date` (this repository's convention).
    case frontmatter
    /// No frontmatter; MADR-style `Status: …` line or `## Status` section.
    case madr
}

public struct ADRRecord: Sendable, Hashable {
    public var number: Int
    public var title: String
    public var status: ADRStatus
    public var date: String?
    public var supersedes: [Int]
    public var supersededBy: Int?
    public var format: ADRFormat
    public var fileName: String
    /// Non-fatal inconsistencies, e.g. frontmatter number differs from file name.
    public var warnings: [String]
}

public enum ADRIncompatibility: Sendable, Hashable, CustomStringConvertible {
    case malformedFrontmatter(String)
    case missingNumber
    case invalidNumber(String)
    case missingStatus
    case unknownStatus(String)

    public var description: String {
        switch self {
        case let .malformedFrontmatter(message): "malformed frontmatter: \(message)"
        case .missingNumber: "no ADR number in frontmatter or file name (NNNN-title.md)"
        case let .invalidNumber(value): "invalid ADR number '\(value)'"
        case .missingStatus: "no status found"
        case let .unknownStatus(value): "unknown status '\(value)'"
        }
    }
}

public enum ADRParseResult: Sendable, Hashable {
    case compatible(ADRRecord)
    /// Spec E3: incompatible documents are marked as such for manual mapping, never rewritten.
    case incompatible(ADRIncompatibility)

    public var record: ADRRecord? {
        if case let .compatible(record) = self { return record }
        return nil
    }
}

public enum ADRParser {
    public static func parse(fileName: String, text: String) -> ADRParseResult {
        let document = FrontmatterDocument(text: text)
        let fileNumber = ADRNumbering.number(fromFileName: fileName)
        var warnings: [String] = []

        switch document.state {
        case .unterminated:
            return .incompatible(.malformedFrontmatter("missing closing ---"))
        case .present:
            for diagnostic in document.diagnostics {
                switch diagnostic {
                case let .malformedYAML(message): return .incompatible(.malformedFrontmatter(message))
                case .frontmatterNotAMapping: return .incompatible(.malformedFrontmatter("not a mapping"))
                case let .duplicateKey(key): return .incompatible(.malformedFrontmatter("duplicate key '\(key)'"))
                case .missingFrontmatter, .unterminatedFrontmatter: break
                }
            }
        case .absent:
            break
        }

        let body = MarkdownBodyScan(document.body)
        let hasFrontmatterFields = document.values["adr"] != nil || document.values["status"] != nil

        // Number
        var number = fileNumber
        if let raw = document.values["adr"]?.scalarString {
            guard let parsed = ADRNumbering.parseNumber(raw) else { return .incompatible(.invalidNumber(raw)) }
            if let fileNumber, fileNumber != parsed {
                warnings.append("frontmatter adr \(parsed) differs from file name number \(fileNumber)")
            }
            number = parsed
        }
        guard let number else { return .incompatible(.missingNumber) }

        // Status
        let statusText = document.values["status"]?.scalarString ?? body.statusText
        guard let statusText, !statusText.trimmingWhitespace().isEmpty else { return .incompatible(.missingStatus) }
        guard let status = ADRStatus(text: statusText) else { return .incompatible(.unknownStatus(statusText)) }
        var supersededBy: Int?
        if status == .superseded,
           let match = statusText.firstMatch(of: /(?i)(?:by|durch)\D*([0-9]+)/) {
            supersededBy = Int(match.1)
        }

        // Title
        let title = document.values["title"]?.scalarString?.trimmingWhitespace()
            ?? body.title
            ?? ADRNumbering.titleFromFileName(fileName)

        var supersedes: [Int] = []
        switch document.values["supersedes"] {
        case let .scalar(value)?: supersedes = ADRNumbering.parseNumber(value).map { [$0] } ?? []
        case let .sequence(items)?: supersedes = items.compactMap { $0.scalarString.flatMap(ADRNumbering.parseNumber) }
        default: break
        }

        return .compatible(ADRRecord(
            number: number,
            title: title,
            status: status,
            date: document.values["date"]?.scalarString ?? body.dateText,
            supersedes: supersedes,
            supersededBy: supersededBy,
            format: hasFrontmatterFields ? .frontmatter : .madr,
            fileName: fileName,
            warnings: warnings
        ))
    }
}

/// Extracts title / status / date from a Markdown body (MADR and "**Status:** Accepted" variants).
struct MarkdownBodyScan {
    var title: String?
    var statusText: String?
    var dateText: String?

    init(_ body: String) {
        var fence = FenceTracker()
        var currentSection: String?
        for line in TextLines.split(body) {
            if fence.consume(line.content) { continue }
            let content = line.content.trimmingWhitespace()
            if title == nil, let heading = MarkdownSections.headingTitle(content, level: 1) {
                title = Self.stripADRPrefix(heading)
                continue
            }
            if let heading = MarkdownSections.headingTitle(content, level: 2) {
                currentSection = heading.lowercased()
                continue
            }
            let plain = content.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "__", with: "")
                .trimmingWhitespace()
            if plain.isEmpty { continue }
            if let section = currentSection, ["status", "stand"].contains(section) {
                if statusText == nil { statusText = Self.stripBullet(plain) }
                continue
            }
            if let section = currentSection, ["date", "datum"].contains(section) {
                if dateText == nil { dateText = Self.stripBullet(plain) }
                continue
            }
            if statusText == nil, let match = plain.wholeMatch(of: /(?i)[-*]?\s*status\s*:\s*(.+)/) {
                statusText = String(match.1)
            } else if dateText == nil, let match = plain.wholeMatch(of: /(?i)[-*]?\s*(?:date|datum)\s*:\s*(.+)/) {
                dateText = String(match.1).trimmingWhitespace()
            }
        }
    }

    static func stripBullet(_ text: String) -> String {
        var result = Substring(text)
        if result.hasPrefix("- ") || result.hasPrefix("* ") { result = result.dropFirst(2) }
        return String(result).trimmingWhitespace()
    }

    /// "ADR-0004: Title", "4. Title", "0004 - Title" → "Title".
    static func stripADRPrefix(_ heading: String) -> String {
        if let match = heading.wholeMatch(of: /(?i)(?:ADR[-\s]?)?[0-9]+\s*[:.\-–]\s*(.+)/) {
            return String(match.1).trimmingWhitespace()
        }
        return heading
    }
}

/// ADR numbering and file names (spec F4: `NNNN-kurzer-titel.md`; ADR-0018: own number range, no prefix).
public enum ADRNumbering {
    public static func number(fromFileName fileName: String) -> Int? {
        guard let match = fileName.wholeMatch(of: /([0-9]{1,9})-.*\.md/) else { return nil }
        return Int(match.1)
    }

    /// Accepts "0004", "4", "ADR-0004".
    public static func parseNumber(_ raw: String) -> Int? {
        guard let match = raw.trimmingWhitespace().wholeMatch(of: /(?i)(?:ADR[-\s]?)?([0-9]{1,9})/) else { return nil }
        return Int(match.1)
    }

    public static func nextNumber(fileNames: some Sequence<String>) -> Int {
        (fileNames.compactMap(number(fromFileName:)).max() ?? 0) + 1
    }

    public static func format(_ number: Int) -> String {
        HumanID.pad(number)
    }

    public static func fileName(number: Int, title: String) -> String {
        let slug = Slug.make(from: title)
        return slug.isEmpty ? "\(format(number)).md" : "\(format(number))-\(slug).md"
    }

    static func titleFromFileName(_ fileName: String) -> String {
        guard let match = fileName.wholeMatch(of: /[0-9]+-(.*)\.md/) else { return fileName }
        return match.1.replacingOccurrences(of: "-", with: " ")
    }
}

/// Creates a new ADR from the repository's `TEMPLATE.md` (spec F4, AGENTS.md rule 9). Only the placeholder
/// lines change; everything else in the template is kept verbatim.
public enum ADRTemplate {
    /// Fallback when a repository has no template (copy of this repository's docs/adr/TEMPLATE.md).
    public static let defaultTemplate = """
    ---
    adr: NNNN
    title: "Kurzer Entscheidungstitel"
    status: proposed
    date: YYYY-MM-DD
    # supersedes: 0000
    ---

    # ADR-NNNN: Kurzer Entscheidungstitel

    ## Kontext

    Welches Problem / welche Randbedingungen führen zu einer Architekturentscheidung?

    ## Entscheidung

    Welche konkrete technische Entscheidung wurde getroffen?

    ## Erwogene Alternativen

    Welche Optionen wurden verworfen und warum?

    ## Konsequenzen

    Welche positiven und negativen Folgen sind zu erwarten?

    ## Verifikation / Akzeptanz

    Wie wird die Entscheidung implementiert und nachgewiesen?

    ## Verweise

    Welche Anforderungen, Tests und Vorgänger-ADRs sind relevant?

    """

    public static func dateString(_ date: Date, timeZone: TimeZone) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day())
    }

    /// New ADRs start as `proposed` (spec F4: acceptance only by user approval).
    public static func render(
        template: String = defaultTemplate, number: Int, title: String, date: String,
        status: ADRStatus = .proposed, supersedes: [Int] = []
    ) throws(FrontmatterError) -> String {
        var document = FrontmatterDocument(text: template)
        let numberString = ADRNumbering.format(number)
        try document.setScalar(key: "adr", value: numberString, style: .plain)
        try document.setScalar(key: "title", value: title)
        try document.setScalar(key: "status", value: status.rawValue)
        try document.setScalar(key: "date", value: date, style: .plain)
        if !supersedes.isEmpty {
            let values = supersedes.map(ADRNumbering.format)
            let rendered = values.count == 1 ? values[0] : "[" + values.joined(separator: ", ") + "]"
            let replaced = document.replaceComment(
                matching: { String($0.dropFirst()).trimmingWhitespace().hasPrefix("supersedes:") },
                withLine: "supersedes: " + rendered
            )
            if !replaced {
                if values.count == 1 {
                    try document.setScalar(key: "supersedes", value: values[0], style: .plain)
                } else {
                    try document.setList(key: "supersedes", values: values)
                }
            }
        }
        // Replace the first H1 (template placeholder) or add one.
        var lines = TextLines.split(document.body)
        let heading = "# ADR-\(numberString): \(title)"
        var fence = FenceTracker()
        var replacedHeading = false
        for index in lines.indices {
            if fence.consume(lines[index].content) { continue }
            if MarkdownSections.headingTitle(lines[index].content, level: 1) != nil {
                lines[index].content = heading
                replacedHeading = true
                break
            }
        }
        if !replacedHeading {
            let le = document.lineEnding.rawValue
            lines.insert(contentsOf: [
                TextLine(content: "", terminator: le),
                TextLine(content: heading, terminator: le),
                TextLine(content: "", terminator: le),
            ], at: 0)
        }
        document.body = TextLines.join(lines)
        return document.text
    }
}
