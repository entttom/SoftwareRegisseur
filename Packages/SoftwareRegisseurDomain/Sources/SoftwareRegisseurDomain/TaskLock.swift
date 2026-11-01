import Foundation

public enum LockScope: String, Hashable, Sendable, Codable, CaseIterable {
    /// Exclusive per task (default, spec L1).
    case task
    /// Optional per-project lock: one agent per repository.
    case project
}

public enum LockRecoveryState: String, Hashable, Sendable, Codable, CaseIterable {
    case active
    /// Lease expired or host restarted; waiting for process/worktree reconciliation.
    case awaitingReconciliation
    case released
}

public enum TaskLockError: Error, Hashable, Sendable {
    case alreadyReleased
    case releaseNotPermitted(LockReleaseDecision)
    case invalidLeaseDuration(TimeInterval)
}

/// Exclusive lease-based lock inside Software Regisseur (spec L1, ADR-0007). It prevents double starts
/// within the app; it does not claim to block external editors or terminals.
public struct TaskLock: Hashable, Sendable, Codable, Identifiable {
    public let lockId: LockID
    public let taskId: WorkItemID
    public let projectId: ProjectID
    public let jobId: JobID
    public let hostId: HostID
    /// Human-readable owner, e.g. service name on the host.
    public let owner: String
    public let scope: LockScope
    public let acquiredAt: Date
    public private(set) var lastHeartbeat: Date
    public private(set) var leaseUntil: Date
    public private(set) var recoveryState: LockRecoveryState
    public private(set) var releasedAt: Date?
    public private(set) var releaseReason: LockReleaseDecision.ReleaseReason?

    public var id: LockID { lockId }

    public init(
        lockId: LockID = LockID(),
        taskId: WorkItemID,
        projectId: ProjectID,
        jobId: JobID,
        hostId: HostID,
        owner: String,
        scope: LockScope = .task,
        acquiredAt: Date,
        leaseDuration: TimeInterval
    ) throws(TaskLockError) {
        guard leaseDuration > 0 else { throw .invalidLeaseDuration(leaseDuration) }
        self.lockId = lockId
        self.taskId = taskId
        self.projectId = projectId
        self.jobId = jobId
        self.hostId = hostId
        self.owner = owner
        self.scope = scope
        self.acquiredAt = acquiredAt
        self.lastHeartbeat = acquiredAt
        self.leaseUntil = acquiredAt.addingTimeInterval(leaseDuration)
        self.recoveryState = .active
    }

    public var lease: DateInterval { DateInterval(start: lastHeartbeat, end: max(lastHeartbeat, leaseUntil)) }
    public var isReleased: Bool { recoveryState == .released }

    /// Lease time elapsed. This alone never makes the lock releasable (spec L1).
    public func isExpired(at now: Date) -> Bool { now >= leaseUntil }

    public mutating func heartbeat(at now: Date, leaseDuration: TimeInterval) throws(TaskLockError) {
        guard !isReleased else { throw .alreadyReleased }
        guard leaseDuration > 0 else { throw .invalidLeaseDuration(leaseDuration) }
        lastHeartbeat = now
        leaseUntil = now.addingTimeInterval(leaseDuration)
        recoveryState = .active
    }

    /// Marks an expired lease as awaiting reconciliation (e.g. after host restart).
    public mutating func markAwaitingReconciliation() {
        guard !isReleased else { return }
        recoveryState = .awaitingReconciliation
    }

    /// Decides whether the lock may be released. Requires a fresh reconciliation by the owning host
    /// unless the lease is still valid (spec L1: never release only because the lease expired).
    public func releaseDecision(at now: Date, reconciliation: LockReconciliation?) -> LockReleaseDecision {
        if isReleased { return .alreadyReleased }
        guard let reconciliation else {
            return isExpired(at: now) ? .reconciliationRequired(.missing) : .keep(.leaseActive)
        }
        guard reconciliation.hostId == hostId else { return .reconciliationRequired(.foreignHost) }
        guard reconciliation.observedAt >= lastHeartbeat else { return .reconciliationRequired(.staleObservation) }

        switch reconciliation.process {
        case .running: return .keep(.processStillRunning)
        case .unknown: return .reconciliationRequired(.processStateUnknown)
        case .notRunning: break
        }

        let jobTerminal = reconciliation.jobState?.isTerminal ?? false
        // Before the process exists (admitted/starting) a missing process is normal while the lease holds.
        if !jobTerminal, !isExpired(at: now) { return .keep(.leaseActive) }

        let preserveWorktree: Bool
        switch reconciliation.worktree {
        case .unknown: return .requiresUserDecision(.worktreeStateUnknown)
        case .clean, .missing: preserveWorktree = false
        case .hasChanges: preserveWorktree = true
        }

        let reason: LockReleaseDecision.ReleaseReason =
            switch reconciliation.jobState {
            case .finished: .jobFinished
            case .cancelled: .jobCancelled
            case .failed: .jobFailed
            default: .processEndedAfterLeaseExpiry
            }
        return .release(reason, preserveWorktree: preserveWorktree)
    }

    public mutating func release(at now: Date, decision: LockReleaseDecision) throws(TaskLockError) {
        guard !isReleased else { throw .alreadyReleased }
        guard case let .release(reason, _) = decision else { throw .releaseNotPermitted(decision) }
        recoveryState = .released
        releasedAt = now
        releaseReason = reason
    }
}

public enum ProcessObservation: String, Hashable, Sendable, Codable, CaseIterable {
    case running
    case notRunning
    case unknown
}

public enum WorktreeObservation: String, Hashable, Sendable, Codable, CaseIterable {
    case clean
    /// Uncommitted or unintegrated agent changes; must be preserved.
    case hasChanges
    case missing
    case unknown
}

/// Facts gathered by the owning host about the agent process and worktree.
public struct LockReconciliation: Hashable, Sendable, Codable {
    public let hostId: HostID
    public let observedAt: Date
    public let process: ProcessObservation
    public let worktree: WorktreeObservation
    public let jobState: AgentJobState?

    public init(hostId: HostID, observedAt: Date, process: ProcessObservation, worktree: WorktreeObservation, jobState: AgentJobState?) {
        self.hostId = hostId
        self.observedAt = observedAt
        self.process = process
        self.worktree = worktree
        self.jobState = jobState
    }
}

public enum LockReleaseDecision: Hashable, Sendable, Codable {
    public enum KeepReason: String, Hashable, Sendable, Codable {
        case leaseActive
        case processStillRunning
    }

    public enum ReconciliationRequirement: String, Hashable, Sendable, Codable {
        case missing
        case staleObservation
        case foreignHost
        case processStateUnknown
    }

    public enum ReleaseReason: String, Hashable, Sendable, Codable {
        case jobFinished
        case jobCancelled
        case jobFailed
        case processEndedAfterLeaseExpiry
    }

    public enum UserDecisionReason: String, Hashable, Sendable, Codable {
        case worktreeStateUnknown
    }

    case keep(KeepReason)
    case reconciliationRequired(ReconciliationRequirement)
    case release(ReleaseReason, preserveWorktree: Bool)
    case requiresUserDecision(UserDecisionReason)
    case alreadyReleased

    public var permitsRelease: Bool {
        if case .release = self { return true }
        return false
    }
}
