import Foundation
import SoftwareRegisseurAgents
import SoftwareRegisseurDomain
import SoftwareRegisseurGit
import SoftwareRegisseurPersistence

/// Review decisions, integration and completion (spec M1, ADR-0007, ADR-0015). Every step needs an
/// explicit user actor; nothing is pushed.
extension JobOrchestrator {
    @discardableResult
    public func approveReview(_ reviewId: ReviewID, by actor: EventActor) async throws -> Review {
        try await decideReview(reviewId, decision: .approved, reviewState: .approved, by: actor)
    }

    @discardableResult
    public func requestChanges(_ reviewId: ReviewID, by actor: EventActor) async throws -> Review {
        try await decideReview(reviewId, decision: .changesRequested, reviewState: .changesRequested, by: actor)
    }

    @discardableResult
    public func rejectReview(_ reviewId: ReviewID, by actor: EventActor) async throws -> Review {
        try await decideReview(reviewId, decision: .rejected, reviewState: .rejected, by: actor)
    }

    func decideReview(_ reviewId: ReviewID, decision: ReviewDecision, reviewState: ReviewState, by actor: EventActor) async throws -> Review {
        guard actor.isUser else { throw JobOrchestratorError.userDecisionRequired }
        let now = currentTime()
        guard var review = try await deps.reviews.fetch(reviewId) else { throw JobOrchestratorError.reviewNotFound(reviewId) }
        if let commit = review.integrationCommit { throw JobOrchestratorError.alreadyIntegrated(commit) }
        guard let job = try await deps.jobs.fetch(review.jobId) else { throw JobOrchestratorError.jobNotFound(review.jobId) }
        review.decide(decision, at: now)
        try await deps.reviews.save(review, at: now)
        if let item = try await deps.workItems.fetch(job.workItemId), item.reviewState != reviewState {
            _ = try await deps.workItems.update(item.uuid, expectedRevision: item.revision, actor: actor, at: now) {
                $0.reviewState = reviewState
            }
        }
        await appendEvent(job.workItemId, kind: .reviewDecided, actor: actor, payload: [
            "reviewId": reviewId.uuidString, "jobId": job.jobId.uuidString, "decision": decision.rawValue,
        ], at: now)
        return review
    }

    /// Integrates an approved review with the project's strategy (default squash). On conflicts the
    /// repository is unchanged and the conflict files are stored in the review details.
    public func integrate(reviewId: ReviewID, approvedBy actor: EventActor) async throws -> IntegrationResult {
        guard actor.isUser else { throw JobOrchestratorError.userDecisionRequired }
        let now = currentTime()
        guard var review = try await deps.reviews.fetch(reviewId) else { throw JobOrchestratorError.reviewNotFound(reviewId) }
        if let commit = review.integrationCommit { throw JobOrchestratorError.alreadyIntegrated(commit) }
        guard review.decision == .approved else { throw JobOrchestratorError.reviewNotApproved(review.decision) }
        guard let job = try await deps.jobs.fetch(review.jobId) else { throw JobOrchestratorError.jobNotFound(review.jobId) }
        guard job.state == .finished else { throw JobOrchestratorError.invalidState(job.jobId, job.state) }
        guard let item = try await deps.workItems.fetch(job.workItemId) else { throw JobOrchestratorError.workItemNotFound(job.workItemId) }
        guard item.status == .review else { throw JobOrchestratorError.workItemNotInReview(item.status) }
        guard let project = try await deps.projects.fetch(job.projectId) else { throw JobOrchestratorError.projectNotFound(job.projectId) }
        guard project.hostId == hostId else { throw JobOrchestratorError.notExecutionHost(project.id) }
        guard var host = runtime.reviewHost(reviewId) else { throw JobOrchestratorError.reviewDataUnavailable(job.jobId) }
        // SR-SEC-06 / ADR-0026: integrate exactly the reviewed state – the host-local branch and head
        // commit captured with the review, never the synced `job.branch`. A review whose synced head
        // commit differs from the host record is refused.
        let branch = host.branch
        if let syncedHead = review.headCommit, syncedHead != host.headCommit {
            throw JobOrchestratorError.integrationRefused(String(localized: "Der geprüfte Stand (\(String(syncedHead.prefix(10)))) passt nicht zum Stand dieses Macs (\(String(host.headCommit.prefix(10)))); nichts wurde übernommen.", bundle: .module))
        }
        let settings = try await deps.projects.settings(forProject: project.id)
        let strategy = settings?.integrationStrategy ?? .default
        let repository = URL(filePath: host.repositoryPath, directoryHint: .isDirectory)
        let title = item.humanId.map { "\($0.formatted): \(item.title)" } ?? item.title
        // ADR-0024: uncommitted request/ADR files in the main tree do not block, but are never overwritten.
        let documentPaths = await documentPaths(for: project.id, settings: settings)
        let request = IntegrationRequest(
            repository: repository, defaultBranch: host.defaultBranch, jobBranch: branch,
            strategy: SoftwareRegisseurGit.IntegrationStrategy(strategy),
            commitMessage: "\(title)\n\nSoftware-Regisseur-Job: \(job.jobId.uuidString)\nBranch: \(branch)",
            temporaryWorktreeParent: configuration.integrationWorktreeDirectory,
            ignoredUncommittedPaths: documentPaths,
            expectedJobTip: host.headCommit)

        let result: IntegrationResult
        do {
            result = try await IntegrationService(git: deps.git).integrate(request)
        } catch let error as IntegrationError {
            if case let .conflicts(files) = error {
                // Synced so the iPhone shows the conflict (spec M1 step 5); the repository is unchanged.
                review.conflict = ReviewConflictInfo(
                    files: files,
                    message: String(localized: "Integrationskonflikt in \(files.count) Datei(en); nichts wurde übernommen.", bundle: .module),
                    detectedAt: now)
                try? await deps.reviews.save(review, at: now)
                host.integrationProblem = nil
                try? runtime.save(host)
                await appendEvent(job.workItemId, kind: .conflictDetected, actor: actor, payload: [
                    "reviewId": reviewId.uuidString, "jobId": job.jobId.uuidString, "files": files.joined(separator: "\n"),
                ], at: now)
                throw JobOrchestratorError.integrationConflict(files: files)
            }
            if case let .uncommittedDocumentsWouldBeOverwritten(_, files) = error {
                // ADR-0024: the user commits request/ADR files; nothing was integrated or overwritten.
                let message = Self.uncommittedDocumentsMessage(files: files)
                review.conflict = ReviewConflictInfo(files: files, message: message, detectedAt: now)
                try? await deps.reviews.save(review, at: now)
                host.integrationProblem = message
                try? runtime.save(host)
                await appendEvent(job.workItemId, kind: .conflictDetected, actor: actor, payload: [
                    "reviewId": reviewId.uuidString, "jobId": job.jobId.uuidString, "reason": "uncommittedDocuments",
                    "files": files.joined(separator: "\n"),
                ], at: now)
                let shown = files.prefix(5).joined(separator: ", ") + (files.count > 5 ? ", …" : "")
                throw JobOrchestratorError.integrationRefused("\(message) \(shown)")
            }
            if case let .jobBranchMoved(expected, actual) = error {
                // SR-SEC-06: commits after the review are never integrated unreviewed.
                let message = String(localized: "Der Job-Branch hat sich seit dem Review verändert (\(String(expected.prefix(10))) → \(String(actual.prefix(10)))); nichts wurde übernommen. Bitte den neuen Stand erneut prüfen.", bundle: .module)
                host.integrationProblem = message
                try? runtime.save(host)
                throw JobOrchestratorError.integrationRefused(message)
            }
            host.integrationProblem = String(localized: "Integration abgelehnt: \(String(describing: error))", bundle: .module)
            try? runtime.save(host)
            throw JobOrchestratorError.integrationRefused("\(error)")
        }

        try review.recordIntegration(commit: result.commitSHA, strategy: strategy)
        try await deps.reviews.save(review, at: now)
        host.integrationProblem = nil
        host.integratedAt = now
        try? runtime.save(host)
        _ = try await deps.workItems.applyHostStatus(job.workItemId, to: .integrated, actor: actor, at: now)
        await appendEvent(job.workItemId, kind: .integrated, actor: actor, payload: [
            "reviewId": reviewId.uuidString, "jobId": job.jobId.uuidString, "commit": result.commitSHA,
            "strategy": strategy.rawValue, "defaultBranch": host.defaultBranch,
        ], at: now)
        return result
    }

    /// German review text for an integration that would overwrite uncommitted request/ADR files (ADR-0024).
    static func uncommittedDocumentsMessage(files: [String]) -> String {
        String(localized: "Übernahme abgebrochen: \(files.count) nicht committete Request-/ADR-Datei(en) im Haupt-Working-Tree würden überschrieben. Bitte zuerst committen oder sichern; nichts wurde übernommen.", bundle: .module)
    }

    /// Repository-relative document folders of the project's effective layout (ADR-0024).
    func documentPaths(for projectId: ProjectID, settings: ProjectSettings?) async -> [String] {
        if let provider = deps.documentPaths { return await provider(projectId) }
        return Self.documentPaths(settings: settings ?? ProjectSettings(updatedAt: currentTime()))
    }

    /// ADR folder plus requests root; if the requests root is the repository root, its status folders
    /// instead (the exemption must never cover the whole repository).
    public static func documentPaths(settings: ProjectSettings) -> [String] {
        func normalized(_ path: String) -> String {
            var value = path.trimmingCharacters(in: .whitespacesAndNewlines)
            while value.hasPrefix("./") { value.removeFirst(2) }
            while value.hasSuffix("/") { value.removeLast() }
            return value == "." ? "" : value
        }
        let requestsRoot = normalized(settings.requestsRoot)
        let requestFolders = requestsRoot.isEmpty
            ? [settings.openPath, settings.activePath, settings.reviewPath, settings.donePath].map(normalized)
            : [requestsRoot]
        var result: [String] = []
        for path in [normalized(settings.adrPath)] + requestFolders where !path.isEmpty && !result.contains(path) {
            result.append(path)
        }
        return result
    }

    /// Spec M1 step 6: `done` only when the integration commit is verifiably in the default branch
    /// and the user approves. Moving the request file to `done/` is the Markdown layer's job.
    @discardableResult
    public func markDone(workItemId: WorkItemID, approvedBy actor: EventActor) async throws -> WorkItem {
        guard actor.isUser else { throw JobOrchestratorError.userDecisionRequired }
        let now = currentTime()
        guard let item = try await deps.workItems.fetch(workItemId) else { throw JobOrchestratorError.workItemNotFound(workItemId) }
        guard item.status == .integrated else { throw JobOrchestratorError.notIntegrated(item.status) }
        var proof: (Review, ReviewHostRecord)?
        for job in try await deps.jobs.jobs(forWorkItem: workItemId).reversed() {
            for review in try await deps.reviews.reviews(jobId: job.jobId) where review.integrationCommit != nil {
                if let details = runtime.reviewHost(review.reviewId) { proof = (review, details) }
            }
            if proof != nil { break }
        }
        guard let (review, details) = proof, let commit = review.integrationCommit else {
            throw JobOrchestratorError.notIntegrated(item.status)
        }
        let check = try await deps.git.run(["merge-base", "--is-ancestor", commit, "refs/heads/\(details.defaultBranch)"],
                                           in: URL(filePath: details.repositoryPath, directoryHint: .isDirectory),
                                           acceptedExitCodes: [0, 1])
        guard check.exitCode == 0 else { throw JobOrchestratorError.integrationCommitNotInDefaultBranch(commit) }
        let done = try await deps.workItems.applyHostStatus(workItemId, to: .done, actor: actor, at: now)
        await appendEvent(workItemId, actor: actor, payload: [
            "type": "markedDone", "commit": commit, "reviewId": review.reviewId.uuidString, "approvedBy": actor.payloadText,
        ], at: now)
        return done
    }

    /// Removes a finished job's worktree after explicit confirmation (ADR-0015). Never forces, never
    /// deletes the branch.
    public func removeWorktree(jobId: JobID, by actor: EventActor) async throws {
        guard actor.isUser else { throw JobOrchestratorError.userDecisionRequired }
        guard let job = try await deps.jobs.fetch(jobId) else { throw JobOrchestratorError.jobNotFound(jobId) }
        // Host-local path only (SR-SEC-02).
        guard job.state.isTerminal, runs[jobId] == nil, let record = runtime.record(jobId), let path = record.worktreePath,
              let repositoryPath = record.repositoryPath
        else { throw JobOrchestratorError.invalidState(jobId, job.state) }
        try await worktrees.removeWorktree(at: URL(filePath: path, directoryHint: .isDirectory),
                                           repository: URL(filePath: repositoryPath, directoryHint: .isDirectory))
    }

    // MARK: - Planning status (spec K3)

    public func scheduleStatus(jobId: JobID, now: Date) async throws -> JobScheduleStatus {
        guard let job = try await deps.jobs.fetch(jobId) else { throw JobOrchestratorError.jobNotFound(jobId) }
        let record = runtime.record(jobId)
        let lastSeen = await hostLastSeen()
        let zone = Self.timeZone(of: job.schedule)
        let planned = job.scheduledAt
        var quota: QuotaRetryState?
        if case let .retryAfterQuota(state) = job.schedule.kind { quota = state }
        let text: String
        if let missed = record?.missedRun, missed.resolution == .awaitingUser {
            text = missed.statusText
        } else if let shared = ScheduleStatusText.status(for: job, hostLastSeen: lastSeen, now: now, timeZone: zone),
                  job.state == .waitingQuota || (planned.map { $0 > now } ?? false) {
            text = shared
        } else if [.requested, .pendingMac, .scheduled].contains(job.state), let block = blocks[jobId] {
            let reason = block.germanDescription
            text = String(localized: "wartet: \(reason)", bundle: .module)
        } else {
            text = job.state.germanDisplayName
        }
        return JobScheduleStatus(
            jobId: jobId, state: job.state, plannedStart: planned,
            timeZoneIdentifier: { if case let .at(local) = job.schedule.kind { return local.timeZoneIdentifier }; return nil }(),
            hostLastSeen: lastSeen, missedRun: record?.missedRun, nextQuotaAttempt: quota, admissionBlock: blocks[jobId], text: text)
    }
}
