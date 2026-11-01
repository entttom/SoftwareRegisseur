import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC
import SoftwareRegisseurMarkdown
import SoftwareRegisseurPersistence
import SoftwareRegisseurWorkspace

/// ADRs aus der Mac-UI (seit Protokoll 3; F4, ADR-0018, ADR-0024).
///
/// - Neue Entwürfe: Nummer vom Mac aus dem eigenen ADR-Nummernkreis (`allocateADRNumber`, nie doppelt),
///   Text aus der `TEMPLATE.md` des Repositorys, Status `proposed`, atomar neu geschrieben (nie
///   überschrieben) und **nicht** committet.
/// - Statuswechsel nur auf ausdrücklichen Befehl. Geändert werden nur die betroffenen Frontmatter-Zeilen
///   (`status`, beim Ersetzen zusätzlich `supersedes` im ersetzenden ADR); der übrige Text bleibt Byte für
///   Byte erhalten. Die Datenbank übernimmt den Stand anschließend über den regulären Import.
extension ServiceRuntime {
    func createADR(_ command: CreateADRCommand) async throws -> ADRCreatedInfo {
        let title = command.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ServiceError.titleMissing }
        try await requireUsableProject(command.projectId)
        for number in command.supersedes {
            guard let value = try? ADRNumber(number),
                  try await database.adrs.fetch(projectId: command.projectId, number: value) != nil else {
                throw ServiceError.adrSupersedingMissing(number)
            }
        }
        let root = try await environment.projectRoot(command.projectId)
        let layout = try await environment.layout(command.projectId)
        let folder = layout.adrPath.isRoot ? root : root.appending(path: layout.adrPath.string, directoryHint: .isDirectory)
        let fileNames = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        let existing = fileNames.compactMap(ADRNumbering.number(fromFileName:)).compactMap { try? ADRNumber($0) }
        let now = clock.now()
        let number = try await database.humanIDs.allocateADRNumber(projectId: command.projectId, existing: existing, at: now)

        let templateURL = folder.appending(path: "TEMPLATE.md", directoryHint: .notDirectory)
        let template = (try? String(contentsOf: templateURL, encoding: .utf8)) ?? ADRTemplate.defaultTemplate
        var text = try ADRTemplate.render(
            template: template, number: number.value, title: title,
            date: ADRTemplate.dateString(now, timeZone: environment.timeZone), status: .proposed,
            supersedes: Array(Set(command.supersedes)).sorted())
        for (heading, value) in [("Kontext", command.context), ("Entscheidung", command.decision),
                                 ("Erwogene Alternativen", command.alternatives), ("Konsequenzen", command.consequences)] {
            text = Self.replaceSection(heading, with: value, in: text)
        }
        let fileName = ADRNumbering.fileName(number: number.value, title: title)
        let relative = layout.adrPath.isRoot ? fileName : layout.adrPath.string + "/" + fileName
        // Nie überschreiben: exklusives Umbenennen schlägt fehl, falls die Datei inzwischen existiert.
        try AtomicFileWriter.write(Data(text.utf8), to: root.appending(path: relative, directoryHint: .notDirectory), mode: .createNew,
                                   confinedTo: root)
        ServiceLog.workspace.notice("ADR \(number.formatted, privacy: .public) als Entwurf angelegt (nicht committet)")

        let reconciliation = await repositorySync.reconcile(projectId: command.projectId)
        if let error = reconciliation.error {
            ServiceLog.workspace.error("ADR-Abgleich: \(ServiceLog.redact(error), privacy: .private)")
        }
        let adrId = try await database.documentFiles.fetch(projectId: command.projectId, relativePath: relative)?.entityId.map { ADRID($0) }
        sendSoon()
        return ADRCreatedInfo(projectId: command.projectId, number: number.value, relativePath: relative, adrId: adrId)
    }

    /// Ausdrücklicher Statuswechsel (F4: Annahme nur durch Benutzerentscheidung).
    func changeADRStatus(_ adrId: ADRID, expectedRevision: Int, to status: SoftwareRegisseurDomain.ADRStatus,
                         supersededBy: Int?) async throws -> String {
        guard let adr = try await database.adrs.fetch(adrId) else { throw ServiceError.adrNotFound(adrId) }
        guard adr.revision == expectedRevision else {
            throw StoreError.revisionConflict(entity: .adr, id: adrId.uuidString, expected: expectedRevision, actual: adr.revision)
        }
        guard adr.status.canTransition(to: status) else { throw ServiceError.adrTransitionNotAllowed(from: adr.status, to: status) }
        let root = try await environment.projectRoot(adr.projectId)
        var edits: [(path: String, original: Data, updated: Data)] = []

        var document = try await Self.loadADRDocument(adr, root: root, database: database)
        if status == .superseded {
            guard let supersededBy else { throw ServiceError.adrStatusRequiresCommand(status) }
            guard let number = try? ADRNumber(supersededBy), number != adr.decisionNumber,
                  let successor = try await database.adrs.fetch(projectId: adr.projectId, number: number) else {
                throw ServiceError.adrSupersedingMissing(supersededBy)
            }
            try document.document.setScalar(key: "status", value: "superseded by \(ADRNumbering.format(supersededBy))")
            var successorDocument = try await Self.loadADRDocument(successor, root: root, database: database)
            var numbers = Self.supersedesNumbers(successorDocument.document)
            if !numbers.contains(adr.decisionNumber.value) { numbers.append(adr.decisionNumber.value) }
            let values = numbers.sorted().map(ADRNumbering.format)
            if values.count == 1, case .sequence? = successorDocument.document.values["supersedes"] {
                try successorDocument.document.setList(key: "supersedes", values: values)
            } else if values.count == 1 {
                try successorDocument.document.setScalar(key: "supersedes", value: values[0], style: .plain)
            } else {
                try successorDocument.document.setList(key: "supersedes", values: values)
            }
            edits.append((successorDocument.path, successorDocument.original, successorDocument.document.data))
        } else {
            try document.document.setScalar(key: "status", value: status.rawValue)
        }
        edits.insert((document.path, document.original, document.document.data), at: 0)

        // Erst alle Texte vorbereiten, dann schreiben – jeweils nur, wenn die Datei unverändert ist.
        for edit in edits where edit.updated != edit.original {
            try AtomicFileWriter.write(edit.updated, to: root.appending(path: edit.path, directoryHint: .notDirectory),
                                       mode: .replace(expectedHash: DocumentFileRecord.hash(edit.original)), confinedTo: root)
        }
        ServiceLog.workspace.notice("ADR \(adr.decisionNumber.formatted, privacy: .public): Status \(status.rawValue, privacy: .public) (nicht committet)")
        let reconciliation = await repositorySync.reconcile(projectId: adr.projectId)
        sendSoon()
        if let error = reconciliation.error { return "Datei geändert; der Abgleich meldet: \(ServiceLog.redact(error))" }
        let label = switch status {
        case .accepted: "angenommen"
        case .deprecated: "als veraltet markiert"
        case .superseded: "als ersetzt markiert"
        case .proposed: "vorgeschlagen"
        }
        return "ADR \(adr.decisionNumber.formatted) \(label). Die Datei wurde geändert, aber nicht committet."
    }

    // MARK: Hilfen

    struct LoadedADRDocument {
        var path: String
        var original: Data
        var document: FrontmatterDocument
    }

    static func loadADRDocument(_ adr: ADR, root: URL, database: AppDatabase) async throws -> LoadedADRDocument {
        guard let record = try await database.documentFiles.fetch(entityId: adr.uuid.rawValue) else {
            throw ServiceError.adrFileMissing(adr.decisionNumber.formatted)
        }
        let url = root.appending(path: record.relativePath, directoryHint: .notDirectory)
        guard let data = FileManager.default.contents(atPath: url.path(percentEncoded: false)) else {
            throw ServiceError.adrFileMissing(record.relativePath)
        }
        let document = FrontmatterDocument(text: String(decoding: data, as: UTF8.self))
        guard document.state == .present else { throw ServiceError.adrWithoutFrontmatter(record.relativePath) }
        return LoadedADRDocument(path: record.relativePath, original: data, document: document)
    }

    static func supersedesNumbers(_ document: FrontmatterDocument) -> [Int] {
        switch document.values["supersedes"] {
        case let .scalar(value)?: ADRNumbering.parseNumber(value).map { [$0] } ?? []
        case let .sequence(items)?: items.compactMap { $0.scalarString.flatMap(ADRNumbering.parseNumber) }
        default: []
        }
    }

    /// Ersetzt den Inhalt unter `## <heading>` bis zur nächsten Überschrift; leere Eingaben lassen die Vorlage.
    static func replaceSection(_ heading: String, with value: String, in text: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        var lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## \(heading)" }) else { return text }
        var end = start + 1
        while end < lines.count, !(lines[end].hasPrefix("## ") || lines[end].hasPrefix("# ")) { end += 1 }
        lines.replaceSubrange((start + 1)..<end, with: [""] + trimmed.components(separatedBy: "\n") + [""])
        return lines.joined(separator: "\n")
    }
}
