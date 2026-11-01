import Foundation
import SoftwareRegisseurAgents
import SoftwareRegisseurDomain
import SoftwareRegisseurGit
import SoftwareRegisseurJobs
import SoftwareRegisseurPersistence
import Testing

@Suite("Crash recovery, review/integration, hosts, configuration snapshots")
struct RecoveryAndIntegrationTests {
    @Test("A21: service crash mid-run, agent gone → failed, lock released, worktree kept, no restart")
    func crashWithDeadProcess() async throws {
        let env = try await TestEnvironment()
        let crashed = try env.orchestrator()
        let item = try await env.addWorkItem("Absturz")
        env.codex.enqueue(Scripts.hang(writing: "partial.txt"))
        let job = try await env.request(crashed, item)
        await crashed.tick(now: t0)
        try await eventually {
            guard let path = try await env.job(job.jobId).worktreePath else { return false }
            return env.fileExists("partial.txt", in: URL(filePath: path))
        }
        let pid = try #require(await crashed.runtimeRecord(for: job.jobId)?.processIdentifier)
        env.inspector.setAlive(pid, false)

        // New service instance on the same database and runtime directory; the old one is gone.
        env.clock.set(t0.addingTimeInterval(120))
        let restarted = try env.orchestrator()
        let report = await restarted.recover(at: t0.addingTimeInterval(120))
        #expect(report.actions[job.jobId] == .failed(preservedWorktree: true))
        #expect(report.releasedLocks.count == 1)
        let failed = try await env.job(job.jobId)
        #expect(failed.state == .failed)
        #expect(try await env.item(item.uuid).status == .failed)
        #expect(try await env.database.locks.activeLock(forTask: item.uuid) == nil)
        #expect(env.fileExists("partial.txt", in: URL(filePath: try #require(failed.worktreePath))))
        await restarted.tick(now: t0.addingTimeInterval(180))
        #expect(env.codex.startCount == 1)
        let releaseEvents = try await env.database.events.events(forWorkItem: item.uuid).filter { $0.kind == .lockReleased }
        #expect(releaseEvents.first?.payload["reason"] == "jobFailed")
        #expect(releaseEvents.first?.payload["preserveWorktree"] == "true")
    }

    @Test("A21: agent survives the crash → paused, lock kept, no second start until the process ended")
    func crashWithOrphanedProcess() async throws {
        let env = try await TestEnvironment()
        let crashed = try env.orchestrator(lease: 300)
        let item = try await env.addWorkItem("Waise")
        env.codex.enqueue(Scripts.hang(writing: "partial.txt"))
        let job = try await env.request(crashed, item)
        await crashed.tick(now: t0)
        let pid = try #require(await crashed.runtimeRecord(for: job.jobId)?.processIdentifier)
        env.inspector.setAlive(pid, true)

        let restarted = try env.orchestrator(lease: 300)
        let report = await restarted.recover(at: t0.addingTimeInterval(60))
        #expect(report.actions[job.jobId] == .orphanPaused(pid: pid))
        #expect(try await env.job(job.jobId).state == .paused)
        #expect(report.keptLocks.values.contains(.keep(.processStillRunning)) || report.keptLocks.values.contains(.keep(.leaseActive)))
        await #expect(throws: JobOrchestratorError.orphanProcessRunning(job.jobId)) {
            try await restarted.resume(jobId: job.jobId, by: env.user)
        }
        await restarted.tick(now: t0.addingTimeInterval(400))
        #expect(env.codex.startCount == 1)
        #expect(try await env.database.locks.activeLock(forTask: item.uuid) != nil)

        #expect(try await restarted.terminateOrphanedProcess(jobId: job.jobId, by: env.user))
        #expect(env.inspector.terminated == [pid])
        let released = await restarted.tick(now: t0.addingTimeInterval(460))
        #expect(released.releasedLocks.count == 1)
        try await restarted.resume(jobId: job.jobId, by: env.user)
        let resumed = await restarted.tick(now: t0.addingTimeInterval(500))
        #expect(resumed.started == [job.jobId])
        await restarted.waitUntilSessionEnds(job.jobId)
        #expect(env.codex.startCount == 2)
        #expect(try await env.job(job.jobId).state == .finished)
    }

    @Test("A22/A23: review is not done; integrate only after approval; done only after integration")
    func reviewIntegrateDone() async throws {
        let env = try await TestEnvironment()
        let orchestrator = try env.orchestrator()
        let item = try await env.addWorkItem("Integration")
        env.codex.enqueue(Scripts.writeAndCommit(commitWith: env.git))
        let job = try await env.request(orchestrator, item)
        await orchestrator.tick(now: t0)
        await orchestrator.waitUntilSessionEnds(job.jobId)
        let review = try #require(try await env.database.reviews.reviews(jobId: job.jobId).first)
        #expect(try await env.item(item.uuid).status == .review)

        await #expect(throws: JobOrchestratorError.notIntegrated(.review)) {
            try await orchestrator.markDone(workItemId: item.uuid, approvedBy: env.user)
        }
        await #expect(throws: JobOrchestratorError.reviewNotApproved(.pending)) {
            _ = try await orchestrator.integrate(reviewId: review.reviewId, approvedBy: env.user)
        }
        await #expect(throws: JobOrchestratorError.userDecisionRequired) {
            try await orchestrator.approveReview(review.reviewId, by: .host(env.hostId))
        }
        let mainBefore = try await env.output(["rev-parse", "main"])
        try await orchestrator.approveReview(review.reviewId, by: env.user)
        let result = try await orchestrator.integrate(reviewId: review.reviewId, approvedBy: env.user)
        #expect(result.previousDefaultBranchCommit == mainBefore)
        #expect(try await env.output(["rev-parse", "main"]) == result.commitSHA)
        #expect(try String(contentsOf: env.repo.appending(path: "feature.txt"), encoding: .utf8) == "Agentenergebnis\n")
        #expect(try await env.output(["rev-list", "--count", "\(mainBefore)..main"]) == "1") // squash (ADR-0015)
        #expect(try await env.database.reviews.fetch(review.reviewId)?.integrationCommit == result.commitSHA)
        #expect(try await env.item(item.uuid).status == .integrated)
        #expect(try await env.item(item.uuid).reviewState == .approved)

        let done = try await orchestrator.markDone(workItemId: item.uuid, approvedBy: env.user)
        #expect(done.status == .done)
        let kinds = try await env.database.events.events(forWorkItem: item.uuid).map(\.kind)
        #expect(kinds.contains(.reviewDecided) && kinds.contains(.integrated))
        #expect(try await env.output(["remote"]).isEmpty)
    }

    @Test("Integration conflict → reported in review, nothing half-applied")
    func integrationConflict() async throws {
        let env = try await TestEnvironment()
        let orchestrator = try env.orchestrator()
        let item = try await env.addWorkItem("Konflikt")
        env.codex.enqueue(Scripts.writeAndCommit(commitWith: env.git))
        let job = try await env.request(orchestrator, item)
        await orchestrator.tick(now: t0)
        await orchestrator.waitUntilSessionEnds(job.jobId)
        try Data("Benutzeränderung\n".utf8).write(to: env.repo.appending(path: "feature.txt"))
        try await env.git.run(["commit", "--quiet", "-am", "User change"], in: env.repo)
        let mainBefore = try await env.output(["rev-parse", "main"])

        let review = try #require(try await env.database.reviews.reviews(jobId: job.jobId).first)
        try await orchestrator.approveReview(review.reviewId, by: env.user)
        await #expect(throws: JobOrchestratorError.integrationConflict(files: ["feature.txt"])) {
            _ = try await orchestrator.integrate(reviewId: review.reviewId, approvedBy: env.user)
        }
        #expect(try await env.output(["rev-parse", "main"]) == mainBefore)
        #expect(try await env.git.status(of: env.repo).isClean)
        #expect(try await env.item(item.uuid).status == .review)
        let details = try #require(await orchestrator.reviewDetails(review.reviewId))
        #expect(details.integrationConflictFiles == ["feature.txt"])
        #expect(try await env.database.reviews.fetch(review.reviewId)?.integrationCommit == nil)
    }

    @Test("A33: a foreign host never takes over or admits the project's jobs")
    func foreignHostDoesNotAdmit() async throws {
        let env = try await TestEnvironment()
        let owner = try env.orchestrator()
        let foreignHost = HostID()
        let foreign = try env.orchestrator(hostId: foreignHost)
        let item = try await env.addWorkItem("Zwei Macs")
        let job = try await env.request(owner, item)

        let foreignReport = await foreign.tick(now: t0)
        #expect(foreignReport.foreign == [job.jobId])
        #expect(foreignReport.started.isEmpty)
        #expect(try await env.job(job.jobId).state == .requested)
        #expect(env.codex.startCount == 0)

        async let a = owner.tick(now: t0.addingTimeInterval(1))
        async let b = foreign.tick(now: t0.addingTimeInterval(1))
        let (ownerReport, otherReport) = await (a, b)
        #expect(ownerReport.started == [job.jobId])
        #expect(otherReport.started.isEmpty)
        await owner.waitUntilSessionEnds(job.jobId)
        #expect(env.codex.startCount == 1)
        #expect(try await env.job(job.jobId).hostId == env.hostId)
    }

    @Test("A39/A40: snapshot fixed across restart and preference change; capability change blocks before start")
    func snapshotStableAndRevalidated() async throws {
        let env = try await TestEnvironment()
        let first = try env.orchestrator()
        try await env.database.preferences.save(AgentModelPreference(
            scope: .project(env.project.id), providerId: .codex, model: .model(codexModel), effort: .medium, updatedAt: t0), at: t0)
        let item = try await env.addWorkItem("Später")
        let job = try await env.request(first, item, schedule: JobSchedule(kind: .notBefore(t0.addingTimeInterval(3600))))
        #expect(job.resolvedModelId == codexModel && job.resolvedEffort == .medium)
        #expect(job.profileSource == ProfileSources(model: .project, effort: .project))
        await first.tick(now: t0)

        // Preference changes only affect new jobs (A38/A39).
        try await env.database.preferences.save(AgentModelPreference(
            scope: .project(env.project.id), providerId: .codex, model: .model(codexMini), effort: .low, updatedAt: t0), at: t0)
        let restarted = try env.orchestrator()
        _ = await restarted.recover(at: t0.addingTimeInterval(600))
        await restarted.tick(now: t0.addingTimeInterval(600))
        #expect(try await env.job(job.jobId).configSnapshot == job.configSnapshot)

        // Agent upgrade drops the model → blocked before start, no fallback (A40).
        env.codex.setCapability(capability(.codex, hostId: env.hostId, models: [(codexMini, [.low])], revision: 2))
        let due = await restarted.tick(now: t0.addingTimeInterval(3601))
        #expect(due.started.isEmpty)
        #expect(due.needsConfiguration[job.jobId] == [.unknownModel(codexModel)])
        let blocked = try await env.job(job.jobId)
        #expect(blocked.state == .needsConfiguration)
        #expect(blocked.configSnapshot == job.configSnapshot)
        #expect(try await env.item(item.uuid).status == .blocked)
        #expect(env.codex.startCount == 0)
        #expect(try await env.database.capabilities.capability(hostId: env.hostId, providerId: .codex)?.capabilityRevision == 2)
        #expect(await restarted.tick(now: t0.addingTimeInterval(3700)).started.isEmpty)

        // Explicit new selection by the user.
        let resolution = ModelEffortResolver.resolve(
            jobOverride: JobConfigurationOverride(providerId: .codex, model: .model(codexMini), effort: .low),
            projectPreference: nil, globalPreference: nil, capability: env.codex.capability)
        let snapshot = try #require(resolution.configuration).makeSnapshot(createdAt: t0.addingTimeInterval(3700))
        await #expect(throws: JobOrchestratorError.userDecisionRequired) {
            try await restarted.replaceConfiguration(jobId: job.jobId, with: snapshot, by: .host(env.hostId))
        }
        try await restarted.replaceConfiguration(jobId: job.jobId, with: snapshot, by: env.user)
        let started = await restarted.tick(now: t0.addingTimeInterval(3800))
        #expect(started.started == [job.jobId])
        #expect(env.codex.plans.first?.modelArgument == codexMini)
        #expect(env.codex.plans.first?.effortArgument == .low)
        await restarted.waitUntilSessionEnds(job.jobId)
    }

    @Test("Darwin process inspector: pid liveness and working-directory scan")
    func darwinInspector() async throws {
        let inspector = DarwinProcessInspector()
        #expect(inspector.observe(pid: getpid(), startedAt: nil) == .running)
        #expect(inspector.observe(pid: 999_999, startedAt: nil) == .notRunning)
        let directory = try PathGuard.canonicalize(FileManager.default.temporaryDirectory)
            .appending(path: "SRInspector-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(inspector.observeProcesses(inside: directory) == .notRunning)
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sleep")
        process.arguments = ["30"]
        process.currentDirectoryURL = directory
        try process.run()
        let started = try #require(inspector.startTime(of: process.processIdentifier))
        #expect(inspector.observe(pid: process.processIdentifier, startedAt: started) == .running)
        #expect(inspector.observe(pid: process.processIdentifier, startedAt: started.addingTimeInterval(-3600)) == .notRunning)
        // The child changes into its working directory right after spawning.
        try await eventually { inspector.observeProcesses(inside: directory) == .running }
        process.terminate()
        process.waitUntilExit()
        #expect(inspector.observe(pid: process.processIdentifier, startedAt: started) == .notRunning)
        #expect(inspector.observeProcesses(inside: directory) == .notRunning)
    }
}
