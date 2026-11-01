import Foundation
import GRDB
import SoftwareRegisseurDomain
import Testing
@testable import SoftwareRegisseurPersistence

/// ADR-0026 / SR-SEC-01: the execution host rejects remote changes to data it owns, not only on conflicts.
@Suite("Remote ownership on the execution host (security audit 2026-10-30)")
struct RemoteOwnershipTests {
    let policy = RemoteOwnershipPolicy(executionHostId: Fixture.host)

    func change<S: EntityStorage>(_ storage: S.Type, _ value: S.Entity, kind: SyncOperationType = .update, version: Int = 50) throws -> RemoteChange {
        RemoteChange(operationId: SyncOperationID(), entityType: S.entityType, entityId: S.syncID(of: value), kind: kind,
                     version: version, baseVersion: nil, payload: kind == .delete ? nil : try S.payloadData(value),
                     systemFields: Data("server-\(version)".utf8))
    }

    /// Payload of `value` with JSON fields replaced (to forge private(set) state like a foreign device could).
    func forged<S: EntityStorage>(_ storage: S.Type, _ value: S.Entity, _ fields: [String: Any]) throws -> S.Entity {
        var object = try #require(try JSONSerialization.jsonObject(with: S.payloadData(value)) as? [String: Any])
        for (key, field) in fields { object[key] = field }
        return try S.decodePayload(JSONSerialization.data(withJSONObject: object))
    }

    /// Confirms every queued operation (as if this host had sent it).
    func sendAll(_ database: AppDatabase) async throws {
        for operation in try await database.sync.pendingOperations(limit: 10_000) {
            try await database.sync.markSent(operation.operationId, systemFields: nil, at: at(9))
        }
    }

    func rejectedConflicts(_ database: AppDatabase) async throws -> [SyncConflict] {
        try await database.sync.resolvedConflicts(limit: 100).filter { $0.resolution == RemoteOwnershipPolicy.rejectedResolution }
    }

    // MARK: Host-owned paths

    @Test func foreignRepositoryLocationWithOwnHostIdIsRejected() async throws {
        let database = try AppDatabase.inMemory()
        let (project, _) = try await database.seedItem()
        let forged = RepositoryLocation(projectId: project.id, hostId: Fixture.host, canonicalPath: "/Users/victim/secret-repo")
        let outcome = try await database.sync.applyRemoteChanges(
            [try change(RepositoryLocationStorage.self, forged, kind: .create)], engineState: nil, ownership: policy, at: at(10))
        #expect(outcome == [.stale])
        #expect(try await database.projects.locations(projectId: project.id).isEmpty)
        #expect(try await rejectedConflicts(database).count == 1)
        #expect(try await database.sync.openConflicts().isEmpty)
    }

    @Test func changedLocalRepositoryLocationIsKeptAndReasserted() async throws {
        let database = try AppDatabase.inMemory()
        let (project, _) = try await database.seedItem()
        let mine = RepositoryLocation(projectId: project.id, hostId: Fixture.host, canonicalPath: "/Users/me/Developer/app")
        try await database.projects.saveLocation(mine, at: at(1))
        let before = try database.outbox().count
        var moved = mine
        moved.canonicalPath = "/"
        let outcome = try await database.sync.applyRemoteChanges(
            [try change(RepositoryLocationStorage.self, moved)], engineState: nil, ownership: policy, at: at(10))
        #expect(outcome == [.stale])
        #expect(try await database.projects.locations(projectId: project.id).map(\.canonicalPath) == ["/Users/me/Developer/app"])
        // Our value is queued again on top of the foreign server version.
        let outbox = try database.outbox()
        #expect(outbox.count == before + 1)
        #expect(outbox.last?.type == "repositoryLocation" && outbox.last.map { $0.version > 50 } == true)
        // Deleting it remotely is refused as well.
        let deletion = try await database.sync.applyRemoteChanges(
            [try change(RepositoryLocationStorage.self, mine, kind: .delete, version: 70)], engineState: nil, ownership: policy, at: at(11))
        #expect(deletion == [.stale])
        #expect(try await database.projects.locations(projectId: project.id).count == 1)
    }

    @Test func otherHostsAndMobileDevicesAreUnaffected() async throws {
        let database = try AppDatabase.inMemory()
        let (project, _) = try await database.seedItem()
        let otherMac = RepositoryLocation(projectId: project.id, hostId: HostID(), canonicalPath: "/Users/other/app")
        #expect(try await database.sync.applyRemoteChanges(
            [try change(RepositoryLocationStorage.self, otherMac, kind: .create)], engineState: nil, ownership: policy, at: at(10)) == [.applied])
        // Without a policy (iPhone/iPad) the previous behaviour is unchanged.
        let mine = RepositoryLocation(projectId: project.id, hostId: Fixture.host, canonicalPath: "/Users/me/app")
        #expect(try await database.sync.applyRemoteChanges(
            [try change(RepositoryLocationStorage.self, mine, kind: .create)], engineState: nil, ownership: nil, at: at(11)) == [.applied])
    }

    @Test func hostOwnedLocksCapabilitiesAndApprovalsAreRejected() async throws {
        let database = try AppDatabase.inMemory()
        let (_, item) = try await database.seedItem()
        let job = Fixture.job(for: item)
        let lock = try TaskLock(taskId: item.uuid, projectId: item.projectId!, jobId: job.jobId, hostId: Fixture.host, owner: "evil",
                            acquiredAt: t0, leaseDuration: 600)
        let approval = PendingApproval(jobId: job.jobId, workItemId: item.uuid, hostId: Fixture.host, requestId: "r", kind: .commandExecution,
                                       summary: "x", requestedAt: t0)
        let outcomes = try await database.sync.applyRemoteChanges([
            try change(TaskLockStorage.self, lock, kind: .create),
            try change(AgentCapabilityStorage.self, Fixture.capability(), kind: .create),
            try change(PendingApprovalStorage.self, approval, kind: .create),
        ], engineState: nil, ownership: policy, at: at(10))
        #expect(outcomes == [.stale, .stale, .stale])
        #expect(try database.count("task_locks") == 0)
        #expect(try await rejectedConflicts(database).count == 3)
    }

    // MARK: Jobs

    @Test func jobRequestsFromOtherDevicesAreAcceptedButExecutionFieldsAreNot() async throws {
        let database = try AppDatabase.inMemory()
        let (_, item) = try await database.seedItem()
        let request = Fixture.job(for: item)
        #expect(try await database.sync.applyRemoteChanges(
            [try change(AgentJobStorage.self, request, kind: .create, version: 1)], engineState: nil, ownership: policy, at: at(10)) == [.applied])

        // A job created elsewhere already "running" in the main working tree: rejected.
        let running = try forged(AgentJobStorage.self, Fixture.job(for: item), [
            "state": "running", "worktreePath": "/Users/me/Developer/app", "branch": "main",
        ])
        #expect(try await database.sync.applyRemoteChanges(
            [try change(AgentJobStorage.self, running, kind: .create, version: 1)], engineState: nil, ownership: policy, at: at(11)) == [.stale])
        #expect(try await database.jobs.fetch(running.jobId) == nil)

        // Updating worktree path and branch of an existing job: rejected, local value kept.
        let redirected = try forged(AgentJobStorage.self, request, ["worktreePath": "/Users/me/Developer/app", "branch": "main"])
        #expect(try await database.sync.applyRemoteChanges(
            [try change(AgentJobStorage.self, redirected, version: 2)], engineState: nil, ownership: policy, at: at(12)) == [.stale])
        #expect(try await database.jobs.fetch(request.jobId)?.worktreePath == nil)

        // Admission by another device (state change) is rejected; priority and cancel are allowed.
        let admitted = try forged(AgentJobStorage.self, request, ["state": "admitted"])
        #expect(try await database.sync.applyRemoteChanges(
            [try change(AgentJobStorage.self, admitted, version: 3)], engineState: nil, ownership: policy, at: at(13)) == [.stale])
        try await sendAll(database)
        var reprioritized = request
        reprioritized.priority = .low
        try reprioritized.transition(to: .cancelled, at: at(14))
        #expect(try await database.sync.applyRemoteChanges(
            [try change(AgentJobStorage.self, reprioritized, version: 20)], engineState: nil, ownership: policy, at: at(14)) == [.applied])
        let stored = try #require(try await database.jobs.fetch(request.jobId))
        #expect(stored.priority == .low && stored.state == .cancelled)
    }

    // MARK: Reviews and setup commands

    @Test func reviewDecisionIsAllowedButExecutionDataIsNot() async throws {
        let database = try AppDatabase.inMemory()
        let (_, item) = try await database.seedItem()
        let job = Fixture.job(for: item)
        _ = try await database.jobs.create(job, actor: deviceActor, at: at(1))
        let review = Review(jobId: job.jobId, diffSummary: DiffSummary(filesChanged: 1, insertions: 1, deletions: 0, files: ["a"]),
                            headCommit: "1111111111111111111111111111111111111111")
        try await database.reviews.save(review, at: at(2))
        try await sendAll(database)

        var decided = review
        decided.decide(.approved, at: at(3))
        #expect(try await database.sync.applyRemoteChanges(
            [try change(ReviewStorage.self, decided)], engineState: nil, ownership: policy, at: at(3)) == [.applied])

        var swapped = decided
        swapped.headCommit = "2222222222222222222222222222222222222222"
        #expect(try await database.sync.applyRemoteChanges(
            [try change(ReviewStorage.self, swapped, version: 60)], engineState: nil, ownership: policy, at: at(4)) == [.stale])
        let stored = try #require(try await database.reviews.fetch(review.reviewId))
        #expect(stored.decision == .approved && stored.headCommit == review.headCommit)

        let foreign = Review(jobId: job.jobId, diffSummary: DiffSummary(filesChanged: 0, insertions: 0, deletions: 0, files: []))
        #expect(try await database.sync.applyRemoteChanges(
            [try change(ReviewStorage.self, foreign, kind: .create, version: 1)], engineState: nil, ownership: policy, at: at(5)) == [.stale])
    }

    @Test func setupCommandsArePendingRequestsOnly() async throws {
        let database = try AppDatabase.inMemory()
        let command = ProjectSetupCommand(kind: .linkProject, projectName: "App", target: .indexedFolder(path: "/Users/me/app"),
                                          hostId: Fixture.host, createdAt: t0)
        #expect(try await database.sync.applyRemoteChanges(
            [try change(ProjectSetupCommandStorage.self, command, kind: .create, version: 1)], engineState: nil, ownership: policy, at: at(1)) == [.applied])
        let completed = try forged(ProjectSetupCommandStorage.self, command, ["state": "completed", "resultPath": "/"])
        #expect(try await database.sync.applyRemoteChanges(
            [try change(ProjectSetupCommandStorage.self, completed, version: 2)], engineState: nil, ownership: policy, at: at(2)) == [.stale])
        let fresh = try forged(ProjectSetupCommandStorage.self,
                               ProjectSetupCommand(kind: .createProject, projectName: "X", target: .indexedFolder(path: "/x"),
                                                   hostId: Fixture.host, createdAt: t0),
                               ["state": "completed", "resultPath": "/etc"])
        #expect(try await database.sync.applyRemoteChanges(
            [try change(ProjectSetupCommandStorage.self, fresh, kind: .create, version: 1)], engineState: nil, ownership: policy, at: at(3)) == [.stale])
    }

    // MARK: SR-SEC-08 host-reviewed decisions

    @Test func hostReviewedAllowIsOnlyAcceptedOnTheHostPath() async throws {
        let database = try AppDatabase.inMemory()
        let (_, item) = try await database.seedItem()
        let approval = PendingApproval(jobId: JobID(), workItemId: item.uuid, hostId: Fixture.host, requestId: "r", kind: .commandExecution,
                                       summary: "x", preview: "abc", allowedDecisions: [.deny], requestedAt: t0,
                                       previewFullLength: 9_000, allowRequiresHostReview: true)
        try await database.approvals.save(approval, at: t0)
        let allow = ApprovalDecision(for: approval, decision: .allow, decidedBy: DeviceID(), at: at(1))
        await #expect(throws: StoreError.approvalDecisionNotAllowed(approval.id, .allow)) {
            try await database.approvals.recordDecision(allow)
        }
        try await database.approvals.recordHostReviewedDecision(allow)
        #expect(try await database.approvals.decisions(approvalId: approval.id) == [allow])
    }
}
