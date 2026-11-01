import Foundation
import GRDB
import SoftwareRegisseurDomain
import Testing
@testable import SoftwareRegisseurPersistence

@Suite("AgentJobRepository")
struct AgentJobRepositoryTests {
    @Test func secondCreateWithSameKeyReturnsExistingJob() async throws {
        let database = try AppDatabase.inMemory()
        let (_, item) = try await database.seedItem()
        let job = Fixture.job(for: item)
        let first = try await database.jobs.create(job, actor: deviceActor, at: at(1))
        #expect(first.wasCreated)

        // Same key, retried from another device with a different job UUID (A15).
        let retry = Fixture.job(for: item, key: job.idempotencyKey)
        let second = try await database.jobs.create(retry, actor: deviceActor, at: at(2))
        #expect(!second.wasCreated)
        #expect(second.job.jobId == job.jobId)
        #expect(try database.count("agent_jobs") == 1)
        #expect(try await database.workItems.fetch(item.uuid)?.agentJobIds == [job.jobId])
    }

    @Test func concurrentCreatesWithSameKeyProduceOneJob() async throws {
        let directory = try TemporaryDirectory()
        let database = try AppDatabase.openWriter(at: directory.databaseURL)
        let (_, item) = try await database.seedItem()
        let key = IdempotencyKey()

        let results = try await withThrowingTaskGroup(of: JobCreationResult.self) { group in
            for index in 0..<8 {
                group.addTask {
                    try await database.jobs.create(Fixture.job(for: item, key: key), actor: deviceActor, at: at(Double(index)))
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.filter(\.wasCreated).count == 1)
        #expect(Set(results.map(\.job.jobId)).count == 1)
        #expect(try database.count("agent_jobs") == 1)
        #expect(try database.count("sync_outbox", "entity_type = 'agentJob'") == 1)
    }

    @Test func differentKeyWhileJobActiveIsRejected() async throws {
        let database = try AppDatabase.inMemory()
        let (_, item) = try await database.seedItem()
        let job = Fixture.job(for: item)
        _ = try await database.jobs.create(job, actor: deviceActor, at: at(1))
        let queued = try #require(try await database.workItems.fetch(item.uuid))
        var second = Fixture.job(for: queued)
        second = AgentJob(idempotencyKey: IdempotencyKey(), projectId: second.projectId, workItemId: second.workItemId,
                          configSnapshot: Fixture.snapshot(), workItemStatusBeforeJob: queued.status, createdAt: at(2))
        await #expect(throws: StoreError.activeJobExists(workItemId: item.uuid, jobId: job.jobId)) {
            _ = try await database.jobs.create(second, actor: deviceActor, at: at(2))
        }
        #expect(try database.count("agent_jobs") == 1)
    }

    @Test func transitionWritesJobDerivedStatusAndEventAtomically() async throws {
        let database = try AppDatabase.inMemory()
        let (_, item) = try await database.seedItem()
        let job = Fixture.job(for: item)
        _ = try await database.jobs.create(job, actor: deviceActor, at: at(1))
        let host = EventActor.host(Fixture.host)

        let expected: [(AgentJobState, WorkItemStatus)] = [
            (.pendingMac, .queued), (.scheduled, .scheduled), (.admitted, .inProgress), (.starting, .inProgress),
            (.running, .inProgress), (.waitingApproval, .waitingApproval), (.running, .inProgress), (.finished, .implementationFinished),
        ]
        for (index, (state, status)) in expected.enumerated() {
            let eventsBefore = try database.count("task_events")
            let change = try await database.jobs.transition(job.jobId, to: state, actor: host, at: at(Double(10 + index)))
            #expect(change.job.state == state)
            #expect(change.workItem.status == status)
            #expect(try await database.jobs.fetch(job.jobId)?.state == state)
            #expect(try await database.workItems.fetch(item.uuid)?.status == status)
            #expect(try database.count("task_events") == eventsBefore + 1)
            #expect(change.event?.kind == .jobStateChanged)
            #expect(change.event?.payload["to"] == state.rawValue)
        }
        // Host completes the review step; `done` never comes from a job state (ADR-0012).
        let review = try await database.workItems.applyHostStatus(item.uuid, to: .review, actor: host, at: at(30))
        #expect(review.status == .review)
    }

    @Test func invalidJobTransitionLeavesJobItemAndEventsUnchanged() async throws {
        let database = try AppDatabase.inMemory()
        let (_, item) = try await database.seedItem()
        let job = Fixture.job(for: item)
        _ = try await database.jobs.create(job, actor: deviceActor, at: at(1))
        let jobBefore = try await database.jobs.fetch(job.jobId)
        let itemBefore = try await database.workItems.fetch(item.uuid)
        let eventsBefore = try database.count("task_events")
        let outboxBefore = try database.count("sync_outbox")

        await #expect(throws: StoreError.jobError(.invalidTransition(InvalidStateTransition(from: .requested, to: .running)))) {
            _ = try await database.jobs.transition(job.jobId, to: .running, actor: .host(Fixture.host), at: at(2))
        }
        #expect(try await database.jobs.fetch(job.jobId) == jobBefore)
        #expect(try await database.workItems.fetch(item.uuid) == itemBefore)
        #expect(try database.count("task_events") == eventsBefore)
        #expect(try database.count("sync_outbox") == outboxBefore)
    }

    @Test func invalidDerivedStatusRollsBackValidJobTransition() async throws {
        let database = try AppDatabase.inMemory()
        let (_, item) = try await database.seedItem()
        let job = Fixture.job(for: item)
        _ = try await database.jobs.create(job, actor: deviceActor, at: at(1))
        // Simulate an inconsistent item (e.g. external edit) that cannot follow the job.
        try await database.writer!.write { db in
            try db.execute(sql: "UPDATE work_items SET status = 'done' WHERE uuid = ?", arguments: [item.uuid.uuidString])
        }
        let jobBefore = try await database.jobs.fetch(job.jobId)
        let itemBefore = try await database.workItems.fetch(item.uuid)
        let eventsBefore = try database.count("task_events")
        let outboxBefore = try database.count("sync_outbox")

        await #expect(throws: StoreError.invalidWorkItemTransition(InvalidStateTransition(from: .done, to: .inProgress))) {
            _ = try await database.jobs.transition(job.jobId, to: .admitted, actor: .host(Fixture.host), at: at(2))
        }
        #expect(try await database.jobs.fetch(job.jobId) == jobBefore)
        #expect(try await database.workItems.fetch(item.uuid) == itemBefore)
        #expect(try database.count("task_events") == eventsBefore)
        #expect(try database.count("sync_outbox") == outboxBefore)
    }

    @Test func cancelRestoresStatusBeforeJobAndAllowsNewJob() async throws {
        let database = try AppDatabase.inMemory()
        let (_, item) = try await database.seedItem(status: .open)
        let job = Fixture.job(for: item)
        _ = try await database.jobs.create(job, actor: deviceActor, at: at(1))
        _ = try await database.jobs.transition(job.jobId, to: .scheduled, actor: .host(Fixture.host), at: at(2))
        let change = try await database.jobs.transition(job.jobId, to: .cancelled, actor: deviceActor, at: at(3))
        #expect(change.workItem.status == .open)
        #expect(change.job.finishedAt == at(3))
        #expect(try await database.jobs.activeJob(forWorkItem: item.uuid) == nil)

        let current = try #require(try await database.workItems.fetch(item.uuid))
        let next = try await database.jobs.create(Fixture.job(for: current), actor: deviceActor, at: at(4))
        #expect(next.wasCreated)
        #expect(try await database.jobs.jobs(forWorkItem: item.uuid).count == 2)
    }

    @Test func configurationSnapshotIsImmutableAfterStart() async throws {
        let database = try AppDatabase.inMemory()
        let (_, item) = try await database.seedItem()
        let job = Fixture.job(for: item)
        _ = try await database.jobs.create(job, actor: deviceActor, at: at(1))

        // Explicit replacement before start is allowed and recorded.
        let replacement = ConfigurationSnapshot(
            providerId: .codex, requestedModel: .providerDefault, requestedEffort: .auto, resolvedModel: .providerDefault,
            resolvedEffort: .auto, profileSource: ProfileSources(model: .job, effort: .job), capabilityRevision: 4,
            agentVersion: "0.51.0", createdAt: at(2)
        )
        let replaced = try await database.jobs.update(job.jobId, expectedRevision: 1, actor: deviceActor, at: at(2)) {
            try $0.replaceConfiguration(with: replacement, at: at(2))
        }
        #expect(replaced.event?.kind == .configurationReplaced)
        #expect(try await database.jobs.fetch(job.jobId)?.configSnapshot == replacement)

        for state in [AgentJobState.admitted, .starting] {
            _ = try await database.jobs.transition(job.jobId, to: state, actor: .host(Fixture.host), at: at(3))
        }
        // The database trigger rejects any later snapshot change, even bypassing the domain.
        #expect(throws: DatabaseError.self) {
            try database.writer!.write { db in
                try db.execute(sql: "UPDATE agent_jobs SET config_snapshot = '{}' WHERE job_id = ?", arguments: [job.jobId.uuidString])
            }
        }
        #expect(try await database.jobs.fetch(job.jobId)?.configSnapshot == replacement)
    }

    @Test func queueOrderingAndDueJobs() async throws {
        let database = try AppDatabase.inMemory()
        var jobs: [AgentJob] = []
        let schedules: [JobSchedule] = [
            JobSchedule(kind: .notBefore(at(3600))),
            JobSchedule(kind: .immediate),
            JobSchedule(kind: .notBefore(at(60))),
        ]
        for schedule in schedules {
            let (_, item) = try await database.seedItem()
            let job = Fixture.job(for: item, schedule: schedule)
            _ = try await database.jobs.create(job, actor: deviceActor, at: at(1))
            jobs.append(job)
        }
        let queue = try await database.jobs.jobs(inStates: [.requested], hostId: nil, limit: nil)
        #expect(queue.map(\.jobId) == [jobs[1].jobId, jobs[2].jobId, jobs[0].jobId])
        let due = try await database.jobs.dueJobs(at: at(120), states: [.requested])
        #expect(Set(due.map(\.jobId)) == [jobs[1].jobId, jobs[2].jobId])
        #expect(try await database.jobs.jobs(inStates: [.requested], hostId: Fixture.host, limit: 1).count == 1)
    }
}
