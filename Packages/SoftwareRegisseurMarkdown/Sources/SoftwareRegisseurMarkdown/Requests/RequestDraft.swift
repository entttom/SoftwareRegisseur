import Foundation

/// Input for a new request file. The human ID is assigned by the Mac host when the file is written (ADR-0018).
public struct RequestDraft: Sendable, Hashable {
    public var uuid: UUID
    public var type: RequestType
    public var title: String
    public var status: WorkItemStatus
    public var priority: RequestPriority?
    public var labels: [String]
    public var dependsOn: [String]
    public var agentJobIds: [String]
    public var reviewState: String?
    public var createdAt: Date
    public var description: String
    public var problem: String
    public var goal: String
    public var acceptanceCriteria: [String]
    public var technicalNotes: String
    public var testNotes: String
    public var references: [String]

    public init(
        uuid: UUID = UUID(), type: RequestType, title: String, status: WorkItemStatus = .open,
        priority: RequestPriority? = .medium, labels: [String] = [], dependsOn: [String] = [],
        agentJobIds: [String] = [], reviewState: String? = "pending", createdAt: Date,
        description: String = "", problem: String = "", goal: String = "", acceptanceCriteria: [String] = [],
        technicalNotes: String = "", testNotes: String = "", references: [String] = []
    ) {
        self.uuid = uuid
        self.type = type
        self.title = title
        self.status = status
        self.priority = priority
        self.labels = labels
        self.dependsOn = dependsOn
        self.agentJobIds = agentJobIds
        self.reviewState = reviewState
        self.createdAt = createdAt
        self.description = description
        self.problem = problem
        self.goal = goal
        self.acceptanceCriteria = acceptanceCriteria
        self.technicalNotes = technicalNotes
        self.testNotes = testNotes
        self.references = references
    }
}

public enum RequestRenderError: Error, Sendable, Hashable {
    case idPrefixMismatch(id: HumanID, type: RequestType)
    case emptyTitle
}

/// Renders a brand-new request file (spec F3 field order, German body sections).
public enum RequestRenderer {
    public static func render(
        _ draft: RequestDraft, id: HumanID, timeZone: TimeZone, lineEnding: LineEnding = .lf
    ) throws(RequestRenderError) -> String {
        guard id.prefix == draft.type.idPrefix else { throw .idPrefixMismatch(id: id, type: draft.type) }
        let title = draft.title.trimmingWhitespace()
        guard !title.isEmpty, !title.contains(where: \.isNewline) else { throw .emptyTitle }
        let timestamp = RequestTimestamp.format(draft.createdAt, timeZone: timeZone)
        let flow = { (items: [String]) in FrontmatterDocument.renderFlowList(items) }

        var lines = ["---"]
        lines.append("id: \(id)")
        lines.append("uuid: " + YAMLScalarFormatter.doubleQuoted(draft.uuid.uuidString.lowercased()))
        lines.append("type: \(draft.type.rawValue)")
        lines.append("status: \(draft.status.rawValue)")
        lines.append("title: " + YAMLScalarFormatter.doubleQuoted(title))
        lines.append("createdAt: " + YAMLScalarFormatter.doubleQuoted(timestamp))
        lines.append("updatedAt: " + YAMLScalarFormatter.doubleQuoted(timestamp))
        if let priority = draft.priority { lines.append("priority: \(priority.rawValue)") }
        lines.append("labels: " + flow(draft.labels))
        lines.append("dependsOn: " + flow(draft.dependsOn))
        lines.append("agentJobIds: " + flow(draft.agentJobIds))
        if let reviewState = draft.reviewState {
            lines.append("reviewState: " + YAMLScalarFormatter.render(reviewState))
        }
        lines.append("---")
        lines.append("")
        lines.append("# \(id): \(title)")

        let bullets = { (items: [String]) in
            items.map { $0.trimmingWhitespace() }.filter { !$0.isEmpty }.map { "- " + $0 }.joined(separator: "\n")
        }
        let contents: [(RequestSection, String)] = [
            (.description, draft.description),
            (.problem, draft.problem),
            (.goal, draft.goal),
            (.acceptanceCriteria, bullets(draft.acceptanceCriteria)),
            (.technicalNotes, draft.technicalNotes),
            (.testNotes, draft.testNotes),
            (.references, bullets(draft.references)),
        ]
        for (section, content) in contents {
            let normalized = MarkdownSections.normalized(content)
            guard section.isAlwaysRendered || !normalized.isEmpty else { continue }
            lines.append("")
            lines.append("## \(section.rawValue)")
            if !normalized.isEmpty {
                lines.append("")
                lines.append(normalized)
            }
        }
        let text = lines.joined(separator: "\n") + "\n"
        return lineEnding == .lf ? text : text.replacingOccurrences(of: "\n", with: "\r\n")
    }
}

/// Field-level comparison of two versions of one request, used to reconcile external edits (spec E3, A04).
public struct RequestChangeReport: Sendable, Hashable {
    public struct FieldChange: Sendable, Hashable {
        public var key: String
        public var old: FrontmatterValue?
        public var new: FrontmatterValue?
    }

    public enum SectionChangeKind: Sendable, Hashable { case added, removed, modified }

    public struct SectionChange: Sendable, Hashable {
        /// nil = text before the first section (title heading etc.).
        public var title: String?
        public var kind: SectionChangeKind
    }

    public var fieldChanges: [FieldChange]
    public var sectionChanges: [SectionChange]

    public var changedKeys: [String] { fieldChanges.map(\.key) }
    public var statusChange: FieldChange? { fieldChanges.first { $0.key == RequestField.status } }
    public var titleChange: FieldChange? { fieldChanges.first { $0.key == RequestField.title } }
    /// UUID differs: not the same request (spec F3: renames are not new tasks, but a new UUID is).
    public var isDifferentRequest: Bool { fieldChanges.contains { $0.key == RequestField.uuid } }
    public var hasChanges: Bool { !fieldChanges.isEmpty || !sectionChanges.isEmpty }

    /// Compares decoded values (requoting or line-ending changes are not reported) and normalised sections.
    public static func compare(_ old: RequestDocument, _ new: RequestDocument) -> RequestChangeReport {
        var fields: [FieldChange] = []
        var keys = old.frontmatter.keys
        for key in new.frontmatter.keys where !keys.contains(key) { keys.append(key) }
        for key in keys {
            let before = old.frontmatter.values[key]
            let after = new.frontmatter.values[key]
            if before != after { fields.append(FieldChange(key: key, old: before, new: after)) }
        }

        var sectionChanges: [SectionChange] = []
        let oldSections = old.sections
        let newSections = new.sections
        if MarkdownSections.normalized(oldSections.preamble) != MarkdownSections.normalized(newSections.preamble) {
            sectionChanges.append(SectionChange(title: nil, kind: .modified))
        }
        for section in oldSections.sections {
            if let counterpart = newSections.section(titled: section.title) {
                if counterpart.trimmedContent != section.trimmedContent {
                    sectionChanges.append(SectionChange(title: section.title, kind: .modified))
                }
            } else {
                sectionChanges.append(SectionChange(title: section.title, kind: .removed))
            }
        }
        for section in newSections.sections where oldSections.section(titled: section.title) == nil {
            sectionChanges.append(SectionChange(title: section.title, kind: .added))
        }
        return RequestChangeReport(fieldChanges: fields, sectionChanges: sectionChanges)
    }
}
