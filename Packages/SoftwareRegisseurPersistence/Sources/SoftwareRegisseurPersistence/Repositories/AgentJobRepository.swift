import Foundation
import GRDB
import SoftwareRegisseurDomain

public enum JobCreationResult: Hashable, Sendable {
    case created(AgentJob, WorkItem)
    /// A job with the same idempotency key already existed; nothing was written (A15).
    case existing(AgentJob)

    public var job: AgentJob {
        switch self {
        case let .created(job, _), let .existing(job): job
        }
    }

    public var wasCreated: Bool {
        if case .created = self { return true }
        return false
    }
}

/// Result of a job change that was written atomically with the derived work item status and the
/// history event (ADR-0012).
public struct JobChange: Hashable, Sendable {
    public let job: AgentJob
    public let workItem: WorkItem
    public let event: TaskEvent?
}

public protocol AgentJobRepository: Sendable {
    /// Idempotent creation: a second call with the same idempotency key returns the existing job.
    /// A different key for a work item that already has an active job fails with `activeJobExists`.
    func create(_ job: AgentJob, actor: EventActor, at date: Date) async throws -> JobCreationResult
    func fetch(_ id: JobID) async throws -> AgentJob?
    func fetch(idempotencyKey: IdempotencyKey) async throws -> AgentJob?
    func jobs(forWorkItem id: WorkItemID) async throws -> [AgentJob]
    /// Jobs that retry `id` (spec K1, M2).
    func retries(of id: JobID) async throws -> [AgentJob]
    func activeJob(forWorkItem id: WorkItemID) async throws -> AgentJob?
    /// Queue order: earliest `scheduledAt` (immediate first), then priority, then creation.
    func jobs(inStates states: Set<AgentJobState>, hostId: HostID?, limit: Int?) async throws -> [AgentJob]
    /// Jobs in `states` whose planned start is not in the future.
    func dueJobs(at date: Date, states: Set<AgentJobState>) async throws -> [AgentJob]
    /// Validated state transition plus derived work item status and event, in one transaction.
    func transition(_ id: JobID, to state: AgentJobState, actor: EventActor, at date: Date) async throws -> JobChange
    /// General optimistic update (session ID, branch, confirmed configuration, admission, …). A state
    /// change made by `mutate` is handled exactly like `transition`.
    func update(
        _ id: JobID, expectedRevision: Int, actor: EventActor, at date: Date,
        _ mutate: @Sendable (inout AgentJob) throws -> Void
    ) async throws -> JobChange
}

public struct GRDBAgentJobRepository: AgentJobRepository {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func create(_ job: AgentJob, actor: EventActor, at date: Date = .now) async throws -> JobCreationResult {
        do {
            return try await database.write { db in try Self.create(db, job, actor: actor, at: date) }
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
            // Another process inserted the same key between our check and insert.
            if let existing = try await fetch(idempotencyKey: job.idempotencyKey) { return .existing(existing) }
            throw error
        }
    }

    public func fetch(_ id: JobID) async throws -> AgentJob? {
        try await database.read { db in try AgentJobStorage.fetch(db, syncID: id.rawValue) }
    }

    public func fetch(idempotencyKey: IdempotencyKey) async throws -> AgentJob? {
        try await database.read { db in try Self.fetch(db, idempotencyKey: idempotencyKey) }
    }

    public func jobs(forWorkItem id: WorkItemID) async throws -> [AgentJob] {
        try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM agent_jobs WHERE work_item_id = ? ORDER BY created_at, rowid",
                             arguments: [id.databaseText]).map(AgentJobStorage.decode)
        }
    }

    public func retries(of id: JobID) async throws -> [AgentJob] {
        try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM agent_jobs WHERE retry_of_job_id = ? ORDER BY created_at, rowid",
                             arguments: [id.databaseText]).map(AgentJobStorage.decode)
        }
    }

    public func activeJob(forWorkItem id: WorkItemID) async throws -> AgentJob? {
        try await database.read { db in try Self.activeJob(db, workItemId: id) }
    }

    public func jobs(inStates states: Set<AgentJobState>, hostId: HostID? = nil, limit: Int? = nil) async throws -> [AgentJob] {
        try await database.read { db in
            var sql = "SELECT * FROM agent_jobs WHERE state IN (\(Self.placeholders(states.count)))"
            var arguments: [any DatabaseValueConvertible] = states.map(\.rawValue).sorted()
            if let hostId {
                sql += " AND host_id = ?"
                arguments.append(hostId.databaseText)
            }
            sql += " ORDER BY scheduled_at IS NOT NULL, scheduled_at, priority_rank DESC, created_at, rowid"
            if let limit {
                sql += " LIMIT ?"
                arguments.append(limit)
            }
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).map(AgentJobStorage.decode)
        }
    }

    public func dueJobs(at date: Date, states: Set<AgentJobState> = [.requested, .pendingMac, .scheduled, .waitingQuota]) async throws -> [AgentJob] {
        try await database.read { db in
            var arguments: [any DatabaseValueConvertible] = states.map(\.rawValue).sorted()
            arguments.append(StoredDate.value(date))
            return try Row.fetchAll(db, sql: """
                SELECT * FROM agent_jobs
                WHERE state IN (\(Self.placeholders(states.count))) AND (scheduled_at IS NULL OR scheduled_at <= ?)
                ORDER BY scheduled_at IS NOT NULL, scheduled_at, priority_rank DESC, created_at, rowid
                """, arguments: StatementArguments(arguments)).map(AgentJobStorage.decode)
        }
    }

    public func transition(_ id: JobID, to state: AgentJobState, actor: EventActor, at date: Date = .now) async throws -> JobChange {
        try await database.write { db in
            let stored = try Self.fetchExisting(db, id)
            var updated = stored
            do throws(AgentJobError) {
                try updated.transition(to: state, at: date)
            } catch {
                throw StoreError.jobError(error)
            }
            return try Self.store(db, stored: stored, updated: updated, actor: actor, at: date)
        }
    }

    public func update(
        _ id: JobID, expectedRevision: Int, actor: EventActor, at date: Date = .now,
        _ mutate: @Sendable (inout AgentJob) throws -> Void
    ) async throws -> JobChange {
        try await database.write { db in
            let stored = try Self.fetchExisting(db, id)
            guard stored.revision == expectedRevision else {
                throw StoreError.revisionConflict(entity: .agentJob, id: id.uuidString, expected: expectedRevision, actual: stored.revision)
            }
            var updated = stored
            try mutate(&updated)
            if updated.revision == stored.revision { updated.touch(at: date) }
            return try Self.store(db, stored: stored, updated: updated, actor: actor, at: date)
        }
    }

    // MARK: Transaction bodies

    static func create(_ db: Database, _ job: AgentJob, actor: EventActor, at date: Date) throws -> JobCreationResult {
        if let existing = try fetch(db, idempotencyKey: job.idempotencyKey) {
            guard existing.workItemId == job.workItemId else { throw StoreError.jobWorkItemMismatch(jobId: existing.jobId) }
            return .existing(existing)
        }
        if try AgentJobStorage.fetch(db, syncID: job.jobId.rawValue) != nil {
            throw StoreError.alreadyExists(entity: .agentJob, id: job.jobId.uuidString)
        }
        guard var item = try WorkItemStorage.fetch(db, syncID: job.workItemId.rawValue) else {
            throw StoreError.notFound(entity: .workItem, id: job.workItemId.uuidString)
        }
        guard item.projectId == job.projectId else { throw StoreError.jobWorkItemMismatch(jobId: job.jobId) }
        if let active = try activeJob(db, workItemId: job.workItemId) {
            throw StoreError.activeJobExists(workItemId: job.workItemId, jobId: active.jobId)
        }
        guard job.workItemStatusBeforeJob == item.status else {
            // `cancelled` restores this status (ADR-0012), so it must be the real current one.
            throw StoreError.identityFieldChanged(entity: .agentJob, field: "workItemStatusBeforeJob")
        }
        let previousStatus = item.status
        do throws(InvalidStateTransition<WorkItemStatus>) {
            try item.applyDerivedStatus(from: job, at: date)
        } catch {
            throw StoreError.invalidWorkItemTransition(error)
        }
        item.agentJobIds.append(job.jobId)
        if item.status == previousStatus { item.touch(at: date) }

        try SyncBookkeeping.save(db, AgentJobStorage.self, job, isNew: true, at: date)
        try SyncBookkeeping.save(db, WorkItemStorage.self, item, isNew: false, at: date)
        try EventLogWriter.append(db, workItem: item, kind: .jobRequested, actor: actor, payload: [
            "jobId": job.jobId.uuidString,
            "providerId": job.providerId.rawValue,
            "resolvedModel": job.resolvedModel.modelID?.rawValue ?? "providerDefault",
            "resolvedEffort": job.resolvedEffort.rawValue,
            "workItemStatus": item.status.rawValue,
        ], at: date)
        return .created(job, item)
    }

    static func store(_ db: Database, stored: AgentJob, updated: AgentJob, actor: EventActor, at date: Date) throws -> JobChange {
        guard updated.jobId == stored.jobId, updated.idempotencyKey == stored.idempotencyKey,
              updated.workItemId == stored.workItemId, updated.projectId == stored.projectId,
              updated.providerId == stored.providerId, updated.createdAt == stored.createdAt,
              updated.workItemStatusBeforeJob == stored.workItemStatusBeforeJob
        else {
            throw StoreError.identityFieldChanged(entity: .agentJob, field: "identity")
        }
        if updated.state != stored.state, !stored.state.canTransition(to: updated.state) {
            throw StoreError.jobError(.invalidTransition(InvalidStateTransition(from: stored.state, to: updated.state)))
        }
        guard var item = try WorkItemStorage.fetch(db, syncID: stored.workItemId.rawValue) else {
            throw StoreError.notFound(entity: .workItem, id: stored.workItemId.uuidString)
        }
        let previousItem = item
        if updated.state != stored.state {
            do throws(InvalidStateTransition<WorkItemStatus>) {
                try item.applyDerivedStatus(from: updated, at: date)
            } catch {
                throw StoreError.invalidWorkItemTransition(error)
            }
        }

        try SyncBookkeeping.save(db, AgentJobStorage.self, updated, isNew: false, at: date)
        if item != previousItem {
            try SyncBookkeeping.save(db, WorkItemStorage.self, item, isNew: false, at: date)
        }

        var event: TaskEvent?
        if updated.state != stored.state {
            event = TaskEvent(workItemId: item.uuid, kind: .jobStateChanged, actor: actor, timestamp: date, payload: [
                "jobId": updated.jobId.uuidString,
                "from": stored.state.rawValue,
                "to": updated.state.rawValue,
                "workItemStatus": item.status.rawValue,
            ], sourceRevision: item.revision)
        } else if updated.configSnapshot != stored.configSnapshot {
            event = TaskEvent(workItemId: item.uuid, kind: .configurationReplaced, actor: actor, timestamp: date, payload: [
                "jobId": updated.jobId.uuidString,
                "previousModel": stored.resolvedModel.modelID?.rawValue ?? "providerDefault",
                "previousEffort": stored.resolvedEffort.rawValue,
                "model": updated.resolvedModel.modelID?.rawValue ?? "providerDefault",
                "effort": updated.resolvedEffort.rawValue,
            ], sourceRevision: item.revision)
        }
        if let event { try EventLogWriter.append(db, event, at: date) }
        return JobChange(job: updated, workItem: item, event: event)
    }

    static func fetchExisting(_ db: Database, _ id: JobID) throws -> AgentJob {
        guard let job = try AgentJobStorage.fetch(db, syncID: id.rawValue) else {
            throw StoreError.notFound(entity: .agentJob, id: id.uuidString)
        }
        return job
    }

    static func fetch(_ db: Database, idempotencyKey: IdempotencyKey) throws -> AgentJob? {
        try Row.fetchOne(db, sql: "SELECT * FROM agent_jobs WHERE idempotency_key = ?", arguments: [idempotencyKey.databaseText])
            .map(AgentJobStorage.decode)
    }

    static func activeJob(_ db: Database, workItemId: WorkItemID) throws -> AgentJob? {
        try Row.fetchOne(db, sql: """
            SELECT * FROM agent_jobs WHERE work_item_id = ? AND state NOT IN \(AgentJobStorage.terminalStatesSQL)
            """, arguments: [workItemId.databaseText]).map(AgentJobStorage.decode)
    }

    static func placeholders(_ count: Int) -> String {
        count == 0 ? "NULL" : Array(repeating: "?", count: count).joined(separator: ", ")
    }
}
