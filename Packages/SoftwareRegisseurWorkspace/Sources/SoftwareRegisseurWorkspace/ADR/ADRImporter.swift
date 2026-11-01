import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurMarkdown
import SoftwareRegisseurPersistence

/// Result of indexing a project's ADR folder (spec F4, E3).
public struct ADRImportReport: Sendable, Hashable {
    public var imported: [ADRNumber] = []
    public var updated: [ADRNumber] = []
    public var unchanged: [ADRNumber] = []
    /// Repository-relative path → reason (kept as-is, manual mapping, spec E3).
    public var incompatible: [String: String] = [:]
    /// Non-fatal remarks (e.g. `rejected` mapped to `deprecated`, invalid status transition from the file).
    public var warnings: [String: [String]] = [:]
}

/// Indexes existing ADRs into the database, preserving their numbers (ADR-0018: own range, never reused).
/// ADR files are never rewritten here; ADRs are never interpreted as feature requests (spec F4).
public struct ADRImporter: Sendable {
    /// Files in the ADR folder that are not ADRs.
    public static let ignoredFileNames: Set<String> = ["readme.md", "template.md", "index.md", "_template.md", "adr-template.md"]

    let environment: WorkspaceEnvironment

    public init(environment: WorkspaceEnvironment) {
        self.environment = environment
    }

    @discardableResult
    public func importADRs(projectId: ProjectID) async throws -> ADRImportReport {
        let database = environment.database
        let root = try await environment.projectRoot(projectId)
        let layout = try await environment.layout(projectId)
        let folder = root.appendingRelative(layout.adrPath.string)
        var report = ADRImportReport()
        var seenNumbers: [Int: String] = [:]
        let now = environment.now()

        for relative in FileSystem.markdownFiles(in: folder, relativeTo: root, recursive: false) {
            let fileName = (relative as NSString).lastPathComponent
            if Self.ignoredFileNames.contains(fileName.lowercased()) { continue }
            guard let data = FileSystem.read(relative, in: root) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            let existingRecord = try await database.documentFiles.fetch(projectId: projectId, relativePath: relative)

            switch ADRParser.parse(fileName: fileName, text: text) {
            case let .incompatible(reason):
                report.incompatible[relative] = reason.description
                try await database.documentFiles.upsert(DocumentFileRecord(
                    projectId: projectId, relativePath: relative, kind: .adr, entityId: existingRecord?.entityId, content: text,
                    entityRevision: nil, compatibility: .incompatible, issue: reason.description, updatedAt: now
                ))
            case let .compatible(record):
                if let other = seenNumbers[record.number] {
                    let issue = "Nummer \(ADRNumbering.format(record.number)) doppelt (auch \(other))"
                    report.incompatible[relative] = issue
                    try await database.documentFiles.upsert(DocumentFileRecord(
                        projectId: projectId, relativePath: relative, kind: .adr, entityId: nil, content: text,
                        entityRevision: nil, compatibility: .incompatible, issue: issue, updatedAt: now
                    ))
                    continue
                }
                seenNumbers[record.number] = relative
                if existingRecord?.contentHash == DocumentFileRecord.hash(data), existingRecord?.compatibility == .compatible,
                   let entityId = existingRecord?.entityId, try await database.adrs.fetch(ADRID(entityId)) != nil {
                    if let number = try? ADRNumber(record.number) { report.unchanged.append(number) }
                    continue
                }
                var warnings = record.warnings
                if record.status == .rejected { warnings.append(String(localized: "Status „rejected“ als „deprecated“ übernommen", bundle: .module)) }
                let adr = try await upsert(record, text: text, projectId: projectId, warnings: &warnings, report: &report)
                if !warnings.isEmpty { report.warnings[relative] = warnings }
                try await database.documentFiles.upsert(DocumentFileRecord(
                    projectId: projectId, relativePath: relative, kind: .adr, entityId: adr.uuid.rawValue, content: text,
                    entityRevision: adr.revision, compatibility: .compatible,
                    issue: warnings.isEmpty ? nil : warnings.joined(separator: "; "), updatedAt: now
                ))
            }
        }
        return report
    }

    private func upsert(
        _ record: ADRRecord, text: String, projectId: ProjectID, warnings: inout [String], report: inout ADRImportReport
    ) async throws -> ADR {
        let database = environment.database
        let number = try ADRNumber(record.number)
        let status = MarkdownDomainBridge.domain(record.status)
        let sections = MarkdownSections(parsing: FrontmatterDocument(text: text).body)
        func section(_ names: [String]) -> String {
            names.lazy.compactMap { sections.content(of: $0) }.first ?? ""
        }
        let context = section(["Kontext", "Context", "Context and Problem Statement"])
        let decision = section(["Entscheidung", "Decision", "Decision Outcome"])
        let alternatives = section(["Erwogene Alternativen", "Alternativen", "Considered Options", "Alternatives"])
        let consequences = section(["Konsequenzen", "Folgen", "Consequences"])
        let date = record.date.flatMap(Self.parseDate)
        let supersedes = record.supersedes.compactMap { try? ADRNumber($0) }
        let supersededBy = record.supersededBy.flatMap { try? ADRNumber($0) }
        let now = environment.now()

        guard let existing = try await database.adrs.fetch(projectId: projectId, number: number) else {
            let adr = ADR(
                projectId: projectId, decisionNumber: number, title: record.title, status: status, date: date,
                context: context, decision: decision, alternatives: alternatives, consequences: consequences,
                supersedes: supersedes, supersededBy: supersededBy, createdAt: now
            )
            try await database.adrs.insert(adr, at: now)
            report.imported.append(number)
            return adr
        }
        var adr = existing
        adr.title = record.title
        adr.date = date ?? existing.date
        adr.context = context
        adr.decision = decision
        adr.alternatives = alternatives
        adr.consequences = consequences
        adr.supersedes = supersedes
        adr.supersededBy = supersededBy
        if status != existing.status {
            do {
                try adr.transition(to: status, at: now)
            } catch {
                warnings.append(String(localized: "Statuswechsel \(existing.status.rawValue) → \(status.rawValue) nicht zulässig; Datenbankstatus bleibt", bundle: .module))
            }
        }
        guard adr != existing else {
            report.unchanged.append(number)
            return existing
        }
        let saved = try await database.adrs.update(adr, expectedRevision: existing.revision, at: now)
        report.updated.append(number)
        return saved
    }

    static func parseDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let date = try? Date(trimmed, strategy: Date.ISO8601FormatStyle().year().month().day()) { return date }
        return RequestTimestamp.parse(trimmed)
    }
}
