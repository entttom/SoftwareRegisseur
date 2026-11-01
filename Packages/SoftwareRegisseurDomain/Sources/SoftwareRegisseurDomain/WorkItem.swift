import Foundation

/// Queue/task priority (spec K1).
public enum Priority: String, Hashable, Sendable, Codable, CaseIterable, Comparable {
    case low
    case medium
    case high
    case urgent

    private var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        case .urgent: 3
        }
    }

    public static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rank < rhs.rank }

    public var germanDisplayName: String {
        switch self {
        case .low: "Niedrig"
        case .medium: "Mittel"
        case .high: "Hoch"
        case .urgent: "Dringend"
        }
    }
}

/// Optional planning metadata; independent of the agent effort level (ADR-0006).
public enum TaskComplexity: String, Hashable, Sendable, Codable, CaseIterable {
    case small
    case medium
    case large
}

/// Frontmatter `reviewState` (spec F3).
public enum ReviewState: String, Hashable, Sendable, Codable, CaseIterable {
    case pending
    case approved
    case changesRequested
    case rejected
}

public enum WorkItemError: Error, Hashable, Sendable {
    case humanIDAlreadyAssigned(HumanID)
    case humanIDTypeMismatch(expected: WorkItemType, found: WorkItemType)
    case statusChange(WorkItemStatusChangeError)
    /// The Mac already assigned a human ID of the old type; renumbering needs the Mac (ADR-0018).
    case typeChangeAfterHumanID(HumanID)
    /// Reclassification while an agent job is active (ADR-0012: the job owns the task state).
    case typeChangeDuringActiveJob
}

/// A request/task (spec F1, F3, O). User-editable text is kept separate from execution metadata.
public struct WorkItem: Hashable, Sendable, Codable, Identifiable {
    public let uuid: WorkItemID
    /// Assigned only by the Mac host when the request file is materialized (ADR-0018).
    public private(set) var humanId: HumanID?
    /// nil for inbox items without project.
    public var projectId: ProjectID?
    /// Changed only through `reclassify(to:hasActiveJob:at:)` (revision bump, `typeChanged` event).
    public private(set) var type: WorkItemType
    public var title: String
    /// Original capture text; never overwritten by AI drafts (spec H3).
    public let originalNote: String
    public var transcript: String?
    /// Markdown body (description, problem, goal, acceptance criteria, ...).
    public var structuredBody: String
    public private(set) var status: WorkItemStatus
    public var priority: Priority
    public var complexity: TaskComplexity?
    public var labels: [String]
    /// Dependencies always reference UUIDs (ADR-0018).
    public var dependencies: [WorkItemID]
    public var agentJobIds: [JobID]
    public var reviewState: ReviewState
    /// Archived items are hidden from default lists (spec H1). Archiving is not a status (ADR-0012):
    /// the status machine is unchanged and unarchiving restores the item as it was.
    public private(set) var archivedAt: Date?
    public private(set) var revision: Int
    public let createdAt: Date
    public private(set) var updatedAt: Date

    public var id: WorkItemID { uuid }
    public var isArchived: Bool { archivedAt != nil }

    public init(
        uuid: WorkItemID = WorkItemID(),
        humanId: HumanID? = nil,
        projectId: ProjectID? = nil,
        type: WorkItemType,
        title: String,
        originalNote: String = "",
        transcript: String? = nil,
        structuredBody: String = "",
        status: WorkItemStatus = .inbox,
        priority: Priority = .medium,
        complexity: TaskComplexity? = nil,
        labels: [String] = [],
        dependencies: [WorkItemID] = [],
        agentJobIds: [JobID] = [],
        reviewState: ReviewState = .pending,
        archivedAt: Date? = nil,
        revision: Int = 1,
        createdAt: Date,
        updatedAt: Date? = nil
    ) {
        self.uuid = uuid
        self.humanId = humanId
        self.projectId = projectId
        self.type = type
        self.title = title
        self.originalNote = originalNote
        self.transcript = transcript
        self.structuredBody = structuredBody
        self.status = status
        self.priority = priority
        self.complexity = complexity
        self.labels = labels
        self.dependencies = dependencies
        self.agentJobIds = agentJobIds
        self.reviewState = reviewState
        self.archivedAt = archivedAt
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    /// Reclassification (spec H3 Typ-Klassifizierung, F1). Allowed until the Mac assigned a human ID of
    /// the old type (ADR-0018: assigned IDs are permanent and carry the type prefix) and never while a
    /// job is active. No-op when the type is unchanged.
    public mutating func reclassify(to newType: WorkItemType, hasActiveJob: Bool, at date: Date) throws(WorkItemError) {
        guard newType != type else { return }
        if let humanId { throw .typeChangeAfterHumanID(humanId) }
        if hasActiveJob { throw .typeChangeDuringActiveJob }
        type = newType
        touch(at: date)
    }

    /// Hides the item from default lists; keeps status, history and jobs (ADR-0012 unchanged).
    public mutating func archive(at date: Date) {
        guard archivedAt == nil else { return }
        archivedAt = date
        touch(at: date)
    }

    public mutating func unarchive(at date: Date) {
        guard archivedAt != nil else { return }
        archivedAt = nil
        touch(at: date)
    }

    /// Mac host only (ADR-0018). An assigned ID is permanent.
    public mutating func assignHumanID(_ id: HumanID, at date: Date) throws(WorkItemError) {
        if let existing = humanId { throw .humanIDAlreadyAssigned(existing) }
        guard id.type == type else { throw .humanIDTypeMismatch(expected: type, found: id.type) }
        humanId = id
        touch(at: date)
    }

    /// User-initiated status change; rejected while a job is active (ADR-0012).
    public mutating func changeStatusManually(to next: WorkItemStatus, hasActiveJob: Bool, at date: Date) throws(WorkItemError) {
        do {
            try status.validateManualChange(to: next, hasActiveJob: hasActiveJob)
        } catch {
            throw .statusChange(error)
        }
        status = next
        touch(at: date)
    }

    /// Host-side status update. Applies the ADR-0012 mapping for the job's state, or explicit host
    /// steps such as `implementation_finished → review` and `review → integrated → done`.
    public mutating func applyHostStatus(_ next: WorkItemStatus, at date: Date) throws(InvalidStateTransition<WorkItemStatus>) {
        guard next != status else { return }
        try status.transition(to: next)
        touch(at: date)
    }

    /// Applies the status derived from `job` (ADR-0012). No-op if unchanged.
    public mutating func applyDerivedStatus(from job: AgentJob, at date: Date) throws(InvalidStateTransition<WorkItemStatus>) {
        try applyHostStatus(job.derivedWorkItemStatus, at: date)
    }

    public mutating func touch(at date: Date) {
        revision += 1
        updatedAt = date
    }
}

/// Architecture Decision Record (spec F4). Number range is separate from human IDs (ADR-0018).
public struct ADR: Hashable, Sendable, Codable, Identifiable {
    public let uuid: ADRID
    public let projectId: ProjectID
    public let decisionNumber: ADRNumber
    public var title: String
    public private(set) var status: ADRStatus
    public var date: Date?
    public var context: String
    public var decision: String
    public var alternatives: String
    public var consequences: String
    public var supersedes: [ADRNumber]
    public var supersededBy: ADRNumber?
    public private(set) var revision: Int
    public let createdAt: Date
    public private(set) var updatedAt: Date

    public var id: ADRID { uuid }

    public init(
        uuid: ADRID = ADRID(),
        projectId: ProjectID,
        decisionNumber: ADRNumber,
        title: String,
        status: ADRStatus = .proposed,
        date: Date? = nil,
        context: String = "",
        decision: String = "",
        alternatives: String = "",
        consequences: String = "",
        supersedes: [ADRNumber] = [],
        supersededBy: ADRNumber? = nil,
        revision: Int = 1,
        createdAt: Date,
        updatedAt: Date? = nil
    ) {
        self.uuid = uuid
        self.projectId = projectId
        self.decisionNumber = decisionNumber
        self.title = title
        self.status = status
        self.date = date
        self.context = context
        self.decision = decision
        self.alternatives = alternatives
        self.consequences = consequences
        self.supersedes = supersedes
        self.supersededBy = supersededBy
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    public mutating func transition(to next: ADRStatus, at date: Date) throws(InvalidStateTransition<ADRStatus>) {
        try status.transition(to: next)
        revision += 1
        updatedAt = date
    }
}
