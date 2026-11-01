import Foundation
import SoftwareRegisseurAgents
import SoftwareRegisseurDomain
import SoftwareRegisseurGit
import SoftwareRegisseurJobs
import SoftwareRegisseurPersistence
import Testing

@Suite("Synced approvals, review content, retry links, process-group liveness")
struct ContractTests {
    @Test("J6 fallback: an iPhone decision synced into the database is relayed exactly once")
    func syncedDecisionIsRelayedOnce() async throws {
        let env = try await TestEnvironment()
        let orchestrator = try env.orchestrator(approvalTimeout: ApprovalTimeoutPolicy(timeout: nil))
        let item = try await env.addWorkItem("Freigabe vom iPhone")
        env.codex.enqueue(Scripts.approval("perm-7"))
        let job = try await env.request(orchestrator, item)
        await orchestrator.tick(now: t0)
        try await eventually { try await env.job(job.jobId).state == .waitingApproval }
        let approval = try #require(await orchestrator.pendingApprovals(for: job.jobId).first)
        #expect(approval.requestId == "perm-7" && approval.hostId == env.hostId && approval.isOpen)
        #expect(approval.summary == "Der Agent möchte einen Befehl ausführen.")
        #expect(approval.allowedDecisions == [.allow, .deny])
        #expect(approval.expiresAt == nil)

        // Nothing is answered without an explicit decision.
        let idle = await orchestrator.tick(now: t0.addingTimeInterval(5))
        #expect(idle.approvalsAnswered.isEmpty)
        #expect(env.codex.sessions.first?.control.decisions.isEmpty == true)

        let phone = DeviceID()
        let decision = ApprovalDecision(for: approval, decision: .allow, decidedBy: phone, at: t0.addingTimeInterval(10))
        try await env.database.approvals.recordDecision(decision)
        let report = await orchestrator.tick(now: t0.addingTimeInterval(11))
        #expect(report.approvalsAnswered == [approval.id])
        await orchestrator.waitUntilSessionEnds(job.jobId)
        #expect(env.codex.sessions.first?.control.decisions == ["perm-7": .allow])
        let answered = try #require(try await env.database.approvals.fetch(approval.id))
        #expect(answered.state == .answered && answered.decisionId == decision.id)
        #expect(try await env.job(job.jobId).state == .finished)

        // Idempotent: later decisions for the answered request are refused and nothing is relayed again.
        await #expect(throws: StoreError.approvalClosed(approval.id, .answered)) {
            try await env.database.approvals.recordDecision(ApprovalDecision(for: approval, decision: .deny, decidedBy: phone,
                                                                             at: t0.addingTimeInterval(12)))
        }
        #expect(await orchestrator.tick(now: t0.addingTimeInterval(13)).approvalsAnswered.isEmpty)
        let events = try await env.database.events.events(forWorkItem: item.uuid)
        let answeredEvent = try #require(events.first { $0.kind == .approvalAnswered })
        #expect(answeredEvent.actor == .user(phone) && answeredEvent.payload["device"] == phone.uuidString)
        #expect(!events.contains { $0.kind == .comment && ["approvalRequested", "approvalAnswered"].contains($0.payload["type"] ?? "") })
    }

    @Test("A decision after expiry is ignored; the run is stopped without approval")
    func decisionForExpiredApprovalIsIgnored() async throws {
        let env = try await TestEnvironment()
        let orchestrator = try env.orchestrator(approvalTimeout: ApprovalTimeoutPolicy(timeout: 300, action: .fail))
        let item = try await env.addWorkItem("Abgelaufen")
        env.codex.enqueue(Scripts.approval("x"))
        let job = try await env.request(orchestrator, item)
        await orchestrator.tick(now: t0)
        try await eventually { try await env.job(job.jobId).state == .waitingApproval }
        let approval = try #require(await orchestrator.pendingApprovals(for: job.jobId).first)
        #expect(approval.expiresAt == t0.addingTimeInterval(300))
        // Decided after the deadline (e.g. the phone was offline): recorded, but never relayed.
        try await env.database.approvals.recordDecision(ApprovalDecision(for: approval, decision: .allow, decidedBy: DeviceID(),
                                                                         at: t0.addingTimeInterval(400)))
        let report = await orchestrator.tick(now: t0.addingTimeInterval(401))
        #expect(report.approvalsAnswered.isEmpty)
        await orchestrator.waitUntilSessionEnds(job.jobId)
        #expect(env.codex.sessions.first?.control.decisions.isEmpty == true)
        #expect(try await env.job(job.jobId).state == .failed)
        #expect(try await env.database.approvals.fetch(approval.id)?.state == .expired)
    }

    @Test("Session end withdraws open approvals; later decisions are refused")
    func cancelledSessionWithdrawsApprovals() async throws {
        let env = try await TestEnvironment()
        let orchestrator = try env.orchestrator(approvalTimeout: ApprovalTimeoutPolicy(timeout: nil))
        let item = try await env.addWorkItem("Abbruch")
        env.codex.enqueue(Scripts.approval("c1"))
        let job = try await env.request(orchestrator, item)
        await orchestrator.tick(now: t0)
        try await eventually { try await env.job(job.jobId).state == .waitingApproval }
        let approval = try #require(await orchestrator.pendingApprovals(for: job.jobId).first)
        _ = try await orchestrator.cancel(jobId: job.jobId, by: env.user)
        await orchestrator.waitUntilSessionEnds(job.jobId)
        #expect(try await env.database.approvals.fetch(approval.id)?.state == .withdrawn)
        await #expect(throws: StoreError.approvalClosed(approval.id, .withdrawn)) {
            try await env.database.approvals.recordDecision(ApprovalDecision(for: approval, decision: .allow, decidedBy: DeviceID(),
                                                                             at: t0.addingTimeInterval(5)))
        }
    }

    @Test("M1: review content is stored in the synced review; conflicts too")
    func reviewContentIsSynced() async throws {
        let env = try await TestEnvironment()
        let orchestrator = try env.orchestrator()
        let item = try await env.addWorkItem("Inhalt")
        env.codex.enqueue(Scripts.writeAndCommit(commitWith: env.git))
        let job = try await env.request(orchestrator, item)
        await orchestrator.tick(now: t0)
        await orchestrator.waitUntilSessionEnds(job.jobId)
        let review = try #require(try await env.database.reviews.reviews(jobId: job.jobId).first)
        #expect(review.summary?.contains("Fertig") == true)
        #expect(review.commits.count == 1 && review.commits.first?.subject == "Agent: feature.txt")
        #expect(review.fileChanges.map(\.path) == ["feature.txt"])
        #expect(review.fileChanges.first?.additions == 1 && review.fileChanges.first?.deletions == 1)
        #expect(review.testSummary == TestRunSummary(passed: 1))
        #expect(review.headCommit == review.commits.last?.sha)
        // The synced payload carries the content; host paths are not part of it.
        let payload = try #require(try await env.database.sync.currentPayload(entityType: .review, entityId: review.reviewId.rawValue))
        let text = String(decoding: payload, as: UTF8.self)
        let details = try #require(await orchestrator.reviewDetails(review.reviewId))
        #expect(env.repo.path(percentEncoded: false).hasPrefix(details.repositoryPath) && details.commits == review.commits)
        #expect(text.contains("\"commits\"") && !text.contains(details.repositoryPath))

        try Data("Benutzeränderung\n".utf8).write(to: env.repo.appending(path: "feature.txt"))
        try await env.git.run(["commit", "--quiet", "-am", "User change"], in: env.repo)
        try await orchestrator.approveReview(review.reviewId, by: env.user)
        await #expect(throws: JobOrchestratorError.integrationConflict(files: ["feature.txt"])) {
            _ = try await orchestrator.integrate(reviewId: review.reviewId, approvedBy: env.user)
        }
        let conflicted = try #require(try await env.database.reviews.fetch(review.reviewId))
        #expect(conflicted.conflict?.files == ["feature.txt"])
        #expect(conflicted.conflict?.message.contains("Integrationskonflikt") == true)
    }

    @Test("K2/J2: 'retry when quota available' waits for the expected reset and shows the shared status text")
    func userRequestedQuotaSchedule() async throws {
        let env = try await TestEnvironment()
        let orchestrator = try env.orchestrator()
        let item = try await env.addWorkItem("Später")
        let reset = t0.addingTimeInterval(3 * 3600)
        let job = try await env.request(orchestrator, item, schedule: JobSchedule(kind: .whenQuotaAvailable(expectedReset: reset, requestedAt: t0)))
        #expect(await orchestrator.tick(now: t0).started.isEmpty)
        let status = try await orchestrator.scheduleStatus(jobId: job.jobId, now: t0)
        #expect(status.text == "Start bei verfügbarem Kontingent, frühestens 22:00 (erwarteter Reset laut Benutzer)")
        #expect(status.nextQuotaAttempt?.isUserRequested == true)
        #expect(await orchestrator.tick(now: reset).started == [job.jobId])
        await orchestrator.waitUntilSessionEnds(job.jobId)
        #expect(try await env.job(job.jobId).state == .finished)
    }

    @Test("Quota and missed runs use dedicated event kinds")
    func dedicatedEventKinds() async throws {
        let env = try await TestEnvironment()
        let orchestrator = try env.orchestrator()
        let item = try await env.addWorkItem("Kontingent")
        env.codex.enqueue(Scripts.quota(resetsAt: t0.addingTimeInterval(1800)))
        let job = try await env.request(orchestrator, item)
        await orchestrator.tick(now: t0)
        await orchestrator.waitUntilSessionEnds(job.jobId)
        #expect(try await env.job(job.jobId).state == .waitingQuota)

        let missedItem = try await env.addWorkItem("Verpasst")
        let local = try ZonedLocalDateTime(year: 2026, month: 10, day: 30, hour: 18, minute: 0, timeZoneIdentifier: "Europe/Vienna")
        _ = try await env.request(orchestrator, missedItem, schedule: JobSchedule(kind: .at(local), missedRunPolicy: .ask))
        await orchestrator.tick(now: t0.addingTimeInterval(60))

        let quotaEvents = try await env.database.events.events(forWorkItem: item.uuid)
        #expect(quotaEvents.contains { $0.kind == .quotaWait && $0.payload["basis"] == "providerSignal" })
        let missedEvents = try await env.database.events.events(forWorkItem: missedItem.uuid)
        let missed = try #require(missedEvents.first { $0.kind == .missedRun })
        #expect(missed.payload["policy"] == "ask" && missed.payload["text"]?.contains("Termin verpasst") == true)
        #expect(!(quotaEvents + missedEvents).contains { $0.kind == .comment && ["quotaWait", "missedRun"].contains($0.payload["type"] ?? "") })
    }

    @Test("L1/A21: a known, empty process group means 'not running' without a cwd scan")
    func processGroupLivenessWinsOverCwdScan() async throws {
        let env = try await TestEnvironment()
        let crashed = try env.orchestrator()
        let item = try await env.addWorkItem("Gruppe")
        env.codex.enqueue(Scripts.hang(writing: "partial.txt"))
        let job = try await env.request(crashed, item)
        await crashed.tick(now: t0)
        try await eventually { await crashed.runtimeRecord(for: job.jobId)?.processGroupIdentifier != nil }
        let record = try #require(await crashed.runtimeRecord(for: job.jobId))
        let pid = try #require(record.processIdentifier)
        #expect(record.processGroupIdentifier == pid)
        env.inspector.setAlive(pid, false)
        // An unrelated process (e.g. an editor) has its cwd in the worktree; the group is known to be empty.
        env.inspector.setBusy(try #require(record.worktreePath), true)
        env.inspector.setGroup(pid, .notRunning)

        let restarted = try env.orchestrator()
        let report = await restarted.recover(at: t0.addingTimeInterval(120))
        #expect(report.actions[job.jobId] == .failed(preservedWorktree: true))
        #expect(try await env.database.locks.activeLock(forTask: item.uuid) == nil)
    }

    @Test("Without process-group information the cwd scan remains the fallback")
    func cwdScanFallback() async throws {
        let env = try await TestEnvironment()
        let crashed = try env.orchestrator()
        let item = try await env.addWorkItem("Fallback")
        env.codex.enqueue(Scripts.hang(writing: "partial.txt"))
        let job = try await env.request(crashed, item)
        await crashed.tick(now: t0)
        try await eventually { await crashed.runtimeRecord(for: job.jobId)?.worktreePath != nil }
        let record = try #require(await crashed.runtimeRecord(for: job.jobId))
        env.inspector.setAlive(try #require(record.processIdentifier), false)
        env.inspector.setBusy(try #require(record.worktreePath), true)
        let restarted = try env.orchestrator()
        let report = await restarted.recover(at: t0.addingTimeInterval(120))
        #expect(report.actions[job.jobId] == .orphanPaused(pid: record.processIdentifier))
    }
}
