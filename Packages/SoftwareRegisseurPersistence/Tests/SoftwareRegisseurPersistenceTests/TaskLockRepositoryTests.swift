import Foundation
import GRDB
import SoftwareRegisseurDomain
import Testing
@testable import SoftwareRegisseurPersistence

@Suite("TaskLockRepository")
struct TaskLockRepositoryTests {
    func request(_ item: WorkItem, scope: LockScope = .task, host: HostID = Fixture.host) -> LockRequest {
        LockRequest(taskId: item.uuid, projectId: item.projectId!, jobId: JobID(), hostId: host,
                    owner: "AgentService", scope: scope, leaseDuration: 60)
    }

    func secondItem(in database: AppDatabase, project: Project) async throws -> WorkItem {
        let item = Fixture.workItem(projectId: project.id, title: "Zweite Aufgabe")
        try await database.workItems.insert(item, actor: deviceActor, at: t0)
        return item
    }

    @Test func taskLockIsExclusivePerTask() async throws {
        let database = try AppDatabase.inMemory()
        let (project, item) = try await database.seedItem()
        let lock = try await database.locks.acquire(request(item), at: t0)
        await #expect(throws: StoreError.lockHeld(existing: lock.lockId, scope: .task)) {
            _ = try await database.locks.acquire(request(item), at: at(1))
        }
        // A different task in the same project may run in parallel (task scope).
        let other = try await secondItem(in: database, project: project)
        _ = try await database.locks.acquire(request(other), at: at(1))
        #expect(try await database.locks.activeLocks(projectId: project.id).count == 2)
    }

    @Test func projectScopeLockExcludesWholeProject() async throws {
        let database = try AppDatabase.inMemory()
        let (project, item) = try await database.seedItem()
        let other = try await secondItem(in: database, project: project)

        let projectLock = try await database.locks.acquire(request(item, scope: .project), at: t0)
        await #expect(throws: StoreError.lockHeld(existing: projectLock.lockId, scope: .project)) {
            _ = try await database.locks.acquire(request(other), at: at(1))
        }

        // And a project lock cannot be taken while any task lock exists.
        let (projectB, itemB) = try await database.seedItem()
        let otherB = try await secondItem(in: database, project: projectB)
        let taskLock = try await database.locks.acquire(request(itemB), at: t0)
        await #expect(throws: StoreError.lockHeld(existing: taskLock.lockId, scope: .task)) {
            _ = try await database.locks.acquire(request(otherB, scope: .project), at: at(1))
        }
    }

    @Test func projectWideLockSettingMakesTaskLocksProjectExclusive() async throws {
        let database = try AppDatabase.inMemory()
        let (project, item) = try await database.seedItem(projectWideLock: true)
        let other = try await secondItem(in: database, project: project)
        let lock = try await database.locks.acquire(request(item), at: t0)
        await #expect(throws: StoreError.lockHeld(existing: lock.lockId, scope: .task)) {
            _ = try await database.locks.acquire(request(other), at: at(1))
        }
    }

    @Test func concurrentAcquisitionHasExactlyOneWinner() async throws {
        let directory = try TemporaryDirectory()
        let database = try AppDatabase.openWriter(at: directory.databaseURL)
        let (project, item) = try await database.seedItem()
        let other = try await secondItem(in: database, project: project)

        let outcomes = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<10 {
                // Half race for the same task, half for a project-wide lock on the same project.
                let req = index.isMultiple(of: 2) ? request(item) : request(other, scope: .project)
                group.addTask { (try? await database.locks.acquire(req, at: at(Double(index)))) != nil }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        let winners = outcomes.filter { $0 }.count
        let active = try await database.locks.activeLocks(projectId: project.id)
        // Either one project lock, or the task lock (which blocks every project lock).
        #expect(winners == 1)
        #expect(active.count == 1)
    }

    @Test func releaseRequiresDomainDecision() async throws {
        let database = try AppDatabase.inMemory()
        let (_, item) = try await database.seedItem()
        let lock = try await database.locks.acquire(request(item), at: t0)

        // Lease still valid, no reconciliation: keep.
        await #expect(throws: StoreError.lockReleaseRefused(.keep(.leaseActive))) {
            _ = try await database.locks.release(lock.lockId, reconciliation: nil, at: at(10))
        }
        // Lease expired alone never frees the lock (spec L1).
        await #expect(throws: StoreError.lockReleaseRefused(.reconciliationRequired(.missing))) {
            _ = try await database.locks.release(lock.lockId, reconciliation: nil, at: at(120))
        }
        #expect(try await database.locks.expiredLocks(at: at(120)).map(\.lockId) == [lock.lockId])
        // Foreign host observation is not accepted.
        let foreign = LockReconciliation(hostId: HostID(), observedAt: at(120), process: .notRunning, worktree: .clean, jobState: .failed)
        await #expect(throws: StoreError.lockReleaseRefused(.reconciliationRequired(.foreignHost))) {
            _ = try await database.locks.release(lock.lockId, reconciliation: foreign, at: at(120))
        }
        // Process still running.
        let running = LockReconciliation(hostId: Fixture.host, observedAt: at(120), process: .running, worktree: .hasChanges, jobState: .running)
        await #expect(throws: StoreError.lockReleaseRefused(.keep(.processStillRunning))) {
            _ = try await database.locks.release(lock.lockId, reconciliation: running, at: at(120))
        }
        #expect(try await database.locks.activeLock(forTask: item.uuid)?.lockId == lock.lockId)

        // Proper reconciliation releases and preserves a dirty worktree.
        let finished = LockReconciliation(hostId: Fixture.host, observedAt: at(120), process: .notRunning, worktree: .hasChanges, jobState: .finished)
        let result = try await database.locks.release(lock.lockId, reconciliation: finished, at: at(121))
        guard case let .released(released, preserveWorktree) = result else { Issue.record("not released"); return }
        #expect(preserveWorktree)
        #expect(released.releaseReason == .jobFinished)
        #expect(released.isReleased)
        #expect(try await database.locks.activeLock(forTask: item.uuid) == nil)
        #expect(try await database.events.events(forWorkItem: item.uuid).last?.kind == .lockReleased)

        // Released lock: a second release is refused, and the task can be locked again.
        await #expect(throws: StoreError.lockReleaseRefused(.alreadyReleased)) {
            _ = try await database.locks.release(lock.lockId, reconciliation: finished, at: at(122))
        }
        _ = try await database.locks.acquire(request(item), at: at(123))
    }

    @Test func heartbeatExtendsLeaseAndFailsAfterRelease() async throws {
        let database = try AppDatabase.inMemory()
        let (_, item) = try await database.seedItem()
        let lock = try await database.locks.acquire(request(item), at: t0)
        let beaten = try await database.locks.heartbeat(lock.lockId, leaseDuration: 300, at: at(50))
        #expect(beaten.lastHeartbeat == at(50))
        #expect(beaten.leaseUntil == at(350))
        #expect(try await database.locks.expiredLocks(at: at(200)).isEmpty)

        let reconciliation = LockReconciliation(hostId: Fixture.host, observedAt: at(60), process: .notRunning, worktree: .clean, jobState: .cancelled)
        _ = try await database.locks.release(lock.lockId, reconciliation: reconciliation, at: at(61))
        await #expect(throws: StoreError.lockError(.alreadyReleased)) {
            _ = try await database.locks.heartbeat(lock.lockId, leaseDuration: 300, at: at(62))
        }
    }

    @Test func partialUniqueIndexIsBackstopForUnreleasedLocks() async throws {
        let database = try AppDatabase.inMemory()
        let (_, item) = try await database.seedItem()
        let lock = try await database.locks.acquire(request(item), at: t0)
        let duplicate = try TaskLock(taskId: item.uuid, projectId: item.projectId!, jobId: JobID(), hostId: Fixture.host,
                                     owner: "rogue", acquiredAt: t0, leaseDuration: 60)
        #expect(throws: DatabaseError.self) {
            try database.writer!.write { db in try TaskLockStorage.save(db, duplicate) }
        }
        #expect(try await database.locks.activeLock(forTask: item.uuid)?.lockId == lock.lockId)
    }
}
