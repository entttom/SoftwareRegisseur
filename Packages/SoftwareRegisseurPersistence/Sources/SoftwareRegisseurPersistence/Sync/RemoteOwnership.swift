import Foundation
import GRDB
import SoftwareRegisseurDomain

/// Device ownership of synced data on the execution host (ADR-0026, security audit SR-SEC-01).
///
/// Every device in the iCloud account can write every record of the private zone. The Mac execution
/// host therefore checks *who may change what* before it applies a fetched change, not only when a
/// conflict happens:
///
/// - **Owned by the execution host** (with its `hostId`): repository locations, indexed folders, agent
///   hosts and capabilities, task locks and pending approvals. Another device may not create, change or
///   delete them; only an identical payload (e.g. an echo after a zone reset) passes.
/// - **Agent jobs of this host**: another device may create a plain job *request* (state `requested`,
///   no execution data) and later change only schedule, priority, the configuration of a job that has not
///   started, or cancel it. State after admission, branch, worktree path, session, effective
///   configuration, host and retry data stay with the Mac.
/// - **Reviews of this host's jobs**: another device may only record the review decision
///   (`decision`, `approvedAt`); diff, commits, tests, head commit, notes, conflict and integration data
///   are execution data of the Mac.
/// - **Project setup commands for this host**: created on any device as `pending` without result; the
///   Mac owns state, failure and result path, and the request becomes immutable once handled.
/// - Everything else (work items, drafts, approval decisions, settings, conflict resolutions, …) is user
///   content and follows the normal conflict rules.
///
/// A violating change is never applied. It is kept as a resolved `SyncConflict` (resolution
/// `rejectedOwnership`, resolver `automaticPolicy`) so it stays visible, and the host's own value is
/// queued again so the server copy is corrected.
public struct RemoteOwnershipPolicy: Sendable, Hashable {
    /// `SyncConflict.resolution` of a change rejected by this policy.
    public static let rejectedResolution = "rejectedOwnership"

    public let executionHostId: HostID

    public init(executionHostId: HostID) {
        self.executionHostId = executionHostId
    }

    /// nil when the change may be applied; otherwise a short English reason (stored with the record).
    func violation(of change: RemoteChange, _ db: Database) throws -> String? {
        switch change.entityType {
        case .repositoryLocation: try hostOwned(RepositoryLocationStorage.self, change, db) { $0.hostId }
        case .indexedFolder: try hostOwned(IndexedFolderStorage.self, change, db) { $0.hostId }
        case .agentHost: try hostOwned(AgentHostStorage.self, change, db) { $0.hostId }
        case .agentCapability: try hostOwned(AgentCapabilityStorage.self, change, db) { $0.hostId }
        case .taskLock: try hostOwned(TaskLockStorage.self, change, db) { $0.hostId }
        case .pendingApproval: try hostOwned(PendingApprovalStorage.self, change, db) { $0.hostId }
        case .agentJob: try jobViolation(change, db)
        case .review: try reviewViolation(change, db)
        case .projectSetupCommand: try setupCommandViolation(change, db)
        default: nil
        }
    }

    // MARK: Rules

    private func remoteValue<S: EntityStorage>(_ storage: S.Type, _ change: RemoteChange) throws -> S.Entity? {
        guard change.kind != .delete, let payload = change.payload else { return nil }
        return try S.decodePayload(payload)
    }

    private func hostOwned<S: EntityStorage>(
        _ storage: S.Type, _ change: RemoteChange, _ db: Database, hostId: (S.Entity) -> HostID
    ) throws -> String? {
        let local = try S.fetch(db, syncID: change.entityId)
        let remote = try remoteValue(storage, change)
        guard local.map(hostId) == executionHostId || remote.map(hostId) == executionHostId else { return nil }
        guard let remote else { return "deletion of \(S.entityType.rawValue) owned by this execution host" }
        if let local, try S.payloadData(local) == S.payloadData(remote) { return nil }
        return "\(S.entityType.rawValue) is owned by this execution host"
    }

    private func isThisHost(_ hostId: HostID?, projectId: ProjectID, _ db: Database) throws -> Bool {
        if let hostId { return hostId == executionHostId }
        // A job without host belongs to the project's execution host (takeover, spec N4).
        return try ProjectStorage.fetch(db, syncID: projectId.rawValue)?.hostId == executionHostId
    }

    private func jobViolation(_ change: RemoteChange, _ db: Database) throws -> String? {
        let local = try AgentJobStorage.fetch(db, syncID: change.entityId)
        let remote = try remoteValue(AgentJobStorage.self, change)
        var ours = false
        if let local, try isThisHost(local.hostId, projectId: local.projectId, db) { ours = true }
        if let remote, try isThisHost(remote.hostId, projectId: remote.projectId, db) { ours = true }
        guard ours else { return nil }
        guard let remote else { return "deletion of a job of this execution host" }
        guard let local else {
            // A new job from another device is a request only (spec J3): no execution data.
            let isPlainRequest = remote.state == .requested && remote.startedAt == nil && remote.finishedAt == nil
                && remote.sessionId == nil && remote.branch == nil && remote.worktreePath == nil
                && remote.effectiveModelId == nil && remote.effectiveEffort == nil && remote.effectiveConfirmedAt == nil
                && remote.retryCount == 0 && (remote.hostId == nil || remote.hostId == executionHostId)
            return isPlainRequest ? nil : "new job from another device is not a plain request"
        }
        if local == remote { return nil }
        var changed: [String] = []
        func check<V: Equatable>(_ name: String, _ path: KeyPath<AgentJob, V>) {
            if local[keyPath: path] != remote[keyPath: path] { changed.append(name) }
        }
        check("jobId", \.jobId)
        check("idempotencyKey", \.idempotencyKey)
        check("projectId", \.projectId)
        check("workItemId", \.workItemId)
        check("hostId", \.hostId)
        check("providerId", \.providerId)
        check("effectiveModelId", \.effectiveModelId)
        check("effectiveEffort", \.effectiveEffort)
        check("effectiveConfirmedAt", \.effectiveConfirmedAt)
        check("workItemStatusBeforeJob", \.workItemStatusBeforeJob)
        check("retryCount", \.retryCount)
        check("sessionId", \.sessionId)
        check("branch", \.branch)
        check("worktreePath", \.worktreePath)
        check("startedAt", \.startedAt)
        check("retryOfJobId", \.retryOfJobId)
        check("createdAt", \.createdAt)
        // State: unchanged, or an explicit cancellation (spec K1) that the state machine allows.
        let cancels = remote.state == .cancelled && local.state != .cancelled && local.state.canTransition(to: .cancelled)
        if local.state != remote.state, !cancels { changed.append("state") }
        if !cancels { check("finishedAt", \.finishedAt) }
        // Configuration: only for a job that has not started (spec J2a).
        if local.configSnapshot != remote.configSnapshot,
           !(local.startedAt == nil && AgentJobState.configurationReplaceable.contains(local.state)) {
            changed.append("configSnapshot")
        }
        return changed.isEmpty ? nil : "host-owned job fields changed: \(changed.joined(separator: ","))"
    }

    private func reviewViolation(_ change: RemoteChange, _ db: Database) throws -> String? {
        let local = try ReviewStorage.fetch(db, syncID: change.entityId)
        let remote = try remoteValue(ReviewStorage.self, change)
        guard let jobId = (local ?? remote)?.jobId else { return nil }
        guard let job = try AgentJobStorage.fetch(db, syncID: jobId.rawValue),
              try isThisHost(job.hostId, projectId: job.projectId, db)
        else { return nil }
        guard let remote else { return "deletion of a review of this execution host" }
        guard let local else { return "review of a job of this execution host created by another device" }
        var changed: [String] = []
        func check<V: Equatable>(_ name: String, _ path: KeyPath<Review, V>) {
            if local[keyPath: path] != remote[keyPath: path] { changed.append(name) }
        }
        check("reviewId", \.reviewId)
        check("jobId", \.jobId)
        check("diffSummary", \.diffSummary)
        check("testResults", \.testResults)
        check("integrationCommit", \.integrationCommit)
        check("integrationStrategy", \.integrationStrategy)
        check("summary", \.summary)
        check("commits", \.commits)
        check("fileChanges", \.fileChanges)
        check("conflict", \.conflict)
        check("testSummary", \.testSummary)
        check("headCommit", \.headCommit)
        check("notes", \.notes)
        return changed.isEmpty ? nil : "review execution data changed: \(changed.joined(separator: ","))"
    }

    private func setupCommandViolation(_ change: RemoteChange, _ db: Database) throws -> String? {
        let local = try ProjectSetupCommandStorage.fetch(db, syncID: change.entityId)
        let remote = try remoteValue(ProjectSetupCommandStorage.self, change)
        let hosts = [local?.hostId, remote?.hostId]
        let ours = hosts.contains(executionHostId) || (local != nil && local?.hostId == nil && remote?.hostId == nil)
            || (local == nil && remote != nil && remote?.hostId == nil)
        guard ours else { return nil }
        guard let remote else {
            return local == nil ? nil : "deletion of a setup command of this execution host"
        }
        guard let local else {
            let isRequest = remote.state == .pending && remote.failure == nil && remote.resultPath == nil
            return isRequest ? nil : "new setup command from another device is not pending"
        }
        if local == remote { return nil }
        var changed: [String] = []
        func check<V: Equatable>(_ name: String, _ path: KeyPath<ProjectSetupCommand, V>) {
            if local[keyPath: path] != remote[keyPath: path] { changed.append(name) }
        }
        check("id", \.id)
        check("kind", \.kind)
        check("projectId", \.projectId)
        check("target", \.target)
        check("requestedBy", \.requestedBy)
        check("hostId", \.hostId)
        check("state", \.state)
        check("failure", \.failure)
        check("resultPath", \.resultPath)
        check("createdAt", \.createdAt)
        if local.state != .pending {
            // Handled commands are history.
            check("projectName", \.projectName)
            check("repositoryScope", \.repositoryScope)
            check("initializeGitRepository", \.initializeGitRepository)
            check("gitInitConsent", \.gitInitConsent)
        }
        return changed.isEmpty ? nil : "host-owned setup command fields changed: \(changed.joined(separator: ","))"
    }
}
