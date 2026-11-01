import Foundation
import Testing
@testable import SoftwareRegisseurDomain

@Suite("Task lock lease and release decision (spec L1)")
struct TaskLockTests {
    let host = Fixtures.host
    let lease: TimeInterval = 120

    private func makeLock() throws -> TaskLock {
        try TaskLock(
            taskId: WorkItemID(),
            projectId: ProjectID(),
            jobId: JobID(),
            hostId: host,
            owner: "SoftwareRegisseurAgentService",
            acquiredAt: referenceDate,
            leaseDuration: lease
        )
    }

    private func observation(
        at offset: TimeInterval,
        process: ProcessObservation,
        worktree: WorktreeObservation = .clean,
        job: AgentJobState? = .running,
        host: HostID? = nil
    ) -> LockReconciliation {
        LockReconciliation(
            hostId: host ?? self.host,
            observedAt: referenceDate.addingTimeInterval(offset),
            process: process,
            worktree: worktree,
            jobState: job
        )
    }

    private var afterExpiry: Date { referenceDate.addingTimeInterval(lease + 60) }

    @Test func expiry() throws {
        let lock = try makeLock()
        #expect(!lock.isExpired(at: referenceDate.addingTimeInterval(lease - 1)))
        #expect(lock.isExpired(at: referenceDate.addingTimeInterval(lease)))
        #expect(lock.lease.duration == lease)
    }

    @Test func rejectsNonPositiveLease() {
        #expect(throws: TaskLockError.invalidLeaseDuration(0)) {
            try TaskLock(taskId: WorkItemID(), projectId: ProjectID(), jobId: JobID(), hostId: HostID(),
                         owner: "x", acquiredAt: referenceDate, leaseDuration: 0)
        }
    }

    @Test func expiryAloneIsNotReleasable() throws {
        let lock = try makeLock()
        let decision = lock.releaseDecision(at: afterExpiry, reconciliation: nil)
        #expect(decision == .reconciliationRequired(.missing))
        #expect(!decision.permitsRelease)
        var copy = lock
        #expect(throws: TaskLockError.releaseNotPermitted(decision)) { try copy.release(at: afterExpiry, decision: decision) }
    }

    @Test func activeLeaseIsKept() throws {
        let lock = try makeLock()
        #expect(lock.releaseDecision(at: referenceDate.addingTimeInterval(10), reconciliation: nil) == .keep(.leaseActive))
    }

    @Test func expiredButProcessAliveIsKept() throws {
        let lock = try makeLock()
        let decision = lock.releaseDecision(at: afterExpiry, reconciliation: observation(at: lease + 30, process: .running))
        #expect(decision == .keep(.processStillRunning))
        #expect(!decision.permitsRelease)
    }

    @Test func unknownProcessStateRequiresReconciliation() throws {
        let lock = try makeLock()
        #expect(lock.releaseDecision(at: afterExpiry, reconciliation: observation(at: lease + 30, process: .unknown))
            == .reconciliationRequired(.processStateUnknown))
    }

    @Test func staleOrForeignObservationIsRejected() throws {
        var lock = try makeLock()
        try lock.heartbeat(at: referenceDate.addingTimeInterval(60), leaseDuration: lease)
        let late = referenceDate.addingTimeInterval(60 + lease + 10)
        #expect(lock.releaseDecision(at: late, reconciliation: observation(at: 30, process: .notRunning))
            == .reconciliationRequired(.staleObservation))
        #expect(lock.releaseDecision(at: late, reconciliation: observation(at: lease + 70, process: .notRunning, host: HostID()))
            == .reconciliationRequired(.foreignHost))
    }

    @Test func expiredDeadProcessReleasesAfterReconciliation() throws {
        let lock = try makeLock()
        #expect(lock.releaseDecision(at: afterExpiry, reconciliation: observation(at: lease + 30, process: .notRunning, worktree: .clean))
            == .release(.processEndedAfterLeaseExpiry, preserveWorktree: false))
        #expect(lock.releaseDecision(at: afterExpiry, reconciliation: observation(at: lease + 30, process: .notRunning, worktree: .hasChanges))
            == .release(.processEndedAfterLeaseExpiry, preserveWorktree: true))
        #expect(lock.releaseDecision(at: afterExpiry, reconciliation: observation(at: lease + 30, process: .notRunning, worktree: .unknown))
            == .requiresUserDecision(.worktreeStateUnknown))
    }

    @Test func confirmedCompletionReleasesBeforeExpiry() throws {
        let lock = try makeLock()
        let now = referenceDate.addingTimeInterval(30)
        #expect(lock.releaseDecision(at: now, reconciliation: observation(at: 30, process: .notRunning, worktree: .hasChanges, job: .finished))
            == .release(.jobFinished, preserveWorktree: true))
        #expect(lock.releaseDecision(at: now, reconciliation: observation(at: 30, process: .notRunning, job: .cancelled))
            == .release(.jobCancelled, preserveWorktree: false))
        #expect(lock.releaseDecision(at: now, reconciliation: observation(at: 30, process: .notRunning, job: .failed))
            == .release(.jobFailed, preserveWorktree: false))
    }

    @Test func noProcessYetDuringStartupKeepsLock() throws {
        let lock = try makeLock()
        #expect(lock.releaseDecision(at: referenceDate.addingTimeInterval(5), reconciliation: observation(at: 5, process: .notRunning, job: .admitted))
            == .keep(.leaseActive))
    }

    @Test func heartbeatExtendsLease() throws {
        var lock = try makeLock()
        lock.markAwaitingReconciliation()
        #expect(lock.recoveryState == .awaitingReconciliation)
        try lock.heartbeat(at: referenceDate.addingTimeInterval(100), leaseDuration: lease)
        #expect(lock.recoveryState == .active)
        #expect(lock.leaseUntil == referenceDate.addingTimeInterval(220))
        #expect(!lock.isExpired(at: referenceDate.addingTimeInterval(200)))
    }

    @Test func releaseIsFinal() throws {
        var lock = try makeLock()
        let decision = lock.releaseDecision(at: afterExpiry, reconciliation: observation(at: lease + 30, process: .notRunning))
        try lock.release(at: afterExpiry, decision: decision)
        #expect(lock.isReleased)
        #expect(lock.releaseReason == .processEndedAfterLeaseExpiry)
        #expect(lock.releaseDecision(at: afterExpiry, reconciliation: nil) == .alreadyReleased)
        #expect(throws: TaskLockError.alreadyReleased) { try lock.release(at: afterExpiry, decision: decision) }
        #expect(throws: TaskLockError.alreadyReleased) { try lock.heartbeat(at: afterExpiry, leaseDuration: lease) }
        #expect(try roundTrip(lock) == lock)
    }
}
