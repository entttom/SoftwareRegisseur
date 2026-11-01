import Foundation
import SoftwareRegisseurMarkdown

/// Neuer ADR-Entwurf (F4): startet immer als `proposed`; angenommen wird nur durch ausdrückliche
/// Benutzerentscheidung. Die Datei entsteht aus der `TEMPLATE.md` des Repositorys (AGENTS.md Regel 9).
struct ADRDraftInput: Hashable, Sendable {
    var number: Int
    var title: String
    var context = ""
    var decision = ""
    var alternatives = ""
    var consequences = ""
    var supersedes: [Int] = []

    var fileName: String { ADRNumbering.fileName(number: number, title: title) }

    var isComplete: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && number > 0
    }

    /// Markdown-Text des Entwurfs. `template` ist der Inhalt der Projektvorlage, sonst die Standardvorlage.
    func render(template: String?, date: Date, timeZone: TimeZone = .current) throws -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = try ADRTemplate.render(
            template: template ?? ADRTemplate.defaultTemplate, number: number, title: title,
            date: ADRTemplate.dateString(date, timeZone: timeZone), status: .proposed, supersedes: supersedes
        )
        for (heading, value) in [("Kontext", context), ("Entscheidung", decision),
                                 ("Erwogene Alternativen", alternatives), ("Konsequenzen", consequences)] {
            text = Self.replaceSection(heading, with: value, in: text)
        }
        return text
    }

    /// Ersetzt den Inhalt unter `## <heading>` bis zur nächsten Überschrift gleicher oder höherer Ebene.
    /// Leere Eingaben lassen den Vorlagentext unverändert.
    static func replaceSection(_ heading: String, with value: String, in text: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        var lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## \(heading)" }) else {
            return text
        }
        var end = start + 1
        while end < lines.count, !(lines[end].hasPrefix("## ") || lines[end].hasPrefix("# ")) {
            end += 1
        }
        lines.replaceSubrange((start + 1)..<end, with: [""] + trimmed.components(separatedBy: "\n") + [""])
        return lines.joined(separator: "\n")
    }

    /// Nächste freie Nummer aus bekannten ADR-Nummern und Dateinamen im ADR-Ordner.
    static func nextNumber(knownNumbers: [Int], fileNames: [String]) -> Int {
        max(knownNumbers.max() ?? 0, ADRNumbering.nextNumber(fileNames: fileNames) - 1) + 1
    }
}

/// Eingaben der Ordnerstruktur eines Projekts (F2). Prüft nur die Form; die Kollisionsprüfung macht die
/// Migrationsvorschau des Dienstes.
struct FolderLayoutForm: Hashable, Sendable {
    var adrPath: String
    var requestsRoot: String
    var openPath: String
    var activePath: String
    var reviewPath: String
    var donePath: String

    var problems: [String] {
        var result: [String] = []
        let all = [adrPath, requestsRoot, openPath, activePath, reviewPath, donePath]
        if all.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            result.append(String(localized: "Alle Ordner müssen einen Namen haben."))
        }
        if all.contains(where: { $0.hasPrefix("/") || $0.hasPrefix("~") }) {
            result.append(String(localized: "Pfade müssen relativ zum Repository sein."))
        }
        if all.contains(where: { $0.split(separator: "/").contains("..") }) {
            result.append(String(localized: "Pfade dürfen das Repository nicht verlassen („..“)."))
        }
        let statusFolders = [openPath, activePath, reviewPath, donePath].map { $0.trimmingCharacters(in: .whitespaces) }
        if Set(statusFolders).count != statusFolders.count {
            result.append(String(localized: "Die Statusordner müssen unterschiedlich sein."))
        }
        return result
    }

    var isValid: Bool { problems.isEmpty }
}
