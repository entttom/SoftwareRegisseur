import Foundation

public enum AgentJobError: Error, Hashable, Sendable {
    case invalidTransition(InvalidStateTransition<AgentJobState>)
    case configurationLocked(state: AgentJobState)
    case providerMismatch(expected: ProviderID, found: ProviderID)
}

/// One agent run for a work item (spec J3, O; ADR-0006, ADR-0007, ADR-0012).
///
/// The configuration snapshot is fixed at creation; requested/resolved model and effort are read from
/// it. Effective values are set only from adapter-confirmed data, otherwise shown as „nicht bestätigt“.
public struct AgentJob: Hashable, Sendable, Codable, Identifiable {
    public static let unconfirmedText = String(localized: "nicht bestätigt", bundle: .module)

    public let jobId: JobID
    /// Idempotent request UUID from the creating device (spec J3).
    public let idempotencyKey: IdempotencyKey
    public let projectId: ProjectID
    public let workItemId: WorkItemID
    public var hostId: HostID?
    public let providerId: ProviderID
    public private(set) var configSnapshot: ConfigurationSnapshot
    public private(set) var effectiveModelId: ModelID?
    public private(set) var effectiveEffort: EffortLevel?
    public private(set) var effectiveConfirmedAt: Date?
    public var schedule: JobSchedule
    public var priority: Priority
    public private(set) var state: AgentJobState
    /// Task status before this job; restored when the job is cancelled (ADR-0012).
    public let workItemStatusBeforeJob: WorkItemStatus
    public var retryCount: Int
    public var sessionId: String?
    public var branch: String?
    public var worktreePath: String?
    public private(set) var startedAt: Date?
    public private(set) var finishedAt: Date?
    public var lastError: String?
    /// Job this one retries (spec K1 „Wiederholung“, M2 Fehlversuche). Absent in older payloads.
    public let retryOfJobId: JobID?
    public private(set) var revision: Int
    public let createdAt: Date
    public private(set) var updatedAt: Date

    public var id: JobID { jobId }

    public init(
        jobId: JobID = JobID(),
        idempotencyKey: IdempotencyKey,
        projectId: ProjectID,
        workItemId: WorkItemID,
        hostId: HostID? = nil,
        configSnapshot: ConfigurationSnapshot,
        schedule: JobSchedule = JobSchedule(kind: .immediate),
        priority: Priority = .medium,
        workItemStatusBeforeJob: WorkItemStatus,
        retryOfJobId: JobID? = nil,
        createdAt: Date
    ) {
        self.jobId = jobId
        self.idempotencyKey = idempotencyKey
        self.projectId = projectId
        self.workItemId = workItemId
        self.hostId = hostId
        self.providerId = configSnapshot.providerId
        self.configSnapshot = configSnapshot
        self.schedule = schedule
        self.priority = priority
        self.state = .requested
        self.workItemStatusBeforeJob = workItemStatusBeforeJob
        self.retryCount = 0
        self.retryOfJobId = retryOfJobId
        self.revision = 1
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    // MARK: Snapshot-derived fields (spec O)

    public var requestedModelId: ModelID? { configSnapshot.requestedModel?.modelID }
    public var requestedEffort: EffortLevel? { configSnapshot.requestedEffort }
    public var resolvedModel: ModelSelection { configSnapshot.resolvedModel }
    /// nil means provider default model.
    public var resolvedModelId: ModelID? { configSnapshot.resolvedModel.modelID }
    public var resolvedEffort: EffortLevel { configSnapshot.resolvedEffort }
    public var capabilityRevision: Int { configSnapshot.capabilityRevision }
    public var agentVersion: String { configSnapshot.agentVersion }
    public var profileSource: ProfileSources { configSnapshot.profileSource }
    /// Planned start instant for `.at`/`.notBefore`/quota retries; nil for immediate or paused.
    public var scheduledAt: Date? { try? schedule.plannedStart() }

    public var isRetry: Bool { retryOfJobId != nil }

    public var effectiveModelDisplayText: String { effectiveModelId?.rawValue ?? Self.unconfirmedText }
    public var effectiveEffortDisplayText: String { effectiveEffort?.germanDisplayName ?? Self.unconfirmedText }

    public var derivedWorkItemStatus: WorkItemStatus {
        WorkItemStatus.derived(from: state, previous: workItemStatusBeforeJob)
    }

    /// `software-regisseur/<task-id>/<job-short-id>` (spec L2). Uses the human ID when assigned.
    public func suggestedBranchName(humanId: HumanID?) -> String {
        let task = humanId?.formatted ?? workItemId.shortString
        return "software-regisseur/\(task)/\(jobId.shortString)"
    }

    // MARK: Mutations

    public mutating func transition(to next: AgentJobState, at date: Date) throws(AgentJobError) {
        do {
            try state.transition(to: next)
        } catch {
            throw .invalidTransition(error)
        }
        if next == .starting, startedAt == nil { startedAt = date }
        if next.isTerminal { finishedAt = date }
        touch(at: date)
    }

    /// Admission check before start (spec J3): revalidates the stored snapshot against the current
    /// capability and moves to `admitted` or `needs_configuration`. The snapshot is left unchanged.
    @discardableResult
    public mutating func admit(against capability: AgentCapability, at date: Date) throws(AgentJobError) -> SnapshotRevalidation {
        let result = ModelEffortResolver.revalidate(configSnapshot, against: capability)
        try transition(to: result.isOK ? .admitted : .needsConfiguration, at: date)
        return result
    }

    /// Explicit user action to apply a new configuration to a job that has not started (spec J2a).
    public mutating func replaceConfiguration(with snapshot: ConfigurationSnapshot, at date: Date) throws(AgentJobError) {
        guard startedAt == nil, AgentJobState.configurationReplaceable.contains(state) else {
            throw .configurationLocked(state: state)
        }
        guard snapshot.providerId == providerId else {
            throw .providerMismatch(expected: providerId, found: snapshot.providerId)
        }
        configSnapshot = snapshot
        effectiveModelId = nil
        effectiveEffort = nil
        effectiveConfirmedAt = nil
        touch(at: date)
    }

    /// Records model/effort the adapter verifiably reported for the running session (spec J2a, A41).
    public mutating func recordConfirmedEffectiveConfiguration(model: ModelID?, effort: EffortLevel?, at date: Date) {
        if let model { effectiveModelId = model }
        if let effort { effectiveEffort = effort }
        effectiveConfirmedAt = date
        touch(at: date)
    }

    public mutating func touch(at date: Date) {
        revision += 1
        updatedAt = date
    }
}
