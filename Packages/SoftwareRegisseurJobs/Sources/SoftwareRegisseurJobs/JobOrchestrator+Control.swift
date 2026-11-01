import Foundation
import SoftwareRegisseurAgents
import SoftwareRegisseurDomain
import SoftwareRegisseurGit
import SoftwareRegisseurPersistence

/// User controls (spec K1: Abbruch, Pause, Repriorisierung, Wiederholung; L3: Freigaben).
extension JobOrchestrator {
    /// Forwards an explicit user decision made on this Mac to the agent. Nothing else ever answers
    /// approvals (spec L3). The decision is recorded as a synced Domain `ApprovalDecision` (spec M2).
    public func answerApproval(
        jobId: JobID, requestId: ApprovalRequestID, decision: AgentApprovalDecision, by actor: EventActor
    ) async throws {
        guard case let .user(device) = actor else { throw JobOrchestratorError.userDecisionRequired }
        guard let run = runs[jobId], !run.finished else { throw JobOrchestratorError.noLiveSession(jobId) }
        guard let live = run.approvals[requestId] else { throw JobOrchestratorError.unknownApproval(requestId) }
        if !live.availableDecisions.isEmpty, !live.availableDecisions.contains(decision) {
            throw JobOrchestratorError.decisionNotAvailable(decision)
        }
        let now = currentTime()
        guard let approval = try await deps.approvals.fetch(live.approvalId), approval.isOpen else {
            throw JobOrchestratorError.unknownApproval(requestId)
        }
        let kind: ApprovalDecisionKind = switch decision {
        case .allow, .allowForSession: .allow
        case .deny, .cancel: .deny
        }
        let message: String? = if case let .deny(text) = decision { text } else { nil }
        let record = ApprovalDecision(for: approval, decision: kind, decidedBy: device, at: now, message: message)
        try await relay(record, approval: approval, requestId: requestId, live: live, jobId: jobId, agentDecision: decision, now: now)
    }

    /// Full redacted text of an approval whose synced preview was truncated (SR-SEC-08), for the Mac UI.
    /// nil when the preview is complete or no live session holds the request any more.
    public func fullApprovalPreview(_ approvalId: PendingApprovalID) -> String? {
        for run in runs.values where !run.finished {
            if let live = run.approvals.values.first(where: { $0.approvalId == approvalId }) { return live.fullPreview }
        }
        return nil
    }

    /// Decision made in the Mac UI for a synced approval (SR-SEC-08). For a truncated preview, `allow`
    /// requires `fullTextConfirmed == true`: the UI showed `fullApprovalPreview` and the user confirmed
    /// having read it. Otherwise only the decisions offered to every device are possible. The decision is
    /// recorded as a synced `ApprovalDecision` and relayed immediately; never automatic (spec L3).
    public func answerApprovalOnHost(
        _ approvalId: PendingApprovalID, decision kind: ApprovalDecisionKind, message: String? = nil,
        fullTextConfirmed: Bool, by actor: EventActor
    ) async throws {
        guard case let .user(device) = actor else { throw JobOrchestratorError.userDecisionRequired }
        let now = currentTime()
        guard let approval = try await deps.approvals.fetch(approvalId), approval.isOpen, !approval.isExpired(at: now) else {
            throw JobOrchestratorError.unknownApproval(ApprovalRequestID(approvalId.uuidString))
        }
        let requestId = ApprovalRequestID(approval.requestId)
        guard let run = runs[approval.jobId], !run.finished, let live = run.approvals[requestId] else {
            throw JobOrchestratorError.noLiveSession(approval.jobId)
        }
        let hostReviewed = kind == .allow && !approval.remoteDecisions.contains(.allow)
        if hostReviewed {
            guard approval.allowRequiresHostReview == true, approval.hostReviewedDecisions.contains(.allow) else {
                throw JobOrchestratorError.decisionNotAvailable(.allow)
            }
            // The user must have seen the whole text on this Mac (SR-SEC-08).
            guard fullTextConfirmed, live.fullPreview != nil else { throw JobOrchestratorError.userDecisionRequired }
        } else if !approval.remoteDecisions.contains(kind) {
            throw JobOrchestratorError.decisionNotAvailable(kind == .allow ? .allow : .deny(message: message))
        }
        let record = ApprovalDecision(for: approval, decision: kind, decidedBy: device, at: now, message: kind == .deny ? message : nil)
        if hostReviewed {
            try await deps.approvals.recordHostReviewedDecision(record)
        }
        try await relay(record, approval: approval, requestId: requestId, live: live, jobId: approval.jobId,
                        agentDecision: Self.agentDecision(for: record, available: live.availableDecisions), now: now)
    }

    /// Records the decision, sends it to the session, marks the approval answered and resumes the run
    /// when no other request is open. Idempotent per approval: a second relay finds it closed.
    func relay(
        _ decision: ApprovalDecision, approval: PendingApproval, requestId: ApprovalRequestID, live: LiveApproval,
        jobId: JobID, agentDecision: AgentApprovalDecision, now: Date
    ) async throws {
        guard let run = runs[jobId], !run.finished, run.approvals[requestId] != nil else {
            throw JobOrchestratorError.noLiveSession(jobId)
        }
        let actor = decision.actor
        do {
            try await deps.approvals.recordDecision(decision)
        } catch StoreError.approvalClosed {
            throw JobOrchestratorError.unknownApproval(requestId)
        }
        if case .cancel = agentDecision { runs[jobId]?.stopIntent = .cancel(actor) }
        try await run.session.respond(to: requestId, with: agentDecision)
        runs[jobId]?.approvals[requestId] = nil
        await updateApproval(live.approvalId, at: now) { $0.recordAnswer(decision, at: now) }
        await appendEvent(run.workItemId, kind: .approvalAnswered, actor: actor, payload: [
            "jobId": jobId.uuidString, "approvalId": approval.id.uuidString, "requestId": requestId.rawValue,
            "decision": Self.describe(agentDecision), "decisionId": decision.id.uuidString,
            "device": decision.decidedBy.uuidString,
        ], at: now)
        if case .cancel = agentDecision { return }
        if runs[jobId]?.approvals.isEmpty == true, runs[jobId]?.finished == false,
           let state = try await deps.jobs.fetch(jobId)?.state, state == .waitingApproval || state == .paused,
           runs[jobId]?.finished == false {
            _ = try? await move(jobId, to: .running, actor: actor, at: now) { $0.lastError = nil }
        }
    }

    /// Closes an approval that can no longer be answered (expired, or no session to relay to).
    func closeApproval(_ approval: PendingApproval, expired: Bool, reason: String, at now: Date) async {
        await updateApproval(approval.id, at: now) { expired ? $0.expire(at: now) : $0.withdraw(at: now) }
        await appendEvent(approval.workItemId, kind: .approvalExpired, payload: [
            "jobId": approval.jobId.uuidString, "approvalIds": approval.id.uuidString, "requestIds": approval.requestId,
            "reason": reason,
        ], at: now)
    }

    /// Agent-side form of a synced decision (allow → `allow`, deny → `deny` or `cancel` if only that exists).
    /// `allow` is never widened to `allowForSession` (SR-SEC-16); such approvals do not offer `allow`.
    static func agentDecision(for decision: ApprovalDecision, available: [AgentApprovalDecision]) -> AgentApprovalDecision {
        switch decision.decision {
        case .allow:
            return .allow
        case .deny:
            let deny = AgentApprovalDecision.deny(message: decision.message)
            if available.isEmpty || available.contains(where: { if case .deny = $0 { true } else { false } }) { return deny }
            return available.contains(.cancel) ? .cancel : deny
        }
    }

    /// Cancels a job. A live session is interrupted; the job becomes `cancelled` once the session
    /// ended, and the lock is released after the verified process end.
    @discardableResult
    public func cancel(jobId: JobID, by actor: EventActor) async throws -> AgentJob {
        let now = currentTime()
        if let run = runs[jobId], !run.finished {
            runs[jobId]?.stopIntent = .cancel(actor)
            await run.session.cancel()
            guard let job = try await deps.jobs.fetch(jobId) else { throw JobOrchestratorError.jobNotFound(jobId) }
            return job
        }
        guard let job = try await deps.jobs.fetch(jobId) else { throw JobOrchestratorError.jobNotFound(jobId) }
        guard !job.state.isTerminal else { throw JobOrchestratorError.invalidState(jobId, job.state) }
        let cancelled = try await move(jobId, to: .cancelled, actor: actor, at: now)
        if let lock = try await deps.locks.activeLock(forTask: job.workItemId), lock.jobId == jobId {
            _ = await attemptLockRelease(lock, job: cancelled, now: now)
        }
        return cancelled
    }

    /// Pauses a job. A running agent is stopped (resume starts a new session in the same worktree);
    /// a job waiting for approval keeps its session and stays answerable.
    @discardableResult
    public func pause(jobId: JobID, by actor: EventActor) async throws -> AgentJob {
        let now = currentTime()
        guard let job = try await deps.jobs.fetch(jobId) else { throw JobOrchestratorError.jobNotFound(jobId) }
        if let run = runs[jobId], !run.finished {
            switch job.state {
            case .running:
                runs[jobId]?.stopIntent = .pause(actor)
                await run.session.cancel()
                return try await deps.jobs.fetch(jobId) ?? job
            case .waitingApproval:
                return try await move(jobId, to: .paused, actor: actor, at: now) {
                    $0.lastError = String(localized: "Vom Benutzer pausiert.", bundle: .module)
                }
            default:
                throw JobOrchestratorError.invalidState(jobId, job.state)
            }
        }
        guard job.state.canTransition(to: .paused) else { throw JobOrchestratorError.invalidState(jobId, job.state) }
        return try await move(jobId, to: .paused, actor: actor, at: now) {
            $0.lastError = String(localized: "Vom Benutzer pausiert.", bundle: .module)
        }
    }

    /// Resumes a paused job: with a live session back to `running`, otherwise back into the queue.
    @discardableResult
    public func resume(jobId: JobID, by actor: EventActor) async throws -> AgentJob {
        let now = currentTime()
        guard let job = try await deps.jobs.fetch(jobId) else { throw JobOrchestratorError.jobNotFound(jobId) }
        guard job.state == .paused else { throw JobOrchestratorError.invalidState(jobId, job.state) }
        if let run = runs[jobId], !run.finished {
            guard run.approvals.isEmpty else { throw JobOrchestratorError.approvalPending(jobId) }
            return try await move(jobId, to: .running, actor: actor, at: now) { $0.lastError = nil }
        }
        let record = runtime.record(jobId)
        if record?.orphanedProcess == true, observeProcess(record: record, job: job) != .notRunning {
            throw JobOrchestratorError.orphanProcessRunning(jobId)
        }
        let resumed = try await move(jobId, to: .scheduled, actor: actor, at: now) {
            if case .manualPause = $0.schedule.kind { $0.schedule.kind = .immediate }
            $0.lastError = nil
        }
        _ = try? updateRecord(jobId) { $0.orphanedProcess = false }
        return resumed
    }

    @discardableResult
    public func reprioritize(jobId: JobID, to priority: Priority, by actor: EventActor) async throws -> AgentJob {
        guard let job = try await deps.jobs.fetch(jobId) else { throw JobOrchestratorError.jobNotFound(jobId) }
        guard !job.state.isTerminal else { throw JobOrchestratorError.invalidState(jobId, job.state) }
        return try await updateJob(jobId, actor: actor, at: currentTime()) { $0.priority = priority }
    }

    /// Manual retry of a terminal job: a new job with the identical configuration snapshot (A39),
    /// linked to the old one via `AgentJob.retryOfJobId` and a `jobRetried` event. Idempotent per key.
    public func retry(jobId: JobID, idempotencyKey: IdempotencyKey, by actor: EventActor) async throws -> JobCreationResult {
        let now = currentTime()
        guard let old = try await deps.jobs.fetch(jobId) else { throw JobOrchestratorError.jobNotFound(jobId) }
        guard old.state == .failed || old.state == .cancelled || old.state == .finished else {
            throw JobOrchestratorError.invalidState(jobId, old.state)
        }
        guard let item = try await deps.workItems.fetch(old.workItemId) else { throw JobOrchestratorError.workItemNotFound(old.workItemId) }
        let project = try await deps.projects.fetch(old.projectId)
        let schedule = JobSchedule(kind: .immediate, missedRunPolicy: old.schedule.missedRunPolicy,
                                   missedRunTolerance: old.schedule.missedRunTolerance,
                                   repeatedTimePolicy: old.schedule.repeatedTimePolicy)
        let job = AgentJob(
            idempotencyKey: idempotencyKey, projectId: old.projectId, workItemId: old.workItemId,
            hostId: project?.hostId == hostId ? hostId : nil, configSnapshot: old.configSnapshot, schedule: schedule,
            priority: old.priority, workItemStatusBeforeJob: item.status, retryOfJobId: jobId, createdAt: now)
        let result = try await deps.jobs.create(job, actor: actor, at: now)
        if case let .created(created, _) = result {
            await appendEvent(old.workItemId, kind: .jobRetried, actor: actor, payload: [
                "jobId": created.jobId.uuidString, "retryOf": jobId.uuidString,
            ], at: now)
        }
        return result
    }

    /// Explicit new model/effort selection for a job that has not started (spec J2a, A40). A job in
    /// `needs_configuration` returns to the queue.
    @discardableResult
    public func replaceConfiguration(jobId: JobID, with snapshot: ConfigurationSnapshot, by actor: EventActor) async throws -> AgentJob {
        guard actor.isUser else { throw JobOrchestratorError.userDecisionRequired }
        let now = currentTime()
        return try await updateJob(jobId, actor: actor, at: now) { job in
            try job.replaceConfiguration(with: snapshot, at: now)
            if job.state == .needsConfiguration {
                try job.transition(to: .scheduled, at: now)
                job.lastError = nil
            }
        }
    }

    /// User decision for a missed run under policy `ask` (spec K3).
    @discardableResult
    public func resolveMissedRun(jobId: JobID, runNow: Bool, by actor: EventActor) async throws -> AgentJob {
        guard actor.isUser else { throw JobOrchestratorError.userDecisionRequired }
        let now = currentTime()
        guard let job = try await deps.jobs.fetch(jobId) else { throw JobOrchestratorError.jobNotFound(jobId) }
        guard runtime.record(jobId)?.missedRun?.resolution == .awaitingUser else { throw JobOrchestratorError.noMissedRunPending(jobId) }
        try updateRecord(jobId) { $0.missedRun?.resolution = runNow ? .runNow : .skipped }
        blocks[jobId] = nil
        await appendEvent(job.workItemId, actor: actor, payload: [
            "type": "missedRunResolved", "jobId": jobId.uuidString, "decision": runNow ? "runNow" : "skip",
        ], at: now)
        if runNow { return job }
        return try await move(jobId, to: .cancelled, actor: actor, at: now) {
            $0.lastError = String(localized: "Verpasster Termin vom Benutzer übersprungen.", bundle: .module)
        }
    }

    /// User-set expected quota reset (spec K2). Replans a waiting job; never earlier than now.
    @discardableResult
    public func setExpectedQuotaReset(jobId: JobID, at reset: Date, by actor: EventActor) async throws -> AgentJob {
        guard actor.isUser else { throw JobOrchestratorError.userDecisionRequired }
        let now = currentTime()
        guard let job = try await deps.jobs.fetch(jobId) else { throw JobOrchestratorError.jobNotFound(jobId) }
        guard job.state == .waitingQuota, case let .retryAfterQuota(state) = job.schedule.kind else {
            throw JobOrchestratorError.invalidState(jobId, job.state)
        }
        let replanned = QuotaRetryState(attempt: state.attempt, nextAttemptAt: max(reset, now), lastFailureAt: state.lastFailureAt,
                                        basis: .userExpectedReset, providerRetryAfter: state.providerRetryAfter, userExpectedReset: reset)
        return try await updateJob(jobId, actor: actor, at: now) { $0.schedule.kind = .retryAfterQuota(replanned) }
    }

    /// Explicit user request to stop an agent process that survived a service restart.
    public func terminateOrphanedProcess(jobId: JobID, by actor: EventActor) async throws -> Bool {
        guard actor.isUser else { throw JobOrchestratorError.userDecisionRequired }
        guard let record = runtime.record(jobId), record.orphanedProcess, let pid = record.processIdentifier else {
            throw JobOrchestratorError.noLiveSession(jobId)
        }
        guard deps.processInspector.observe(pid: pid, startedAt: record.processStartedAt) == .running else { return false }
        return deps.processInspector.terminateProcessGroup(pid)
    }

    static func describe(_ decision: AgentApprovalDecision) -> String {
        switch decision {
        case .allow: "allow"
        case .allowForSession: "allowForSession"
        case .deny: "deny"
        case .cancel: "cancel"
        }
    }
}
