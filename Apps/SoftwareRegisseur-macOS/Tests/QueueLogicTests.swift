import Foundation
import Testing
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC

@Suite("Warteschlange: Filter, Reihenfolge, Steueraktionen")
struct QueueLogicTests {
    let item = Fixture.item("Aufgabe")

    @Test func everyJobStateHasExactlyOneCategory() {
        for state in AgentJobState.allCases {
            let categories = QueueFilter.allCases.filter { $0 != .all && $0.states.contains(state) }
            #expect(categories.count == 1, "\(state)")
        }
        #expect(QueueFilter.category(of: .waitingApproval) == .active)
        #expect(QueueFilter.category(of: .waitingQuota) == .waiting)
        #expect(QueueFilter.category(of: .needsConfiguration) == .problems)
    }

    @Test func filterByStateAndProviderAndOrderByPriorityThenStart() {
        let low = Fixture.job(for: item, state: .scheduled, priority: .low, created: 0)
        let urgent = Fixture.job(for: Fixture.item("B"), state: .scheduled, priority: .urgent, created: 10)
        let soon = Fixture.job(for: Fixture.item("C"), state: .scheduled, priority: .low,
                               schedule: JobSchedule(kind: .notBefore(Fixture.now.addingTimeInterval(60))), created: 20)
        let claude = Fixture.job(for: Fixture.item("D"), state: .running, provider: .claudeCode)
        let jobs = [low, urgent, soon, claude]
        #expect(QueueFilter.waiting.apply(to: jobs).map(\.jobId) == [urgent.jobId, soon.jobId, low.jobId])
        #expect(QueueFilter.active.apply(to: jobs, provider: .claudeCode).map(\.jobId) == [claude.jobId])
        #expect(QueueFilter.active.apply(to: jobs, provider: .codex).isEmpty)
        #expect(QueueFilter.all.apply(to: jobs).count == 4)
    }

    @Test func runningJobCanBePausedAndCancelledButNotReconfigured() {
        let actions = JobAction.available(for: Fixture.job(for: item, state: .running), status: nil)
        #expect(actions.contains(.pause))
        #expect(actions.contains(.cancel))
        #expect(!actions.contains(.resume))
        #expect(!actions.contains(.retry))
        #expect(!actions.contains(.replaceConfiguration))
    }

    @Test func pausedUnstartedJobCanResumeAndReplaceConfiguration() {
        let actions = JobAction.available(for: Fixture.job(for: item, state: .paused), status: nil)
        #expect(actions.contains(.resume))
        #expect(actions.contains(.replaceConfiguration))
        #expect(!actions.contains(.pause))
    }

    @Test func terminalJobsOfferRetryAndWorktreeRemovalOnlyWithWorktree() {
        var failed = Fixture.job(for: item, state: .failed)
        #expect(JobAction.available(for: failed, status: nil) == [.retry])
        failed.worktreePath = "/tmp/worktree"
        #expect(JobAction.available(for: failed, status: nil).contains(.removeWorktree))
    }

    @Test func needsConfigurationOffersExplicitReplacement() {
        let actions = JobAction.available(for: Fixture.job(for: item, state: .needsConfiguration), status: nil)
        #expect(actions.contains(.replaceConfiguration))
    }

    @Test func hostDetailsUnlockMissedRunAndOrphanActions() {
        let job = Fixture.job(for: item, state: .scheduled)
        let status = JobStatusInfo(
            job: JobInfo(jobId: job.jobId, workItemId: item.uuid, providerId: .codex, state: .scheduled, priority: .medium, lastError: nil),
            scheduleText: "", plannedStart: nil, admissionBlock: nil, awaitingMissedRunDecision: true, nextQuotaAttempt: nil,
            isLive: false, orphanedProcess: true, processIdentifier: 42, worktreePath: nil, branch: nil, repositoryPath: nil, openApprovals: [])
        let actions = JobAction.available(for: job, status: status)
        #expect(actions.prefix(2) == [.resolveMissedRunNow, .resolveMissedRunSkip])
        #expect(actions.contains(.terminateOrphanedProcess))
    }

    @Test func waitingQuotaOffersExpectedReset() {
        let actions = JobAction.available(for: Fixture.job(for: item, state: .waitingQuota), status: nil)
        #expect(actions.contains(.setExpectedQuotaReset))
    }

    @Test func actionsBuildTheMatchingServiceRequests() {
        let id = JobID()
        let key = IdempotencyKey()
        #expect(JobAction.pause.request(for: id) == .pauseJob(jobId: id))
        #expect(JobAction.resume.request(for: id) == .resumeJob(jobId: id))
        #expect(JobAction.cancel.request(for: id) == .cancelJob(jobId: id))
        #expect(JobAction.retry.request(for: id, idempotencyKey: key) == .retryJob(jobId: id, idempotencyKey: key))
        #expect(JobAction.resolveMissedRunNow.request(for: id) == .resolveMissedRun(jobId: id, runNow: true))
        #expect(JobAction.resolveMissedRunSkip.request(for: id) == .resolveMissedRun(jobId: id, runNow: false))
        #expect(JobAction.removeWorktree.request(for: id) == .removeWorktree(jobId: id))
        #expect(JobAction.terminateOrphanedProcess.request(for: id) == .terminateOrphanedProcess(jobId: id))
        // Aktionen mit eigener Eingabe bauen keinen Befehl ohne diese Eingabe.
        #expect(JobAction.replaceConfiguration.request(for: id) == nil)
        #expect(JobAction.setExpectedQuotaReset.request(for: id) == nil)
        #expect(JobAction.cancel.isDestructive)
    }

    @Test func configurationTextShowsUnconfirmedEffectiveValuesOnce() {
        let text = JobConfigurationText(job: Fixture.job(for: item, state: .running))
        #expect(text.effective == AgentJob.unconfirmedText)
        #expect(text.resolved.contains(ModelSelection.providerDefault.germanDisplayName))
    }

    @Test func savedOnlyJobIsDescribedAsWaitingForManualRelease() {
        let job = Fixture.job(for: item, state: .scheduled, schedule: JobSchedule(kind: .manualPause))
        #expect(JobScheduleText.text(for: job, hostLastSeen: nil, now: Fixture.now) == "gespeichert – wartet auf manuelle Freigabe")
    }
}
