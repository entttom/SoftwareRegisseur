import Foundation
import SoftwareRegisseurDomain

/// Human-readable Markdown for the export (spec Q1, A34).
///
/// Deliberately not `SoftwareRegisseurMarkdown.RequestRenderer`: that renderer produces the repository
/// file of a request, needs a Mac-assigned human ID (inbox items have none) and has no place for the
/// original note, transcript and draft history the export must contain. The export Markdown keeps the
/// spec F3 frontmatter field names so it stays recognizable, but it is a read-only report, never a file
/// that is written into a repository.
enum ExportMarkdown {
    static func request(
        _ item: WorkItem, projectName: String?, drafts: [DraftVersion], timeZone: TimeZone
    ) -> String {
        var lines = ["---"]
        lines.append("uuid: " + quoted(item.uuid.uuidString.lowercased()))
        if let humanId = item.humanId { lines.append("id: \(humanId)") }
        lines.append("type: \(item.type.rawValue)")
        lines.append("status: \(item.status.rawValue)")
        lines.append("title: " + quoted(item.title))
        if let projectName { lines.append("project: " + quoted(projectName)) }
        lines.append("priority: \(item.priority.rawValue)")
        if let complexity = item.complexity { lines.append("complexity: \(complexity.rawValue)") }
        lines.append("labels: " + flowList(item.labels))
        lines.append("dependsOn: " + flowList(item.dependencies.map { $0.uuidString.lowercased() }))
        lines.append("agentJobIds: " + flowList(item.agentJobIds.map { $0.uuidString.lowercased() }))
        lines.append("reviewState: \(item.reviewState.rawValue)")
        lines.append("createdAt: " + quoted(timestamp(item.createdAt, timeZone)))
        lines.append("updatedAt: " + quoted(timestamp(item.updatedAt, timeZone)))
        if let archivedAt = item.archivedAt { lines.append("archivedAt: " + quoted(timestamp(archivedAt, timeZone))) }
        lines.append("revision: \(item.revision)")
        lines.append("---")
        lines.append("")
        let heading = item.humanId.map { "\($0): \(item.title)" } ?? item.title
        lines.append("# " + singleLine(heading))

        section(String(localized: "Inhalt", bundle: .module), item.structuredBody, into: &lines)
        section(String(localized: "Originalnotiz", bundle: .module), item.originalNote, into: &lines)
        if let transcript = item.transcript {
            section(String(localized: "Transkript", bundle: .module), transcript, into: &lines)
        }
        if !drafts.isEmpty {
            lines.append("")
            lines.append("## " + String(localized: "Entwurfsversionen", bundle: .module))
            for draft in drafts {
                lines.append("")
                var title = String(localized: "Version \(draft.version)", bundle: .module)
                    + " · " + draft.source.rawValue + " · " + timestamp(draft.createdAt, timeZone)
                if let provider = draft.providerId {
                    title += " · " + provider.rawValue + (draft.modelId.map { "/" + $0.rawValue } ?? "")
                }
                if draft.isAccepted { title += " · " + String(localized: "übernommen", bundle: .module) }
                lines.append("### " + title)
                if let text = draft.text, !text.isEmpty {
                    lines.append("")
                    lines.append(text)
                }
                for (index, content) in draft.contents.enumerated() {
                    lines.append("")
                    lines.append("#### " + String(localized: "Vorschlag \(index + 1)", bundle: .module)
                                 + ": " + singleLine(content.title) + " (" + content.classification.rawValue + ")")
                    field(String(localized: "Ziel", bundle: .module), content.goal, into: &lines)
                    field(String(localized: "Kontext", bundle: .module), content.context, into: &lines)
                    bullets(String(localized: "Akzeptanzkriterien", bundle: .module), content.acceptanceCriteria, into: &lines)
                    bullets(String(localized: "Technische Hinweise", bundle: .module), content.technicalNotes, into: &lines)
                    bullets(String(localized: "Testfälle", bundle: .module), content.testCases, into: &lines)
                    bullets(String(localized: "Abhängigkeiten", bundle: .module), content.dependencies, into: &lines)
                    bullets(String(localized: "Offene Fragen", bundle: .module), content.openQuestions, into: &lines)
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Same frontmatter keys and section headings as the repository ADR template (docs/adr/TEMPLATE.md).
    static func adr(_ adr: ADR, projectName: String?, timeZone: TimeZone) -> String {
        var lines = ["---"]
        lines.append("adr: \(adr.decisionNumber.formatted)")
        lines.append("title: " + quoted(adr.title))
        lines.append("status: \(adr.status.rawValue)")
        if let date = adr.date { lines.append("date: " + day(date, timeZone)) }
        if !adr.supersedes.isEmpty { lines.append("supersedes: " + flowList(adr.supersedes.map(\.formatted))) }
        if let supersededBy = adr.supersededBy { lines.append("supersededBy: \(supersededBy.formatted)") }
        if let projectName { lines.append("project: " + quoted(projectName)) }
        lines.append("uuid: " + quoted(adr.uuid.uuidString.lowercased()))
        lines.append("---")
        lines.append("")
        lines.append("# \(adr.decisionNumber.displayID): " + singleLine(adr.title))
        section(String(localized: "Kontext", bundle: .module), adr.context, into: &lines, keepEmpty: true)
        section(String(localized: "Entscheidung", bundle: .module), adr.decision, into: &lines, keepEmpty: true)
        section(String(localized: "Erwogene Alternativen", bundle: .module), adr.alternatives, into: &lines, keepEmpty: true)
        section(String(localized: "Konsequenzen", bundle: .module), adr.consequences, into: &lines, keepEmpty: true)
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Helpers

    private static func section(_ title: String, _ content: String, into lines: inout [String], keepEmpty: Bool = false) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard keepEmpty || !trimmed.isEmpty else { return }
        lines.append("")
        lines.append("## " + title)
        if !trimmed.isEmpty {
            lines.append("")
            lines.append(trimmed)
        }
    }

    private static func field(_ title: String, _ content: String, into lines: inout [String]) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lines.append("")
        lines.append("**\(title):** " + trimmed)
    }

    private static func bullets(_ title: String, _ items: [String], into lines: inout [String]) {
        let items = items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !items.isEmpty else { return }
        lines.append("")
        lines.append("**\(title):**")
        lines.append("")
        lines.append(contentsOf: items.map { "- " + singleLine($0) })
    }

    /// YAML double-quoted scalar (JSON string escaping is valid YAML).
    static func quoted(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04X", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    private static func flowList(_ items: [String]) -> String {
        "[" + items.map(quoted).joined(separator: ", ") + "]"
    }

    private static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    static func timestamp(_ date: Date, _ timeZone: TimeZone) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: timeZone))
    }

    static func day(_ date: Date, _ timeZone: TimeZone) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day())
    }

    /// File-system safe lowercase slug (ASCII letters/digits and `-`), at most `limit` characters.
    static func slug(_ text: String, limit: Int = 60) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "de_DE"))
            .replacingOccurrences(of: "ß", with: "ss").lowercased()
        var result = ""
        var lastWasDash = false
        for scalar in folded.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash, !result.isEmpty {
                result += "-"
                lastWasDash = true
            }
            if result.count >= limit { break }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result.isEmpty ? "ohne-titel" : result
    }
}
