import Foundation
import GRDB
import SoftwareRegisseurDomain

public struct LockRequest: Hashable, Sendable {
    public let taskId: WorkItemID
    public let projectId: ProjectID
    public let jobId: JobID
    public let hostId: HostID
    public let owner: String
    public let scope: LockScope
    public let leaseDuration: TimeInterval

    public init(
        taskId: WorkItemID, projectId: ProjectID, jobId: JobID, hostId: HostID,
        owner: String, scope: LockScope = .task, leaseDuration: TimeInterval
    ) {
        self.taskId = taskId
        self.projectId = projectId
        self.jobId = jobId
        self.hostId = hostId
        self.owner = owner
        self.scope = scope
        self.leaseDuration = leaseDuration
    }
}

public enum LockReleaseResult: Hashable, Sendable {
    case released(TaskLock, preserveWorktree: Bool)
}

/// Lease-based locks (spec L1, ADR-0007). Acquisition fails while any unreleased lock exists for the
/// task, or for the project when either lock is project-scoped or the project setting
/// `projectWideLock` is on. An expired lease never frees a lock by itself: release requires the
/// domain `LockReleaseDecision` computed from a host reconciliation.
public protocol TaskLockRepository: Sendable {
    func acquire(_ request: LockRequest, at date: Date) async throws -> TaskLock
    func heartbeat(_ id: LockID, leaseDuration: TimeInterval, at date: Date) async throws -> TaskLock
    func markAwaitingReconciliation(_ id: LockID, at date: Date) async throws -> TaskLock
    /// Computes `TaskLock.releaseDecision` inside the transaction from the stored lock; releases only
    /// on `.release`, otherwise throws `lockReleaseRefused(decision)` and leaves the lock untouched.
    func release(_ id: LockID, reconciliation: LockReconciliation?, at date: Date) async throws -> LockReleaseResult
    func fetch(_ id: LockID) async throws -> TaskLock?
    func activeLock(forTask id: WorkItemID) async throws -> TaskLock?
    func activeLocks(projectId: ProjectID) async throws -> [TaskLock]
    func activeLocks(hostId: HostID) async throws -> [TaskLock]
    /// Unreleased locks whose lease ended before `date` (candidates for reconciliation).
    func expiredLocks(at date: Date) async throws -> [TaskLock]
}

public struct GRDBTaskLockRepository: TaskLockRepository {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func acquire(_ request: LockRequest, at date: Date = .now) async throws -> TaskLock {
        do {
            return try await database.write { db in try Self.acquire(db, request, at: date) }
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
            // Unique partial indexes are the cross-process backstop.
            let existing = try await activeLock(forTask: request.taskId)
            throw StoreError.lockHeld(existing: existing?.lockId ?? LockID(), scope: existing?.scope ?? .project)
        }
    }

    public func heartbeat(_ id: LockID, leaseDuration: TimeInterval, at date: Date = .now) async throws -> TaskLock {
        try await database.write { db in
            var lock = try Self.fetchExisting(db, id)
            do throws(TaskLockError) {
                try lock.heartbeat(at: date, leaseDuration: leaseDuration)
            } catch {
                throw StoreError.lockError(error)
            }
            try SyncBookkeeping.save(db, TaskLockStorage.self, lock, isNew: false, at: date)
            return lock
        }
    }

    public func markAwaitingReconciliation(_ id: LockID, at date: Date = .now) async throws -> TaskLock {
        try await database.write { db in
            var lock = try Self.fetchExisting(db, id)
            let before = lock
            lock.markAwaitingReconciliation()
            if lock != before { try SyncBookkeeping.save(db, TaskLockStorage.self, lock, isNew: false, at: date) }
            return lock
        }
    }

    public func release(_ id: LockID, reconciliation: LockReconciliation?, at date: Date = .now) async throws -> LockReleaseResult {
        try await database.write { db in
            var lock = try Self.fetchExisting(db, id)
            let decision = lock.releaseDecision(at: date, reconciliation: reconciliation)
            guard case let .release(reason, preserveWorktree) = decision else {
                throw StoreError.lockReleaseRefused(decision)
            }
            do throws(TaskLockError) {
                try lock.release(at: date, decision: decision)
            } catch {
                throw StoreError.lockError(error)
            }
            try SyncBookkeeping.save(db, TaskLockStorage.self, lock, isNew: false, at: date)
            try Self.appendEvent(db, lock, kind: .lockReleased, payload: [
                "lockId": lock.lockId.uuidString,
                "reason": reason.rawValue,
                "preserveWorktree": String(preserveWorktree),
            ], at: date)
            return .released(lock, preserveWorktree: preserveWorktree)
        }
    }

    public func fetch(_ id: LockID) async throws -> TaskLock? {
        try await database.read { db in try TaskLockStorage.fetch(db, syncID: id.rawValue) }
    }

    public func activeLock(forTask id: WorkItemID) async throws -> TaskLock? {
        try await database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM task_locks WHERE task_id = ? AND recovery_state <> 'released'",
                             arguments: [id.databaseText]).map(TaskLockStorage.decode)
        }
    }

    public func activeLocks(projectId: ProjectID) async throws -> [TaskLock] {
        try await database.read { db in try Self.activeLocks(db, projectId: projectId) }
    }

    public func activeLocks(hostId: HostID) async throws -> [TaskLock] {
        try await database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM task_locks WHERE host_id = ? AND recovery_state <> 'released' ORDER BY acquired_at, rowid
                """, arguments: [hostId.databaseText]).map(TaskLockStorage.decode)
        }
    }

    public func expiredLocks(at date: Date) async throws -> [TaskLock] {
        try await database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM task_locks WHERE recovery_state <> 'released' AND lease_until <= ? ORDER BY lease_until, rowid
                """, arguments: [StoredDate.value(date)]).map(TaskLockStorage.decode)
        }
    }

    // MARK: Transaction bodies

    static func acquire(_ db: Database, _ request: LockRequest, at date: Date) throws -> TaskLock {
        if let held = try Row.fetchOne(db, sql: "SELECT * FROM task_locks WHERE task_id = ? AND recovery_state <> 'released'",
                                       arguments: [request.taskId.databaseText]).map(TaskLockStorage.decode) {
            throw StoreError.lockHeld(existing: held.lockId, scope: held.scope)
        }
        let projectWide = try Bool.fetchOne(db, sql: """
            SELECT s.project_wide_lock FROM projects p JOIN project_settings s ON s.id = p.settings_id WHERE p.id = ?
            """, arguments: [request.projectId.databaseText]) ?? false
        for held in try activeLocks(db, projectId: request.projectId)
        where projectWide || request.scope == .project || held.scope == .project {
            throw StoreError.lockHeld(existing: held.lockId, scope: held.scope)
        }
        let lock: TaskLock
        do throws(TaskLockError) {
            lock = try TaskLock(
                taskId: request.taskId, projectId: request.projectId, jobId: request.jobId, hostId: request.hostId,
                owner: request.owner, scope: request.scope, acquiredAt: date, leaseDuration: request.leaseDuration
            )
        } catch {
            throw StoreError.lockError(error)
        }
        try SyncBookkeeping.save(db, TaskLockStorage.self, lock, isNew: true, at: date)
        try appendEvent(db, lock, kind: .lockAcquired, payload: [
            "lockId": lock.lockId.uuidString,
            "jobId": lock.jobId.uuidString,
            "scope": lock.scope.rawValue,
        ], at: date)
        return lock
    }

    static func activeLocks(_ db: Database, projectId: ProjectID) throws -> [TaskLock] {
        try Row.fetchAll(db, sql: """
            SELECT * FROM task_locks WHERE project_id = ? AND recovery_state <> 'released' ORDER BY acquired_at, rowid
            """, arguments: [projectId.databaseText]).map(TaskLockStorage.decode)
    }

    static func fetchExisting(_ db: Database, _ id: LockID) throws -> TaskLock {
        guard let lock = try TaskLockStorage.fetch(db, syncID: id.rawValue) else {
            throw StoreError.notFound(entity: .taskLock, id: id.uuidString)
        }
        return lock
    }

    /// Lock events reference the task; the item's current revision is the source revision.
    static func appendEvent(_ db: Database, _ lock: TaskLock, kind: TaskEventKind, payload: [String: String], at date: Date) throws {
        let revision = try Int.fetchOne(db, sql: "SELECT revision FROM work_items WHERE uuid = ?", arguments: [lock.taskId.databaseText]) ?? 0
        let event = TaskEvent(workItemId: lock.taskId, kind: kind, actor: .host(lock.hostId), timestamp: date,
                              payload: payload, sourceRevision: revision)
        try EventLogWriter.append(db, event, at: date)
    }
}
