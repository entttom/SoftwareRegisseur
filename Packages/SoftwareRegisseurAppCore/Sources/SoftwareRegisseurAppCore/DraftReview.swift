import Foundation
import SoftwareRegisseurAI
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

public enum DraftDecision: String, Hashable, Sendable, Codable {
    case pending
    case accepted
    case rejected
}

/// One AI draft awaiting the user's decision.
public struct DraftCandidate: Hashable, Sendable, Identifiable {
    public let id: UUID
    public var draft: StructuredDraft
    public var decision: DraftDecision

    public init(id: UUID = UUID(), draft: StructuredDraft, decision: DraftDecision = .pending) {
        self.id = id
        self.draft = draft
        self.decision = decision
    }

    /// ADR numbers are allocated by the Mac (ADR-0018); an ADR draft cannot become a work item.
    public var isAdoptable: Bool { DraftMapping.workItemType(draft.type) != nil }
}

/// Per-item confirmation of AI drafts (spec H3: „vor Anlage einzeln bestätigen“). A draft is never
/// adopted without an explicit `accepted` decision and never starts an agent.
public struct DraftReviewSession: Hashable, Sendable {
    public let mode: DraftMode
    public private(set) var candidates: [DraftCandidate]

    public init(mode: DraftMode, drafts: [StructuredDraft]) {
        self.mode = mode
        self.candidates = drafts.map { DraftCandidate(draft: $0) }
    }

    public mutating func decide(_ decision: DraftDecision, for id: DraftCandidate.ID) {
        guard let index = candidates.firstIndex(where: { $0.id == id }) else { return }
        if decision == .accepted, !candidates[index].isAdoptable { return }
        candidates[index].decision = decision
    }

    /// The user may edit a draft before accepting it (spec H3: „korrigieren“).
    public mutating func edit(_ id: DraftCandidate.ID, _ change: (inout StructuredDraft) -> Void) {
        guard let index = candidates.firstIndex(where: { $0.id == id }) else { return }
        change(&candidates[index].draft)
    }

    public var accepted: [DraftCandidate] { candidates.filter { $0.decision == .accepted } }
    public var allDecided: Bool { candidates.allSatisfy { $0.decision != .pending } }
    /// Adoption needs a decision on every item and at least one accepted draft.
    public var canAdopt: Bool { allDecided && !accepted.isEmpty }
    public var openQuestions: [String] { candidates.flatMap(\.draft.openQuestions) }
}

/// Section headings of the Markdown body. Passed in by the app from its String Catalog.
public struct DraftBodyHeadings: Hashable, Sendable {
    public var goal: String
    public var context: String
    public var acceptanceCriteria: String
    public var technicalNotes: String
    public var testCases: String
    public var dependencies: String
    public var openQuestions: String

    public init(goal: String, context: String, acceptanceCriteria: String, technicalNotes: String,
                testCases: String, dependencies: String, openQuestions: String) {
        self.goal = goal
        self.context = context
        self.acceptanceCriteria = acceptanceCriteria
        self.technicalNotes = technicalNotes
        self.testCases = testCases
        self.dependencies = dependencies
        self.openQuestions = openQuestions
    }
}

public enum DraftMapping {
    public static func workItemType(_ type: DraftType) -> WorkItemType? {
        switch type {
        case .todo: .todo
        case .feature: .feature
        case .bug: .bug
        case .improvement: .improvement
        case .note: .note
        case .adr: nil
        }
    }

    /// AI draft → synced Domain draft content (lossless for the fields the Domain keeps).
    public static func content(_ draft: StructuredDraft) -> DraftContent {
        DraftContent(
            classification: classification(draft.type), title: draft.title, goal: draft.goal, context: draft.context,
            acceptanceCriteria: draft.acceptanceCriteria, technicalNotes: draft.technicalNotes, testCases: draft.testCases,
            priority: priority(draft.priority), dependencies: draft.dependencies, openQuestions: draft.openQuestions)
    }

    public static func structuredDraft(_ content: DraftContent) -> StructuredDraft {
        StructuredDraft(
            type: draftType(content.classification), title: content.title, goal: content.goal, context: content.context,
            acceptanceCriteria: content.acceptanceCriteria, technicalNotes: content.technicalNotes, testCases: content.testCases,
            priority: draftPriority(content.priority), dependencies: content.dependencies, openQuestions: content.openQuestions)
    }

    public static func classification(_ type: DraftType) -> DraftClassification {
        switch type {
        case .todo: .todo
        case .feature: .feature
        case .bug: .bug
        case .improvement: .improvement
        case .adr: .adr
        case .note: .note
        }
    }

    public static func draftType(_ classification: DraftClassification) -> DraftType {
        switch classification {
        case .todo: .todo
        case .feature: .feature
        case .bug: .bug
        case .improvement: .improvement
        case .adr: .adr
        case .note: .note
        }
    }

    public static func draftPriority(_ priority: Priority?) -> DraftPriority? {
        switch priority {
        case .low: .low
        case .medium: .medium
        case .high: .high
        case .urgent: .critical
        case nil: nil
        }
    }

    public static func priority(_ priority: DraftPriority?) -> Priority? {
        switch priority {
        case .low: .low
        case .medium: .medium
        case .high: .high
        case .critical: .urgent
        case nil: nil
        }
    }

    /// Markdown body of a draft; empty sections are omitted.
    public static func markdownBody(_ draft: StructuredDraft, headings: DraftBodyHeadings) -> String {
        var sections: [String] = []
        func text(_ heading: String, _ value: String) {
            guard !value.isEmpty else { return }
            sections.append("## \(heading)\n\n\(value)")
        }
        func list(_ heading: String, _ values: [String], checkbox: Bool = false) {
            guard !values.isEmpty else { return }
            let prefix = checkbox ? "- [ ] " : "- "
            sections.append("## \(heading)\n\n" + values.map { prefix + $0 }.joined(separator: "\n"))
        }
        text(headings.goal, draft.goal)
        text(headings.context, draft.context)
        list(headings.acceptanceCriteria, draft.acceptanceCriteria, checkbox: true)
        list(headings.technicalNotes, draft.technicalNotes)
        list(headings.testCases, draft.testCases)
        list(headings.dependencies, draft.dependencies)
        list(headings.openQuestions, draft.openQuestions)
        return sections.joined(separator: "\n\n")
    }
}

/// Writes accepted drafts. Original note and transcript stay untouched (spec H3 versioning).
public struct DraftAdopter: Sendable {
    public let workItems: any WorkItemRepository
    public let headings: DraftBodyHeadings

    public init(workItems: any WorkItemRepository, headings: DraftBodyHeadings) {
        self.workItems = workItems
        self.headings = headings
    }

    /// Applies one accepted draft to the existing item (title, body, priority). The type of an existing
    /// item is fixed; a different classification has to be adopted as a new item.
    public func apply(_ draft: StructuredDraft, to item: WorkItem, actor: EventActor, at date: Date) async throws -> WorkItem {
        let body = DraftMapping.markdownBody(draft, headings: headings)
        let priority = DraftMapping.priority(draft.priority)
        return try await workItems.update(item.uuid, expectedRevision: item.revision, actor: actor, at: date) { item in
            item.title = draft.title
            item.structuredBody = body
            if let priority { item.priority = priority }
        }
    }

    /// Creates one new item per accepted candidate. Requires a complete per-item decision.
    public func createItems(
        from session: DraftReviewSession, source: WorkItem, actor: EventActor, at date: Date
    ) async throws -> [WorkItem] {
        guard session.canAdopt else { return [] }
        var created: [WorkItem] = []
        for candidate in session.accepted {
            guard let type = DraftMapping.workItemType(candidate.draft.type) else { continue }
            let item = WorkItem(
                projectId: source.projectId,
                type: type,
                title: candidate.draft.title,
                originalNote: source.originalNote,
                transcript: source.transcript,
                structuredBody: DraftMapping.markdownBody(candidate.draft, headings: headings),
                status: source.projectId == nil ? .inbox : .open,
                priority: DraftMapping.priority(candidate.draft.priority) ?? .medium,
                labels: source.labels,
                createdAt: date
            )
            try await workItems.insert(item, actor: actor, at: date)
            created.append(item)
        }
        return created
    }
}
