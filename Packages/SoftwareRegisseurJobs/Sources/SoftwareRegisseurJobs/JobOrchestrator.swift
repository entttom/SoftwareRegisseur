import Foundation
import SoftwareRegisseurAgents
import SoftwareRegisseurDomain
import SoftwareRegisseurGit
import SoftwareRegisseurPersistence
import SoftwareRegisseurProcess

enum StopIntent: Sendable {
    case cancel(EventActor)
    case pause(EventActor)
    case quota
    case approvalTimeout
}

/// In-memory state of one agent session owned by this host.
struct LiveRun: Sendable {
    let jobId: JobID
    let projectId: ProjectID
    let providerId: ProviderID
    let workItemId: WorkItemID
    let session: any AgentSession
    let lockId: LockID
    var consumer: Task<Void, Never>?
    /// Open approval requests of this session, keyed by the agent's request ID.
    var approvals: [ApprovalRequestID: LiveApproval] = [:]
    var lastMessage: String?
    var currentText = ""
    var tests: [String: TestResult] = [:]
    var testOrder: [String] = []
    var quotaSignal: QuotaSignal?
    var stopIntent: StopIntent?
    var finished = false
    var lastHeartbeat: Date
}

/// Orchestrates agent jobs on the execution host (spec J3, K1–K3, L1–L3, M1, N2–N4; ADR-0007,
/// ADR-0012). The database is the source of truth; the service drives `tick(now:)` and calls
/// `recover(at:)` once on start. No UI timers (spec K3).
public actor JobOrchestrator {
    public nonisolated let configuration: JobOrchestratorConfiguration
    let deps: JobOrchestratorDependencies
    let runtime: JobRuntimeStore
    let worktrees: WorktreeManager
    var runs: [JobID: LiveRun] = [:]
    var blocks: [JobID: AdmissionBlock] = [:]
    var admitting: Set<JobID> = []
    var rng: SeededGenerator
    var isTicking = false
    var latestTime = Date.distantPast
    var hostLastSeenBeforeStart: Date?
    /// Previous completed tick; after sleep this is when the Mac was last online (spec K3).
    var lastTickAt: Date?

    public init(configuration: JobOrchestratorConfiguration, dependencies: JobOrchestratorDependencies) throws {
        for directory in [configuration.worktreesBaseDirectory, configuration.integrationWorktreeDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        self.configuration = configuration
        deps = dependencies
        runtime = try JobRuntimeStore(directory: configuration.runtimeDirectory)
        worktrees = try WorktreeManager(git: dependencies.git, worktreesBaseDirectory: configuration.worktreesBaseDirectory,
                                        scanRoots: configuration.scanRoots)
        rng = SeededGenerator(seed: dependencies.randomSeed ?? UInt64.random(in: .min ... .max))
    }

    var hostId: HostID { configuration.hostId }
    var hostActor: EventActor { .host(configuration.hostId) }

    // MARK: - Read API

    public func job(_ id: JobID) async throws -> AgentJob? { try await deps.jobs.fetch(id) }

    /// Open approvals of a job (synced Domain records, spec J6 V1 fallback), oldest first.
    public func pendingApprovals(for jobId: JobID) async -> [PendingApproval] {
        ((try? await deps.approvals.approvals(jobId: jobId)) ?? []).filter(\.isOpen)
    }

    public func runtimeRecord(for jobId: JobID) -> JobRuntimeRecord? { runtime.record(jobId) }

    /// Synced review content plus host-local paths (Mac UI).
    public func reviewDetails(_ id: ReviewID) async -> ReviewDetails? {
        guard let host = runtime.reviewHost(id), let review = try? await deps.reviews.fetch(id) else { return nil }
        return ReviewDetails(review: review, host: host)
    }

    public func admissionBlock(for jobId: JobID) -> AdmissionBlock? { blocks[jobId] }

    /// Jobs with a connected agent session on this host.
    public var liveJobIds: Set<JobID> { Set(runs.filter { !$0.value.finished }.keys) }

    /// Waits until the session of `jobId` delivered `.finished` and was processed.
    public func waitUntilSessionEnds(_ jobId: JobID) async {
        guard let consumer = runs[jobId]?.consumer else { return }
        await consumer.value
    }

    // MARK: - Job creation (spec J2a, J3)

    /// Resolves Job > Project > Global > provider default against the host's capability and creates
    /// the job with an immutable configuration snapshot. Idempotent per `idempotencyKey` (A15).
    public func requestJob(
        workItemId: WorkItemID,
        providerId: ProviderID,
        override: JobConfigurationOverride? = nil,
        schedule: JobSchedule = JobSchedule(kind: .immediate),
        priority: Priority = .medium,
        idempotencyKey: IdempotencyKey,
        by actor: EventActor
    ) async throws -> JobCreationResult {
        let now = currentTime()
        if let existing = try await deps.jobs.fetch(idempotencyKey: idempotencyKey) { return .existing(existing) }
        guard let item = try await deps.workItems.fetch(workItemId) else { throw JobOrchestratorError.workItemNotFound(workItemId) }
        guard let projectId = item.projectId else { throw JobOrchestratorError.workItemWithoutProject(workItemId) }
        guard let project = try await deps.projects.fetch(projectId) else { throw JobOrchestratorError.projectNotFound(projectId) }
        guard let capability = try await deps.capabilities.capability(hostId: project.hostId ?? hostId, providerId: providerId) else {
            throw JobOrchestratorError.capabilityUnknown(providerId)
        }
        let settings = try await deps.projects.settings(forProject: projectId)
        let projectPreference = try await deps.preferences.preference(scope: .project(projectId), providerId: providerId)
            ?? settings?.modelPreference(for: providerId)
        let globalPreference = try await deps.preferences.preference(scope: .global, providerId: providerId)
        let resolution = ModelEffortResolver.resolve(
            jobOverride: override, projectPreference: projectPreference, globalPreference: globalPreference, capability: capability)
        guard let resolved = resolution.configuration else { throw JobOrchestratorError.configurationInvalid(resolution.issues) }
        let job = AgentJob(
            idempotencyKey: idempotencyKey, projectId: projectId, workItemId: workItemId,
            hostId: project.hostId == hostId ? hostId : nil, configSnapshot: resolved.makeSnapshot(createdAt: now),
            schedule: schedule, priority: priority, workItemStatusBeforeJob: item.status, createdAt: now)
        return try await deps.jobs.create(job, actor: actor, at: now)
    }

    // MARK: - Tick (service loop)

    /// One pass of the service loop: take over requested jobs, heartbeats, approval timeouts, lock
    /// reconciliation, schedule evaluation and admission. Never throws; problems are in the report.
    @discardableResult
    public func tick(now requested: Date) async -> TickReport {
        let now = advance(to: requested)
        var report = TickReport(now: now)
        guard !isTicking else {
            report.skipped = true
            report.nextWakeDate = await nextWakeDate(after: now)
            return report
        }
        isTicking = true
        defer { isTicking = false }
        await takeOverRequestedJobs(now: now, report: &report)
        await renewHeartbeats(now: now, report: &report)
        await consumeApprovalDecisions(now: now, report: &report)
        await enforceApprovalTimeouts(now: now, report: &report)
        await reconcileIdleLocks(now: now, report: &report)
        await admitDueJobs(now: now, report: &report)
        report.nextWakeDate = await nextWakeDate(after: now)
        lastTickAt = now
        if configuration.recordsHostHeartbeat {
            try? await deps.capabilities.recordHeartbeat(hostId, ready: true, at: now)
        }
        return report
    }

    /// Next instant the service loop should call `tick(now:)`: the earliest planned start, quota
    /// retry, approval deadline, heartbeat or lease end; `maximumIdleInterval` only when none exists.
    public func nextWakeDate(after now: Date) async -> Date {
        var candidates: [Date] = []
        if runs.values.contains(where: { !$0.finished }) {
            candidates.append(now.addingTimeInterval(configuration.heartbeatInterval))
        }
        if let timeout = configuration.approvalTimeout.timeout {
            for run in runs.values {
                for approval in run.approvals.values where approval.timedOutAt == nil {
                    candidates.append(approval.receivedAt.addingTimeInterval(timeout))
                }
            }
        }
        if let queued = try? await deps.jobs.jobs(inStates: [.scheduled, .waitingQuota], hostId: hostId, limit: nil) {
            candidates += queued.compactMap(\.scheduledAt)
        }
        if let locks = try? await deps.locks.activeLocks(hostId: hostId) {
            candidates += locks.filter { runs[$0.jobId] == nil }.map(\.leaseUntil)
        }
        return candidates.filter { $0 > now }.min() ?? now.addingTimeInterval(configuration.maximumIdleInterval)
    }

    func takeOverRequestedJobs(now: Date, report: inout TickReport) async {
        let candidates: [AgentJob]
        do {
            candidates = try await deps.jobs.jobs(inStates: [.requested, .pendingMac], hostId: nil, limit: nil)
        } catch {
            report.errors.append("takeover: \(error)")
            return
        }
        for job in candidates {
            do {
                // N4/A33: only the project's execution host may take over; others leave the job untouched.
                guard let project = try await deps.projects.fetch(job.projectId), project.hostId == hostId,
                      job.hostId == nil || job.hostId == hostId
                else {
                    report.foreign.append(job.jobId)
                    continue
                }
                let host = hostId
                try await move(job.jobId, to: .scheduled, at: now) { $0.hostId = host }
                try updateRecord(job.jobId) { _ in }
                report.takenOver.append(job.jobId)
            } catch {
                report.errors.append("takeover \(job.jobId): \(error)")
            }
        }
    }

    func renewHeartbeats(now: Date, report: inout TickReport) async {
        for (id, run) in runs where !run.finished && now.timeIntervalSince(run.lastHeartbeat) >= configuration.heartbeatInterval / 2 {
            do {
                _ = try await deps.locks.heartbeat(run.lockId, leaseDuration: configuration.lockLeaseDuration, at: now)
                runs[id]?.lastHeartbeat = now
            } catch {
                report.errors.append("heartbeat \(id): \(error)")
            }
        }
    }

    func enforceApprovalTimeouts(now: Date, report: inout TickReport) async {
        guard let timeout = configuration.approvalTimeout.timeout else { return }
        for (id, run) in runs where !run.finished {
            let expired = run.approvals.filter {
                $0.value.timedOutAt == nil && now >= $0.value.receivedAt.addingTimeInterval(timeout)
            }
            guard !expired.isEmpty else { continue }
            let action = configuration.approvalTimeout.action
            for (requestId, live) in expired {
                runs[id]?.approvals[requestId]?.timedOutAt = now
                // Pause keeps the request answerable (only marked); fail closes it (spec L3: never auto-approve).
                await updateApproval(live.approvalId, at: now) { approval in
                    if action == .fail { approval.expire(at: now) } else { approval.markTimedOut(at: now) }
                }
            }
            report.approvalTimeouts.append(id)
            let minutes = Int((timeout / 60).rounded())
            await appendEvent(run.workItemId, kind: .approvalExpired, payload: [
                "jobId": id.uuidString,
                "approvalIds": expired.map(\.value.approvalId.uuidString).sorted().joined(separator: ","),
                "requestIds": expired.map(\.key.rawValue).sorted().joined(separator: ","),
                "reason": "timeout", "action": action.rawValue,
            ], at: now)
            switch action {
            case .pause:
                do {
                    if try await deps.jobs.fetch(id)?.state == .waitingApproval {
                        try await move(id, to: .paused, at: now) {
                            $0.lastError = String(localized: "Freigabe nicht innerhalb von \(minutes) Minuten beantwortet – Lauf pausiert, keine automatische Freigabe.", bundle: .module)
                        }
                    }
                } catch {
                    report.errors.append("approval timeout \(id): \(error)")
                }
            case .fail:
                runs[id]?.stopIntent = .approvalTimeout
                await run.session.cancel()
            }
        }
    }

    /// Relays explicit, synced user decisions (iPhone or Mac UI) to the agent session (spec J6 V1
    /// fallback, L3). Each approval is answered at most once; decisions for expired, answered or
    /// withdrawn approvals are ignored.
    func consumeApprovalDecisions(now: Date, report: inout TickReport) async {
        let open: [PendingApproval]
        do {
            open = try await deps.approvals.openApprovals(hostId: hostId)
        } catch {
            report.errors.append("approvals: \(error)")
            return
        }
        for approval in open {
            guard let run = runs[approval.jobId], !run.finished,
                  let (requestId, live) = run.approvals.first(where: { $0.value.approvalId == approval.id })
            else {
                // No connected session can transport an answer any more (session ended or service restarted).
                if runs[approval.jobId] == nil {
                    await closeApproval(approval, expired: false, reason: "sessionEnded", at: now)
                    report.approvalsClosed.append(approval.id)
                }
                continue
            }
            if approval.isExpired(at: now) {
                await closeApproval(approval, expired: true, reason: "expired", at: now)
                report.approvalsClosed.append(approval.id)
                continue
            }
            let decisions: [ApprovalDecision]
            do {
                decisions = try await deps.approvals.decisions(approvalId: approval.id)
            } catch {
                report.errors.append("approval decisions \(approval.id): \(error)")
                continue
            }
            guard let decision = ApprovalDecision.firstApplicable(decisions, for: approval, at: now) else { continue }
            do {
                try await relay(decision, approval: approval, requestId: requestId, live: live, jobId: approval.jobId,
                                agentDecision: Self.agentDecision(for: decision, available: live.availableDecisions), now: now)
                report.approvalsAnswered.append(approval.id)
            } catch {
                report.errors.append("approval relay \(approval.id): \(error)")
            }
        }
    }

    func reconcileIdleLocks(now: Date, report: inout TickReport) async {
        let locks: [TaskLock]
        do {
            locks = try await deps.locks.activeLocks(hostId: hostId)
        } catch {
            report.errors.append("locks: \(error)")
            return
        }
        for lock in locks where runs[lock.jobId] == nil && !admitting.contains(lock.jobId) {
            let job = try? await deps.jobs.fetch(lock.jobId)
            if case .released = await attemptLockRelease(lock, job: job, now: now) {
                report.releasedLocks.append(lock.lockId)
            }
        }
    }

    // MARK: - Scheduling and admission (spec K1, K3, J3)

    enum ScheduleDecision { case due, waiting, handled }

    func admitDueJobs(now: Date, report: inout TickReport) async {
        let candidates: [AgentJob]
        do {
            candidates = try await deps.jobs.jobs(inStates: [.scheduled, .waitingQuota], hostId: hostId, limit: nil)
        } catch {
            report.errors.append("queue: \(error)")
            return
        }
        var due: [AgentJob] = []
        for job in candidates where runs[job.jobId] == nil {
            if await scheduleDecision(job, now: now, report: &report) == .due { due.append(job) }
        }
        due.sort { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            let left = lhs.scheduledAt ?? lhs.createdAt, right = rhs.scheduledAt ?? rhs.createdAt
            return left != right ? left < right : lhs.createdAt < rhs.createdAt
        }
        for job in due { await admit(job, now: now, report: &report) }
    }

    func scheduleDecision(_ job: AgentJob, now: Date, report: inout TickReport) async -> ScheduleDecision {
        let evaluation: ScheduleEvaluation
        do {
            evaluation = try job.schedule.evaluate(at: now)
        } catch {
            report.errors.append("schedule \(job.jobId): \(error)")
            return .waiting
        }
        switch evaluation {
        case .runNow:
            if job.scheduledAt != nil, runtime.record(job.jobId)?.dueObservedAt == nil {
                _ = try? updateRecord(job.jobId) { $0.dueObservedAt = now }
            }
            return .due
        case .waitUntil:
            return .waiting
        case .paused:
            _ = try? await move(job.jobId, to: .paused, at: now)
            return .handled
        case let .missed(scheduledFor, action):
            let record = runtime.record(job.jobId)
            // Observed as due in time but held back by limits/locks → not a missed run.
            if let observed = record?.dueObservedAt, observed.timeIntervalSince(scheduledFor) <= job.schedule.missedRunTolerance {
                return .due
            }
            if let missed = record?.missedRun {
                switch missed.resolution {
                case .runNow: return .due
                case .skipped: return .handled
                case .awaitingUser:
                    blocks[job.jobId] = .awaitingMissedRunDecision(scheduledFor)
                    report.blocked[job.jobId] = .awaitingMissedRunDecision(scheduledFor)
                    return .handled
                }
            }
            return await registerMissedRun(job, scheduledFor: scheduledFor, action: action, now: now, report: &report)
        }
    }

    func registerMissedRun(
        _ job: AgentJob, scheduledFor: Date, action: MissedRunAction, now: Date, report: inout TickReport
    ) async -> ScheduleDecision {
        let lastSeen = await hostLastSeen()
        let zone = Self.timeZone(of: job.schedule)
        let text = ScheduleStatusText.missed(scheduledFor: scheduledFor, hostLastSeen: lastSeen,
                                             policy: job.schedule.missedRunPolicy, now: now, timeZone: zone)
        let resolution: MissedRunResolution = switch action {
        case .runNow: .runNow
        case .askUser: .awaitingUser
        case .skip: .skipped
        }
        _ = try? updateRecord(job.jobId) {
            $0.missedRun = MissedRunRecord(scheduledFor: scheduledFor, detectedAt: now, hostLastSeen: lastSeen,
                                           policy: job.schedule.missedRunPolicy, resolution: resolution, statusText: text)
        }
        report.missed[job.jobId] = action
        await appendEvent(job.workItemId, kind: .missedRun, payload: [
            "jobId": job.jobId.uuidString, "scheduledFor": Self.iso(scheduledFor),
            "policy": job.schedule.missedRunPolicy.rawValue, "text": text,
            "hostLastSeen": lastSeen.map(Self.iso) ?? "",
        ], at: now)
        switch action {
        case .runNow:
            return .due
        case .askUser:
            blocks[job.jobId] = .awaitingMissedRunDecision(scheduledFor)
            report.blocked[job.jobId] = .awaitingMissedRunDecision(scheduledFor)
            return .handled
        case .skip:
            _ = try? await move(job.jobId, to: .cancelled, at: now) {
                $0.lastError = String(localized: "\(text) – übersprungen.", bundle: .module)
            }
            return .handled
        }
    }

    func admit(_ job: AgentJob, now: Date, report: inout TickReport) async {
        admitting.insert(job.jobId)
        defer { admitting.remove(job.jobId) }
        func block(_ reason: AdmissionBlock) {
            blocks[job.jobId] = reason
            report.blocked[job.jobId] = reason
            _ = try? updateRecord(job.jobId) { $0.admissionNote = reason.germanDescription }
        }
        do {
            guard let project = try await deps.projects.fetch(job.projectId), project.hostId == hostId else {
                return block(.notExecutionHost)
            }
            let settings = try await deps.projects.settings(forProject: project.id)
            if let limit = try await concurrencyBlock(for: job, settings: settings) { return block(limit) }
            guard let item = try await deps.workItems.fetch(job.workItemId) else { return block(.workItemMissing) }
            var open: [WorkItemID] = []
            for dependency in item.dependencies {
                let status = try await deps.workItems.fetch(dependency)?.status
                if status != .done, status != .integrated { open.append(dependency) }
            }
            if !open.isEmpty { return block(.dependenciesOpen(open)) }
            if let held = try await deps.locks.activeLock(forTask: job.workItemId), held.jobId != job.jobId {
                return block(.taskLocked(held.lockId))
            }
            let projectWide = settings?.projectWideLock ?? false
            if let other = try await deps.locks.activeLocks(projectId: project.id)
                .first(where: { $0.jobId != job.jobId && (projectWide || $0.scope == .project) }) {
                return block(.projectLocked(other.lockId))
            }
            guard let repository = try await repositoryURL(for: project.id) else { return block(.repositoryUnavailable) }
            // L2: inspect the main working tree; user changes there are never touched.
            guard let mainStatus = try? await deps.git.status(of: repository) else { return block(.repositoryUnavailable) }
            if mainStatus.hasConflicts {
                return block(.mainWorkingTreeConflicted(mainStatus.entries.filter { $0.kind == .unmerged }.map(\.path)))
            }
            guard let defaultBranch = await defaultBranch(of: repository) else { return block(.defaultBranchUnknown) }
            guard let provider = deps.providers.provider(for: job.providerId) else {
                return block(.providerUnavailable(job.providerId))
            }

            // J3/ADR-0006: revalidate the stored snapshot against a fresh capability; never fall back.
            let previous = try await deps.capabilities.capability(hostId: hostId, providerId: job.providerId)
            let plan: AgentLaunchPlan
            switch await provider.prepareLaunch(snapshot: job.configSnapshot, previous: previous) {
            case let .ready(ready):
                plan = ready
                _ = try? await deps.capabilities.saveCapability(ready.capability, at: now)
            case let .needsConfiguration(issues, capability):
                _ = try? await deps.capabilities.saveCapability(capability, at: now)
                try await blockForConfiguration(job, issues: issues, now: now)
                report.needsConfiguration[job.jobId] = issues
                return
            case let .notRunnable(reason, capability):
                _ = try? await deps.capabilities.saveCapability(capability, at: now)
                return block(.agentNotRunnable(reason))
            }

            var current = try await updateJob(job.jobId, at: now) { _ = try $0.admit(against: plan.capability, at: now) }
            guard current.state == .admitted else {
                let issues = ModelEffortResolver.revalidate(job.configSnapshot, against: plan.capability)
                if case let .needsConfiguration(list) = issues { report.needsConfiguration[job.jobId] = list }
                return
            }

            let lock: TaskLock
            do {
                lock = try await acquireLock(for: current, projectWide: projectWide, now: now)
            } catch let StoreError.lockHeld(existing, scope) {
                _ = try? await move(job.jobId, to: .scheduled, at: now)
                return block(scope == .project || projectWide ? .projectLocked(existing) : .taskLocked(existing))
            }
            try updateRecord(job.jobId) {
                $0.lockId = lock.lockId
                $0.repositoryPath = Self.plainPath(repository)
                $0.defaultBranch = defaultBranch
            }

            let taskID = item.humanId?.formatted ?? item.uuid.shortString
            let worktree: (url: URL, branch: String, baseCommit: String?)
            do {
                worktree = try await prepareWorktree(for: current, repository: repository, taskID: taskID, defaultBranch: defaultBranch)
            } catch {
                await failStart(job.jobId, lockId: lock.lockId, reason: String(localized: "Worktree konnte nicht angelegt werden: \(String(describing: error))", bundle: .module), now: now, report: &report)
                return
            }
            let worktreePath = Self.plainPath(worktree.url)
            let branch = worktree.branch
            current = try await move(job.jobId, to: .starting, at: now) {
                $0.branch = branch
                $0.worktreePath = worktreePath
            }
            let isRerun = current.retryCount > 0 || runtime.record(job.jobId)?.sessionUUID != nil
            let sessionUUID = isRerun ? UUID() : job.jobId.rawValue
            try updateRecord(job.jobId) {
                $0.worktreePath = worktreePath
                $0.branch = branch
                if let base = worktree.baseCommit { $0.baseCommit = base }
                $0.sessionUUID = sessionUUID
                $0.admissionNote = nil
            }

            let body = item.structuredBody.isEmpty ? item.originalNote : item.structuredBody
            let requestFile = await deps.requestFilePath?(item)
            let managedDocuments = await documentPaths(for: job.projectId,
                                                       settings: try? await deps.projects.settings(forProject: job.projectId))
            let prompt = deps.promptBuilder.build(
                workItem: AgentWorkItemContext(humanId: item.humanId?.formatted, title: item.title, body: body,
                                               requestFilePath: requestFile, managedDocumentPaths: managedDocuments),
                workingDirectory: worktree.url, branch: branch)
            let session: any AgentSession
            do {
                session = try await provider.startSession(
                    plan: plan,
                    request: AgentSessionRequest(jobId: job.jobId, workingDirectory: worktree.url, prompt: prompt, sessionUUID: sessionUUID))
            } catch {
                await failStart(job.jobId, lockId: lock.lockId, reason: String(localized: "Agent konnte nicht gestartet werden: \(String(describing: error))", bundle: .module), now: now, report: &report)
                return
            }
            let pid = await session.processIdentifier
            let processGroup = await session.processGroupIdentifier
            let inspector = deps.processInspector
            _ = try? updateRecord(job.jobId) {
                $0.processIdentifier = pid
                $0.processGroupIdentifier = processGroup
                $0.processStartedAt = pid.flatMap { inspector.startTime(of: $0) }
                $0.orphanedProcess = false
            }
            runs[job.jobId] = LiveRun(jobId: job.jobId, projectId: job.projectId, providerId: job.providerId,
                                      workItemId: job.workItemId, session: session, lockId: lock.lockId, lastHeartbeat: now)
            do {
                _ = try await move(job.jobId, to: .running, at: now)
            } catch {
                runs[job.jobId]?.stopIntent = .cancel(hostActor)
                await session.cancel()
                report.errors.append("start \(job.jobId): \(error)")
            }
            startConsumer(for: job.jobId, session: session)
            blocks[job.jobId] = nil
            report.started.append(job.jobId)
        } catch {
            report.errors.append("admission \(job.jobId): \(error)")
            // Never leave a half-admitted job behind: back to the queue before a worktree exists,
            // failed (with verified lock release) once it was starting.
            guard runs[job.jobId] == nil, let state = try? await deps.jobs.fetch(job.jobId)?.state else { return }
            if state == .admitted {
                _ = try? await move(job.jobId, to: .scheduled, at: now)
                block(.startFailed(String(describing: error)))
            } else if state == .starting {
                var lockId = runtime.record(job.jobId)?.lockId
                if lockId == nil { lockId = (try? await deps.locks.activeLock(forTask: job.workItemId))?.lockId }
                if let lockId {
                    await failStart(job.jobId, lockId: lockId, reason: String(localized: "Start fehlgeschlagen: \(String(describing: error))", bundle: .module), now: now, report: &report)
                } else {
                    _ = try? await move(job.jobId, to: .failed, at: now) { $0.lastError = String(localized: "Start fehlgeschlagen: \(String(describing: error))", bundle: .module) }
                }
            }
        }
    }

    func blockForConfiguration(_ job: AgentJob, issues: [ConfigurationIssue], now: Date) async throws {
        let text = issues.map(\.germanDescription).joined(separator: " ")
        try await move(job.jobId, to: .needsConfiguration, at: now) { $0.lastError = text }
        await appendEvent(job.workItemId, payload: [
            "type": "configurationRejected", "jobId": job.jobId.uuidString, "issues": text,
        ], at: now)
    }

    func concurrencyBlock(for job: AgentJob, settings: ProjectSettings?) async throws -> AdmissionBlock? {
        let active = try await deps.jobs.jobs(inStates: [.admitted, .starting, .running, .waitingApproval], hostId: hostId, limit: nil)
            .filter { $0.jobId != job.jobId }
        var entries = active.map { (project: $0.projectId, provider: $0.providerId) }
        let activeIds = Set(active.map(\.jobId))
        for run in runs.values where !run.finished && run.jobId != job.jobId && !activeIds.contains(run.jobId) {
            entries.append((run.projectId, run.providerId))
        }
        let limits = configuration.limits
        if entries.count >= limits.global { return .globalLimit(limits.global) }
        let projectLimit = settings.map { $0.allowParallel ? ($0.maxParallelJobs ?? limits.perProject) : 1 } ?? limits.perProject
        if entries.filter({ $0.project == job.projectId }).count >= projectLimit { return .projectLimit(projectLimit) }
        if let providerLimit = limits.providerLimit(job.providerId),
           entries.filter({ $0.provider == job.providerId }).count >= providerLimit {
            return .providerLimit(job.providerId, providerLimit)
        }
        return nil
    }

    /// Acquires the task lock, or reuses this job's own unreleased lock (re-admission after quota/recovery).
    func acquireLock(for job: AgentJob, projectWide: Bool, now: Date) async throws -> TaskLock {
        if let own = try await deps.locks.activeLock(forTask: job.workItemId), own.jobId == job.jobId, own.hostId == hostId {
            return try await deps.locks.heartbeat(own.lockId, leaseDuration: configuration.lockLeaseDuration, at: now)
        }
        return try await deps.locks.acquire(LockRequest(
            taskId: job.workItemId, projectId: job.projectId, jobId: job.jobId, hostId: hostId,
            owner: configuration.lockOwner, scope: projectWide ? .project : .task, leaseDuration: configuration.lockLeaseDuration
        ), at: now)
    }

    /// New worktree + branch `software-regisseur/<task-id>/<job-short-id>` (spec L2), or the job's
    /// existing one when it is re-admitted (quota retry, resume).
    ///
    /// SR-SEC-02 / ADR-0026: worktree path and branch come only from the host-local runtime record
    /// (computed by `WorktreeManager` under the service's worktree base), never from the synced
    /// `AgentJob.worktreePath`/`branch`, and a reused worktree is verified to be a linked worktree below
    /// the base – never the main working tree.
    func prepareWorktree(
        for job: AgentJob, repository: URL, taskID: String, defaultBranch: String
    ) async throws -> (url: URL, branch: String, baseCommit: String?) {
        if let record = runtime.record(job.jobId), let path = record.worktreePath, let branch = record.branch,
           FileManager.default.fileExists(atPath: path) {
            let entry = try await worktrees.verifyManagedWorktree(URL(filePath: path, directoryHint: .isDirectory),
                                                                  repository: repository, expectedBranch: branch)
            return (entry.url, branch, record.baseCommit)
        }
        let created = try await worktrees.createWorktree(repository: repository, taskID: taskID,
                                                         jobShortID: job.jobId.shortString, baseRef: defaultBranch)
        return (created.url, created.branchName, created.baseCommit)
    }

    func failStart(_ jobId: JobID, lockId: LockID, reason: String, now: Date, report: inout TickReport) async {
        let job = try? await move(jobId, to: .failed, at: now) { $0.lastError = reason }
        report.failed[jobId] = reason
        if let lock = try? await deps.locks.fetch(lockId), !lock.isReleased {
            _ = await attemptLockRelease(lock, job: job, now: now)
        }
    }

    func startConsumer(for jobId: JobID, session: any AgentSession) {
        let events = session.events
        let task = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event, jobId: jobId)
            }
            await self?.streamEnded(jobId)
        }
        runs[jobId]?.consumer = task
    }

    // MARK: - Locks (spec L1)

    enum LockReleaseOutcome { case released, kept(LockReleaseDecision), failed }

    /// Releases only on a Domain `LockReleaseDecision.release` computed from fresh process/worktree facts.
    func attemptLockRelease(_ lock: TaskLock, job: AgentJob?, now: Date) async -> LockReleaseOutcome {
        let record = runtime.record(lock.jobId)
        let process = observeProcess(record: record, job: job)
        let worktree = await observeWorktree(record?.worktreePath)
        let observedAt = max(now, lock.lastHeartbeat)
        let reconciliation = LockReconciliation(hostId: hostId, observedAt: observedAt, process: process,
                                                worktree: worktree, jobState: job?.state)
        do {
            _ = try await deps.locks.release(lock.lockId, reconciliation: reconciliation, at: observedAt)
            if record != nil {
                _ = try? updateRecord(lock.jobId) {
                    $0.lockId = nil
                    $0.orphanedProcess = false
                }
            }
            return .released
        } catch let StoreError.lockReleaseRefused(decision) {
            switch decision {
            case .reconciliationRequired, .requiresUserDecision:
                if lock.recoveryState == .active, lock.isExpired(at: now) {
                    _ = try? await deps.locks.markAwaitingReconciliation(lock.lockId, at: now)
                }
            default: break
            }
            return .kept(decision)
        } catch {
            return .failed
        }
    }

    /// Liveness from PID and process group reported by the session; the working-directory scan is only
    /// the fallback when neither is known or the group state cannot be determined (spec L1, A21).
    func observeProcess(record: JobRuntimeRecord?, job: AgentJob?) -> ProcessObservation {
        let inspector = deps.processInspector
        if let pid = record?.processIdentifier {
            let observation = inspector.observe(pid: pid, startedAt: record?.processStartedAt)
            if observation != .notRunning { return observation }
        }
        if let group = record?.processGroupIdentifier {
            switch inspector.observeProcessGroup(group) {
            case .running: return .running
            case .notRunning: return .notRunning
            case .unknown: break
            }
        }
        // Host-local path only (SR-SEC-02); the synced job path is a display hint.
        if let path = record?.worktreePath, FileManager.default.fileExists(atPath: path) {
            return inspector.observeProcesses(inside: URL(filePath: path, directoryHint: .isDirectory))
        }
        return .notRunning
    }

    func observeWorktree(_ path: String?) async -> WorktreeObservation {
        guard let path else { return .missing }
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        guard let status = try? await deps.git.status(of: URL(filePath: path, directoryHint: .isDirectory)) else { return .unknown }
        return status.isClean ? .clean : .hasChanges
    }

    // MARK: - Helpers

    func currentTime() -> Date {
        latestTime = max(deps.clock.now(), latestTime)
        return latestTime
    }

    func advance(to date: Date) -> Date {
        latestTime = max(latestTime, date)
        return latestTime
    }

    func hostLastSeen() async -> Date? {
        if let lastTickAt { return lastTickAt }
        if let hostLastSeenBeforeStart { return hostLastSeenBeforeStart }
        return try? await deps.capabilities.host(hostId)?.lastSeen
    }

    /// Repository folder of a project on this Mac (SR-SEC-01, ADR-0026). Only this host's own location
    /// is used, and only if its canonical path (all symlinks resolved) is unchanged and lies inside a
    /// confirmed root folder, outside the service's worktree and integration directories. Anything else
    /// is treated as unavailable – a synced path is never trusted on its own.
    func repositoryURL(for projectId: ProjectID) async throws -> URL? {
        guard let location = try await deps.projects.locations(projectId: projectId).first(where: { $0.hostId == hostId }) else {
            return nil
        }
        let stored = URL(filePath: location.canonicalPath, directoryHint: .isDirectory)
        guard let canonical = try? PathGuard.canonicalize(stored), Self.plainPath(canonical) == Self.plainPath(stored),
              FileManager.default.fileExists(atPath: Self.plainPath(canonical)) else { return nil }
        let path = Self.plainPath(canonical)
        func isInside(_ root: URL) -> Bool {
            guard let rootPath = (try? PathGuard.canonicalize(root)).map(Self.plainPath) else { return false }
            return path == rootPath || path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/")
        }
        for serviceDirectory in [configuration.worktreesBaseDirectory, configuration.integrationWorktreeDirectory] where isInside(serviceDirectory) {
            return nil
        }
        if let live = deps.allowedRepositoryRoots {
            // Live source of confirmed roots: strict, no root → no repository.
            guard await live().contains(where: isInside) else { return nil }
        } else if !configuration.scanRoots.isEmpty {
            guard configuration.scanRoots.contains(where: isInside) else { return nil }
        }
        // Without a live source and without roots at service start only the checks above apply
        // (transitional; the service passes `allowedRepositoryRoots`, ADR-0026).
        return canonical
    }

    func defaultBranch(of repository: URL) async -> String? {
        guard let info = try? await RepositoryInspector(git: deps.git).inspect(repository),
              info.defaultBranchSource != .unbornHead else { return nil }
        return info.defaultBranch
    }

    @discardableResult
    func updateRecord(_ id: JobID, _ mutate: (inout JobRuntimeRecord) -> Void) throws -> JobRuntimeRecord {
        let now = currentTime()
        var record = runtime.record(id) ?? JobRuntimeRecord(jobId: id, hostId: hostId, at: now)
        mutate(&record)
        record.updatedAt = now
        try runtime.save(record)
        return record
    }

    /// Read-modify-write of a host-owned approval record; failures are not fatal for the run.
    func updateApproval(_ id: PendingApprovalID, at date: Date, _ mutate: (inout PendingApproval) -> Void) async {
        guard var approval = try? await deps.approvals.fetch(id) else { return }
        let before = approval
        mutate(&approval)
        guard approval != before else { return }
        try? await deps.approvals.save(approval, at: date)
    }

    /// Optimistic job update with a bounded retry on revision conflicts.
    @discardableResult
    func updateJob(
        _ id: JobID, actor: EventActor? = nil, at date: Date, _ mutate: @Sendable (inout AgentJob) throws -> Void
    ) async throws -> AgentJob {
        var attempts = 0
        while true {
            guard let job = try await deps.jobs.fetch(id) else { throw JobOrchestratorError.jobNotFound(id) }
            do {
                return try await deps.jobs.update(id, expectedRevision: job.revision, actor: actor ?? hostActor, at: date, mutate).job
            } catch let error as StoreError {
                if case .revisionConflict = error, attempts < 3 {
                    attempts += 1
                    continue
                }
                throw error
            }
        }
    }

    /// Moves a job to `target`, through `running`/`scheduled` when the Domain table requires an
    /// intermediate step (e.g. `waiting_approval → running → finished`).
    @discardableResult
    func move(
        _ id: JobID, to target: AgentJobState, actor: EventActor? = nil, at date: Date,
        _ mutate: @Sendable (inout AgentJob) throws -> Void = { _ in }
    ) async throws -> AgentJob {
        guard let current = try await deps.jobs.fetch(id) else { throw JobOrchestratorError.jobNotFound(id) }
        if current.state == target { return try await updateJob(id, actor: actor, at: date, mutate) }
        guard let steps = Self.path(from: current.state, to: target) else {
            throw JobOrchestratorError.invalidState(id, current.state)
        }
        var job = current
        for (index, step) in steps.enumerated() {
            let isLast = index == steps.count - 1
            job = try await updateJob(id, actor: actor, at: date) { job in
                if isLast { try mutate(&job) }
                if job.state != step { try job.transition(to: step, at: date) }
            }
        }
        return job
    }

    static func path(from: AgentJobState, to: AgentJobState) -> [AgentJobState]? {
        if from.canTransition(to: to) { return [to] }
        for via in [AgentJobState.running, .scheduled] where from.canTransition(to: via) && via.canTransition(to: to) {
            return [via, to]
        }
        return nil
    }

    func appendEvent(
        _ workItemId: WorkItemID, kind: TaskEventKind = .comment, actor: EventActor? = nil,
        payload: [String: String], at date: Date
    ) async {
        let revision = (try? await deps.workItems.fetch(workItemId))?.revision ?? 0
        try? await deps.events.append(TaskEvent(workItemId: workItemId, kind: kind, actor: actor ?? hostActor,
                                                timestamp: date, payload: payload, sourceRevision: revision))
    }

    static func timeZone(of schedule: JobSchedule) -> TimeZone {
        ScheduleStatusText.timeZone(of: schedule) ?? .current
    }

    static func iso(_ date: Date) -> String { date.formatted(.iso8601) }

    /// File-system path without percent encoding and without a trailing slash.
    static func plainPath(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
