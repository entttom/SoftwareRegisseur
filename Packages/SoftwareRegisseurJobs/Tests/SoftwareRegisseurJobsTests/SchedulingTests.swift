import Foundation
import SoftwareRegisseurAgents
import SoftwareRegisseurDomain
import SoftwareRegisseurJobs
import SoftwareRegisseurPersistence
import Testing

@Suite("Scheduling, missed runs, quota, approvals")
struct SchedulingTests {
    @Test("A17: planned for tomorrow 07:00 Europe/Vienna → fires exactly once, survives restart")
    func scheduledTomorrowMorning() async throws {
        let env = try await TestEnvironment()
        let first = try env.orchestrator()
        let item = try await env.addWorkItem("Morgens")
        let local = try ZonedLocalDateTime(year: 2026, month: 10, day: 31, hour: 7, minute: 0, timeZoneIdentifier: "Europe/Vienna")
        let job = try await env.request(first, item, schedule: JobSchedule(kind: .at(local)))
        let expected = iso("2026-10-31T06:00:00Z") // CET after the DST change on 2026-10-25
        #expect(job.scheduledAt == expected)

        let evening = await first.tick(now: t0)
        #expect(evening.takenOver == [job.jobId] && evening.started.isEmpty)
        #expect(evening.nextWakeDate == expected)
        #expect(try await env.item(item.uuid).status == .scheduled)
        let status = try await first.scheduleStatus(jobId: job.jobId, now: t0)
        #expect(status.text.hasPrefix("für 31.10. 07:00 geplant"))

        // Service restart before the due time: the queue is persistent.
        let second = try env.orchestrator()
        _ = await second.recover(at: iso("2026-10-31T05:00:00Z"))
        #expect(await second.tick(now: iso("2026-10-31T05:59:59Z")).started.isEmpty)
        let due = await second.tick(now: iso("2026-10-31T06:00:10Z"))
        #expect(due.started == [job.jobId])
        await second.waitUntilSessionEnds(job.jobId)
        await second.tick(now: iso("2026-10-31T06:01:00Z"))
        await second.tick(now: iso("2026-10-31T07:00:00Z"))
        #expect(env.codex.startCount == 1)
        #expect(try await env.job(job.jobId).state == .finished)
    }

    @Test("A18: host offline at due time → no false 'running', missed-run policies applied")
    func missedRunAfterHostDowntime() async throws {
        let env = try await TestEnvironment()
        let online = iso("2026-10-30T19:00:00Z")
        env.clock.set(online)
        let orchestrator = try env.orchestrator()
        let local = try ZonedLocalDateTime(year: 2026, month: 10, day: 30, hour: 22, minute: 0, timeZoneIdentifier: "Europe/Vienna")
        var jobs: [MissedRunPolicy: AgentJob] = [:]
        for policy in MissedRunPolicy.allCases {
            let item = try await env.addWorkItem("Nachts \(policy.rawValue)")
            jobs[policy] = try await env.request(orchestrator, item, schedule: JobSchedule(kind: .at(local), missedRunPolicy: policy))
        }
        await orchestrator.tick(now: online)
        // Last heartbeat 21:30 Vienna, then the Mac sleeps through 22:00.
        try await env.database.capabilities.recordHeartbeat(env.hostId, ready: true, at: iso("2026-10-30T20:30:00Z"))

        let wake = iso("2026-10-30T22:10:00Z")
        env.clock.set(wake)
        let restarted = try env.orchestrator()
        let recovery = await restarted.recover(at: wake)
        #expect(recovery.hostLastSeenBeforeStart == iso("2026-10-30T20:30:00Z"))
        let report = await restarted.tick(now: wake)

        let ask = try #require(jobs[.ask]), skip = try #require(jobs[.skipExpired]), run = try #require(jobs[.runImmediatelyWhenAvailable])
        #expect(report.started == [run.jobId])
        #expect(report.missed[ask.jobId] == .askUser)
        #expect(report.missed[skip.jobId] == .skip)
        #expect(try await env.job(skip.jobId).state == .cancelled)
        #expect(try await env.item(skip.workItemId).status == .open)
        let waiting = try await env.job(ask.jobId)
        #expect(waiting.state == .scheduled)
        #expect(try await env.item(ask.workItemId).status == .scheduled)
        let status = try await restarted.scheduleStatus(jobId: ask.jobId, now: wake)
        #expect(status.text.hasPrefix("für 22:00 geplant, Mac zuletzt online 21:30"))
        #expect(status.missedRun?.resolution == .awaitingUser)

        // Ticks without a decision never start it.
        #expect(await restarted.tick(now: wake.addingTimeInterval(60)).started.isEmpty)
        await #expect(throws: JobOrchestratorError.userDecisionRequired) {
            try await restarted.resolveMissedRun(jobId: ask.jobId, runNow: true, by: .host(env.hostId))
        }
        try await restarted.resolveMissedRun(jobId: ask.jobId, runNow: true, by: env.user)
        let after = await restarted.tick(now: wake.addingTimeInterval(120))
        #expect(after.started == [ask.jobId])
        await restarted.waitUntilSessionEnds(ask.jobId)
        await restarted.waitUntilSessionEnds(run.jobId)
        #expect(env.codex.startCount == 2)
    }

    @Test("K3: Mac asleep without restart → status names the last tick before sleep, host heartbeat recorded")
    func missedRunAfterSleep() async throws {
        let env = try await TestEnvironment()
        env.clock.set(iso("2026-10-30T19:00:00Z"))
        let orchestrator = try env.orchestrator()
        let item = try await env.addWorkItem("Schlaf")
        let local = try ZonedLocalDateTime(year: 2026, month: 10, day: 30, hour: 22, minute: 0, timeZoneIdentifier: "Europe/Vienna")
        let job = try await env.request(orchestrator, item, schedule: JobSchedule(kind: .at(local), missedRunPolicy: .ask))
        await orchestrator.tick(now: iso("2026-10-30T19:00:00Z"))
        await orchestrator.tick(now: iso("2026-10-30T20:30:00Z"))
        let wake = iso("2026-10-30T22:10:00Z")
        let report = await orchestrator.tick(now: wake)
        #expect(report.missed[job.jobId] == .askUser && report.started.isEmpty)
        let status = try await orchestrator.scheduleStatus(jobId: job.jobId, now: wake)
        #expect(status.text.hasPrefix("für 22:00 geplant, Mac zuletzt online 21:30"))
        #expect(try await env.database.capabilities.host(env.hostId)?.lastSeen == wake)
        try await orchestrator.resolveMissedRun(jobId: job.jobId, runNow: false, by: env.user)
        #expect(try await env.job(job.jobId).state == .cancelled)
        #expect(env.codex.startCount == 0)
    }

    @Test("A19: quota → waiting_quota at provider reset, lock freed after process end, one retry, no spam")
    func quotaWaitAndRetry() async throws {
        let env = try await TestEnvironment()
        let orchestrator = try env.orchestrator(lease: 300)
        let item = try await env.addWorkItem("Kontingent")
        let reset = t0.addingTimeInterval(2 * 3600)
        env.codex.enqueue(Scripts.quota(resetsAt: reset))
        let job = try await env.request(orchestrator, item)
        await orchestrator.tick(now: t0)
        await orchestrator.waitUntilSessionEnds(job.jobId)

        let waiting = try await env.job(job.jobId)
        #expect(waiting.state == .waitingQuota)
        #expect(waiting.retryCount == 1)
        guard case let .retryAfterQuota(state) = waiting.schedule.kind else {
            Issue.record("expected quota schedule")
            return
        }
        #expect(state.nextAttemptAt == reset && state.basis == .providerSignal)
        #expect(try await env.item(item.uuid).status == .scheduled)
        let status = try await orchestrator.scheduleStatus(jobId: job.jobId, now: t0)
        #expect(status.text.contains("wartet auf Kontingent") && status.text.contains("vom Anbieter gemeldet"))

        // Lease still valid → reservation kept; after expiry and verified process end → released.
        #expect(try await env.database.locks.activeLock(forTask: item.uuid) != nil)
        let afterLease = await orchestrator.tick(now: t0.addingTimeInterval(301))
        #expect(afterLease.releasedLocks.count == 1)
        #expect(try await env.database.locks.activeLock(forTask: item.uuid) == nil)

        for minutes in [10, 30, 60, 90, 119] {
            #expect(await orchestrator.tick(now: t0.addingTimeInterval(TimeInterval(minutes * 60))).started.isEmpty)
        }
        #expect(await orchestrator.nextWakeDate(after: t0.addingTimeInterval(3600)) == reset)
        #expect(env.codex.startCount == 1)

        let retry = await orchestrator.tick(now: reset.addingTimeInterval(1))
        #expect(retry.started == [job.jobId])
        await orchestrator.waitUntilSessionEnds(job.jobId)
        for seconds in [10.0, 600, 7200] { await orchestrator.tick(now: reset.addingTimeInterval(seconds)) }
        #expect(env.codex.startCount == 2)
        #expect(env.codex.requests[1].jobId == job.jobId)
        #expect(env.codex.requests[1].sessionUUID != env.codex.requests[0].sessionUUID)
        let finished = try await env.job(job.jobId)
        #expect(finished.state == .finished)
        #expect(finished.configSnapshot == job.configSnapshot)
        #expect(try await env.database.jobs.jobs(forWorkItem: item.uuid).count == 1)
        #expect(try await env.item(item.uuid).status == .review)
    }

    @Test("A19: bounded backoff without provider reset; give up after max attempts; manual retry → one new linked job")
    func quotaGivesUpAndManualRetry() async throws {
        let env = try await TestEnvironment()
        let policy = try BackoffPolicy(baseDelay: 900, multiplier: 2, maxDelay: 3600, maxAttempts: 1, jitter: .none)
        let orchestrator = try env.orchestrator(planner: QuotaRetryPlanner(policy: policy))
        let item = try await env.addWorkItem("Limit")
        env.codex.enqueue(Scripts.quota(resetsAt: nil))
        env.codex.enqueue(Scripts.quota(resetsAt: nil))
        let job = try await env.request(orchestrator, item)
        await orchestrator.tick(now: t0)
        await orchestrator.waitUntilSessionEnds(job.jobId)
        let waiting = try await env.job(job.jobId)
        guard case let .retryAfterQuota(state) = waiting.schedule.kind else {
            Issue.record("expected quota schedule")
            return
        }
        #expect(state.basis == .backoff && state.nextAttemptAt == t0.addingTimeInterval(900))
        #expect(await orchestrator.tick(now: t0.addingTimeInterval(899)).started.isEmpty)
        #expect(await orchestrator.tick(now: t0.addingTimeInterval(900)).started == [job.jobId])
        await orchestrator.waitUntilSessionEnds(job.jobId)
        let failed = try await env.job(job.jobId)
        #expect(failed.state == .failed)
        #expect(failed.lastError?.contains("keine weiteren automatischen Versuche") == true)
        for hours in [1.0, 5, 24] { await orchestrator.tick(now: t0.addingTimeInterval(hours * 3600)) }
        #expect(env.codex.startCount == 2)

        let key = IdempotencyKey()
        let retried = try await orchestrator.retry(jobId: job.jobId, idempotencyKey: key, by: env.user)
        let again = try await orchestrator.retry(jobId: job.jobId, idempotencyKey: key, by: env.user)
        #expect(retried.wasCreated && !again.wasCreated && again.job.jobId == retried.job.jobId)
        #expect(retried.job.configSnapshot == job.configSnapshot)
        #expect(retried.job.retryOfJobId == job.jobId)
        #expect(try await env.job(retried.job.jobId).retryOfJobId == job.jobId)
        #expect(try await env.database.events.events(forWorkItem: item.uuid).contains {
            $0.kind == .jobRetried && $0.payload["retryOf"] == job.jobId.uuidString
        })
        #expect(try await env.database.jobs.jobs(forWorkItem: item.uuid).count == 2)
        let next = await orchestrator.tick(now: t0.addingTimeInterval(25 * 3600))
        #expect(next.started == [retried.job.jobId])
        await orchestrator.waitUntilSessionEnds(retried.job.jobId)
        #expect(try await env.job(retried.job.jobId).state == .finished)
    }

    @Test("A20: approval pauses the job, timeout → paused without auto-approval, explicit user answer continues")
    func approvalTimeoutPauses() async throws {
        let env = try await TestEnvironment()
        let orchestrator = try env.orchestrator(approvalTimeout: ApprovalTimeoutPolicy(timeout: 600, action: .pause))
        let item = try await env.addWorkItem("Freigabe")
        env.codex.enqueue(Scripts.approval("a1"))
        let job = try await env.request(orchestrator, item)
        await orchestrator.tick(now: t0)
        try await eventually { try await env.job(job.jobId).state == .waitingApproval }
        #expect(try await env.item(item.uuid).status == .waitingApproval)
        #expect(await orchestrator.pendingApprovals(for: job.jobId).map(\.requestId) == ["a1"])
        #expect(try await env.database.approvals.openApprovals(hostId: env.hostId).count == 1)
        #expect(await orchestrator.nextWakeDate(after: t0) == t0.addingTimeInterval(60))

        await #expect(throws: JobOrchestratorError.userDecisionRequired) {
            try await orchestrator.answerApproval(jobId: job.jobId, requestId: ApprovalRequestID("a1"), decision: .allow, by: .host(env.hostId))
        }
        #expect(await orchestrator.tick(now: t0.addingTimeInterval(599)).approvalTimeouts.isEmpty)
        let timeout = await orchestrator.tick(now: t0.addingTimeInterval(601))
        #expect(timeout.approvalTimeouts == [job.jobId])
        let paused = try await env.job(job.jobId)
        #expect(paused.state == .paused)
        #expect(try await env.item(item.uuid).status == .paused)
        let session = try #require(env.codex.sessions.first)
        #expect(session.control.decisions.isEmpty)
        // Still answerable; lock kept while the agent process waits.
        #expect(try await env.database.locks.activeLock(forTask: item.uuid) != nil)
        await orchestrator.tick(now: t0.addingTimeInterval(3600))
        #expect(session.control.decisions.isEmpty)

        try await orchestrator.answerApproval(jobId: job.jobId, requestId: ApprovalRequestID("a1"), decision: .allow, by: env.user)
        await orchestrator.waitUntilSessionEnds(job.jobId)
        #expect(session.control.decisions == ["a1": .allow])
        #expect(try await env.job(job.jobId).state == .finished)
        #expect(try await env.item(item.uuid).status == .review)
        let events = try await env.database.events.events(forWorkItem: item.uuid)
        #expect(events.contains { $0.kind == .approvalRequested })
        #expect(events.contains { $0.kind == .approvalExpired && $0.payload["reason"] == "timeout" })
        #expect(events.contains { $0.kind == .approvalAnswered && $0.payload["decision"] == "allow" })
        #expect(await orchestrator.pendingApprovals(for: job.jobId).isEmpty)
    }

    @Test("A20: approval timeout with fail policy stops the run, never approves")
    func approvalTimeoutFails() async throws {
        let env = try await TestEnvironment()
        let orchestrator = try env.orchestrator(approvalTimeout: ApprovalTimeoutPolicy(timeout: 300, action: .fail))
        let item = try await env.addWorkItem("Freigabe Fehler")
        env.codex.enqueue(Scripts.approval("x"))
        let job = try await env.request(orchestrator, item)
        await orchestrator.tick(now: t0)
        try await eventually { try await env.job(job.jobId).state == .waitingApproval }
        await orchestrator.tick(now: t0.addingTimeInterval(301))
        await orchestrator.waitUntilSessionEnds(job.jobId)
        let failed = try await env.job(job.jobId)
        #expect(failed.state == .failed)
        #expect(failed.lastError?.contains("keine automatische Freigabe") == true)
        #expect(try #require(env.codex.sessions.first).control.decisions.isEmpty)
        #expect(try await env.database.locks.activeLock(forTask: item.uuid) == nil)
        #expect(try await env.item(item.uuid).status == .failed)
    }

    @Test("Status texts (K3)")
    func statusTexts() throws {
        let vienna = try #require(TimeZone(identifier: "Europe/Vienna"))
        let now = iso("2026-10-30T21:10:00Z")
        #expect(ScheduleStatusText.planned(iso("2026-10-30T21:00:00Z"), hostLastSeen: iso("2026-10-30T20:30:00Z"), now: now, timeZone: vienna)
            == "für 22:00 geplant, Mac zuletzt online 21:30")
        #expect(ScheduleStatusText.planned(iso("2026-10-31T06:00:00Z"), hostLastSeen: nil, now: now, timeZone: vienna)
            == "für 31.10. 07:00 geplant")
    }
}
