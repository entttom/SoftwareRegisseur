import Foundation
import SoftwareRegisseurAgents
import SoftwareRegisseurDomain
import SoftwareRegisseurGit
import SoftwareRegisseurJobs
import SoftwareRegisseurPersistence
import Testing

@Suite("Run lifecycle: start, review, parallelism, limits")
struct RunLifecycleTests {
    @Test("A13/A22: Codex run → worktree, lock, session, effective config, review (not done)")
    func codexRunToReview() async throws {
        let env = try await TestEnvironment()
        let orchestrator = try env.orchestrator(requestFilePath: { _ in "docs/requests/open/FR-0001-export.md" })
        let item = try await env.addWorkItem("Export")
        env.codex.enqueue(Scripts.writeAndCommit(commitWith: env.git, model: codexModel, effort: .high))
        let job = try await env.request(orchestrator, item, override: JobConfigurationOverride(
            providerId: .codex, model: .model(codexModel), effort: .high))

        let report = await orchestrator.tick(now: t0)
        #expect(report.takenOver == [job.jobId])
        #expect(report.started == [job.jobId])
        let lockDuringRun = try await env.database.locks.activeLock(forTask: item.uuid)
        #expect(lockDuringRun?.jobId == job.jobId)
        await orchestrator.waitUntilSessionEnds(job.jobId)

        let finished = try await env.job(job.jobId)
        #expect(finished.state == .finished)
        #expect(finished.hostId == env.hostId)
        #expect(finished.branch == "software-regisseur/\(item.uuid.shortString)/\(job.jobId.shortString)")
        let worktree = try #require(finished.worktreePath)
        #expect(worktree.hasPrefix(env.root.appending(path: "worktrees").path(percentEncoded: false)))
        #expect(finished.sessionId == "session-\(job.jobId.uuidString)")
        #expect(finished.effectiveModelId == codexModel)
        #expect(finished.effectiveEffort == .high)
        #expect(finished.configSnapshot == job.configSnapshot)
        // Adapter received exactly the snapshot values (A41 at orchestration level).
        #expect(env.codex.plans.first?.modelArgument == codexModel)
        #expect(env.codex.plans.first?.effortArgument == .high)
        #expect(env.codex.requests.first?.prompt.contains("Export") == true)
        #expect(env.codex.requests.first?.prompt.contains("docs/requests/open/FR-0001-export.md") == true)
        // ADR-0024: the agent is told that request/ADR files belong to the Mac app (default layout folders).
        #expect(env.codex.requests.first?.prompt.contains(AgentPromptBuilder.managedDocumentsRule) == true)
        #expect(env.codex.requests.first?.prompt.contains("(folders `docs/adr`, `docs/requests`)") == true)

        let updated = try await env.item(item.uuid)
        #expect(updated.status == .review)
        let reviews = try await env.database.reviews.reviews(jobId: job.jobId)
        let review = try #require(reviews.first)
        #expect(review.decision == .pending)
        #expect(review.diffSummary.files == ["feature.txt"])
        #expect(review.testResults == [TestResult(name: "swift test", outcome: .passed)])
        let details = try #require(await orchestrator.reviewDetails(review.reviewId))
        #expect(details.commits.count == 1)
        #expect(details.agentSummary?.contains("Fertig") == true)
        #expect(details.autoCommittedPaths.isEmpty)
        #expect(try await env.database.locks.activeLock(forTask: item.uuid) == nil)
        // Default branch untouched (spec J3: no implicit writes to productive branches).
        #expect(try String(contentsOf: env.repo.appending(path: "feature.txt"), encoding: .utf8) == "Basis\n")
        let kinds = try await env.database.events.events(forWorkItem: item.uuid).map(\.kind)
        #expect(kinds.contains(.lockAcquired) && kinds.contains(.lockReleased) && kinds.contains(.jobStateChanged))
    }

    @Test("A14: Claude run without own commit → output committed on job branch, effort not confirmed")
    func claudeRunAutoCommits() async throws {
        let env = try await TestEnvironment()
        let orchestrator = try env.orchestrator()
        let item = try await env.addWorkItem("Suche")
        env.claude.enqueue(Scripts.writeAndCommit(file: "search.swift", content: "let x = 1\n", model: claudeModel))
        let job = try await env.request(orchestrator, item, provider: .claudeCode,
                                        override: JobConfigurationOverride(providerId: .claudeCode, model: .model(claudeModel), effort: .max))
        await orchestrator.tick(now: t0)
        await orchestrator.waitUntilSessionEnds(job.jobId)

        let finished = try await env.job(job.jobId)
        #expect(finished.state == .finished)
        #expect(finished.effectiveModelId == claudeModel)
        #expect(finished.effectiveEffortDisplayText == AgentJob.unconfirmedText)
        #expect(env.claude.requests.first?.sessionUUID == job.jobId.rawValue)
        let review = try #require(try await env.database.reviews.reviews(jobId: job.jobId).first)
        #expect(review.diffSummary.files == ["search.swift"])
        let details = try #require(await orchestrator.reviewDetails(review.reviewId))
        #expect(details.autoCommittedPaths == ["search.swift"])
        let status = try await env.git.status(of: URL(filePath: try #require(finished.worktreePath)))
        #expect(status.isClean)
        #expect(try await env.item(item.uuid).status == .review)
    }

    @Test("A15: same task started twice quickly → only one run")
    func doubleStartPrevented() async throws {
        let env = try await TestEnvironment()
        let orchestrator = try env.orchestrator()
        let item = try await env.addWorkItem("Doppelt")
        env.codex.enqueue(Scripts.hang())
        let key = IdempotencyKey()
        let first = try await env.request(orchestrator, item, key: key)
        let again = try await orchestrator.requestJob(workItemId: item.uuid, providerId: .codex, idempotencyKey: key, by: env.user)
        #expect(!again.wasCreated && again.job.jobId == first.jobId)
        await #expect(throws: StoreError.self) {
            _ = try await env.request(orchestrator, item, key: IdempotencyKey())
        }
        await orchestrator.tick(now: t0)
        await orchestrator.tick(now: t0.addingTimeInterval(1))
        await orchestrator.tick(now: t0.addingTimeInterval(2))
        #expect(env.codex.startCount == 1)
        #expect(try await env.database.jobs.jobs(forWorkItem: item.uuid).count == 1)

        try await orchestrator.cancel(jobId: first.jobId, by: env.user)
        await orchestrator.waitUntilSessionEnds(first.jobId)
        #expect(try await env.job(first.jobId).state == .cancelled)
        #expect(try await env.item(item.uuid).status == .open)
        #expect(try await env.database.locks.activeLock(forTask: item.uuid) == nil)
    }

    @Test("A16: two tasks in parallel → separate worktrees and branches, no cross-write")
    func twoTasksInParallel() async throws {
        let env = try await TestEnvironment()
        let orchestrator = try env.orchestrator()
        let a = try await env.addWorkItem("A")
        let b = try await env.addWorkItem("B")
        env.codex.enqueue(Scripts.hang(writing: "a.txt"))
        env.codex.enqueue(Scripts.hang(writing: "b.txt"))
        let jobA = try await env.request(orchestrator, a, priority: .high)
        let jobB = try await env.request(orchestrator, b)
        let report = await orchestrator.tick(now: t0)
        #expect(Set(report.started) == [jobA.jobId, jobB.jobId])
        try await eventually {
            let ja = try await env.job(jobA.jobId), jb = try await env.job(jobB.jobId)
            guard let wa = ja.worktreePath, let wb = jb.worktreePath else { return false }
            return env.fileExists("a.txt", in: URL(filePath: wa)) && env.fileExists("b.txt", in: URL(filePath: wb))
        }
        let ja = try await env.job(jobA.jobId), jb = try await env.job(jobB.jobId)
        #expect(ja.worktreePath != jb.worktreePath)
        #expect(ja.branch != jb.branch)
        #expect(!env.fileExists("b.txt", in: URL(filePath: try #require(ja.worktreePath))))
        #expect(!env.fileExists("a.txt", in: URL(filePath: try #require(jb.worktreePath))))
        #expect(!env.fileExists("a.txt", in: env.repo) && !env.fileExists("b.txt", in: env.repo))
        let branches = try await env.output(["branch", "--list", "software-regisseur/*", "--format=%(refname:short)"])
        #expect(branches.split(separator: "\n").count == 2)
        for job in [jobA, jobB] {
            try await orchestrator.cancel(jobId: job.jobId, by: env.user)
            await orchestrator.waitUntilSessionEnds(job.jobId)
        }
    }

    @Test("Limits: global, per provider, project-wide lock; queued job starts when a slot frees up")
    func concurrencyLimits() async throws {
        let env = try await TestEnvironment()
        let orchestrator = try env.orchestrator(limits: ConcurrencyLimits(global: 1, perProject: 4))
        let a = try await env.addWorkItem("A")
        let b = try await env.addWorkItem("B")
        env.codex.enqueue(Scripts.hang())
        let jobA = try await env.request(orchestrator, a, priority: .urgent)
        let jobB = try await env.request(orchestrator, b)
        let first = await orchestrator.tick(now: t0)
        #expect(first.started == [jobA.jobId])
        #expect(first.blocked[jobB.jobId] == .globalLimit(1))
        #expect(try await env.job(jobB.jobId).state == .scheduled)
        try await orchestrator.cancel(jobId: jobA.jobId, by: env.user)
        await orchestrator.waitUntilSessionEnds(jobA.jobId)
        let second = await orchestrator.tick(now: t0.addingTimeInterval(5))
        #expect(second.started == [jobB.jobId])
        await orchestrator.waitUntilSessionEnds(jobB.jobId)

        let providerEnv = try await TestEnvironment()
        let limited = try providerEnv.orchestrator(limits: ConcurrencyLimits(global: 4, perProject: 4, perProvider: [.codex: 1]))
        let c1 = try await providerEnv.addWorkItem("C1")
        let c2 = try await providerEnv.addWorkItem("C2")
        let c3 = try await providerEnv.addWorkItem("C3")
        providerEnv.codex.enqueue(Scripts.hang())
        providerEnv.claude.enqueue(Scripts.hang())
        let j1 = try await providerEnv.request(limited, c1, priority: .high)
        let j2 = try await providerEnv.request(limited, c2)
        let j3 = try await providerEnv.request(limited, c3, provider: .claudeCode)
        let report = await limited.tick(now: t0)
        #expect(Set(report.started) == [j1.jobId, j3.jobId])
        #expect(report.blocked[j2.jobId] == .providerLimit(.codex, 1))
        for job in [j1, j3] {
            try await limited.cancel(jobId: job.jobId, by: providerEnv.user)
            await limited.waitUntilSessionEnds(job.jobId)
        }

        let lockedEnv = try await TestEnvironment(projectWideLock: true)
        let locked = try lockedEnv.orchestrator()
        let l1 = try await lockedEnv.addWorkItem("L1")
        let l2 = try await lockedEnv.addWorkItem("L2")
        lockedEnv.codex.enqueue(Scripts.hang())
        let k1 = try await lockedEnv.request(locked, l1, priority: .high)
        let k2 = try await lockedEnv.request(locked, l2)
        let lockedReport = await locked.tick(now: t0)
        #expect(lockedReport.started == [k1.jobId])
        guard case .projectLocked = lockedReport.blocked[k2.jobId] else {
            Issue.record("expected project lock, got \(String(describing: lockedReport.blocked[k2.jobId]))")
            return
        }
        try await locked.cancel(jobId: k1.jobId, by: lockedEnv.user)
        await locked.waitUntilSessionEnds(k1.jobId)
    }

    @Test("Dependencies: job waits until the dependency is done")
    func dependenciesGateAdmission() async throws {
        let env = try await TestEnvironment()
        let orchestrator = try env.orchestrator()
        let base = try await env.addWorkItem("Basis")
        let dependent = try await env.addWorkItem("Aufbau", dependencies: [base.uuid])
        let job = try await env.request(orchestrator, dependent)
        let report = await orchestrator.tick(now: t0)
        #expect(report.blocked[job.jobId] == .dependenciesOpen([base.uuid]))
        let current = try await env.item(base.uuid)
        _ = try await env.database.workItems.changeStatus(base.uuid, to: .done, expectedRevision: current.revision, actor: env.user, at: t0)
        let next = await orchestrator.tick(now: t0.addingTimeInterval(1))
        #expect(next.started == [job.jobId])
        await orchestrator.waitUntilSessionEnds(job.jobId)
    }

    @Test("Start failure → job failed, lock released after verification, no hidden retry")
    func startFailure() async throws {
        let env = try await TestEnvironment()
        let orchestrator = try env.orchestrator()
        let item = try await env.addWorkItem("Startfehler")
        env.codex.failNextStart()
        let job = try await env.request(orchestrator, item)
        let report = await orchestrator.tick(now: t0)
        #expect(report.started.isEmpty)
        #expect(report.failed[job.jobId]?.contains("Prozess nicht startbar") == true)
        let failed = try await env.job(job.jobId)
        #expect(failed.state == .failed)
        #expect(try await env.item(item.uuid).status == .failed)
        #expect(try await env.database.locks.activeLock(forTask: item.uuid) == nil)
        await orchestrator.tick(now: t0.addingTimeInterval(60))
        #expect(env.codex.startCount == 0)
    }

    @Test("Pause stops the agent; resume re-queues and continues in the same worktree")
    func pauseAndResume() async throws {
        let env = try await TestEnvironment()
        let orchestrator = try env.orchestrator()
        let item = try await env.addWorkItem("Pause")
        env.codex.enqueue(Scripts.hang(writing: "zwischenstand.txt"))
        let job = try await env.request(orchestrator, item)
        await orchestrator.tick(now: t0)
        try await orchestrator.pause(jobId: job.jobId, by: env.user)
        await orchestrator.waitUntilSessionEnds(job.jobId)
        let paused = try await env.job(job.jobId)
        #expect(paused.state == .paused)
        #expect(try await env.item(item.uuid).status == .paused)
        let worktree = try #require(paused.worktreePath)

        try await orchestrator.resume(jobId: job.jobId, by: env.user)
        #expect(try await env.job(job.jobId).state == .scheduled)
        let report = await orchestrator.tick(now: t0.addingTimeInterval(30))
        #expect(report.started == [job.jobId])
        await orchestrator.waitUntilSessionEnds(job.jobId)
        let finished = try await env.job(job.jobId)
        #expect(finished.state == .finished)
        #expect(finished.worktreePath == worktree)
        #expect(env.codex.startCount == 2)
        #expect(env.codex.requests[1].sessionUUID != env.codex.requests[0].sessionUUID)
        let review = try #require(try await env.database.reviews.reviews(jobId: job.jobId).first)
        #expect(Set(review.diffSummary.files) == ["feature.txt", "zwischenstand.txt"])
    }
}
