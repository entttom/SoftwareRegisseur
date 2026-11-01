import Foundation
import SoftwareRegisseurAgents
import SoftwareRegisseurDomain
import SoftwareRegisseurGit
import SoftwareRegisseurPersistence
import SoftwareRegisseurProcess

extension JobOrchestrator {
    static let maxTextLength = 20_000

    func handle(_ event: AgentSessionEvent, jobId: JobID) async {
        guard let run = runs[jobId], !run.finished else { return }
        let now = currentTime()
        switch event {
        case let .sessionIdentified(sessionId, threadId):
            _ = try? await updateJob(jobId, at: now) { $0.sessionId = sessionId }
            _ = try? updateRecord(jobId) { $0.threadId = threadId }
        case .status, .diagnostic:
            break
        case let .assistantText(text, isDelta):
            if isDelta {
                let combined = (runs[jobId]?.currentText ?? "") + text
                runs[jobId]?.currentText = String(combined.suffix(Self.maxTextLength))
            } else {
                runs[jobId]?.lastMessage = String(text.suffix(Self.maxTextLength))
                runs[jobId]?.currentText = ""
            }
        case let .toolActivity(activity):
            if let result = Self.testResult(from: activity) {
                if runs[jobId]?.tests[activity.id] == nil { runs[jobId]?.testOrder.append(activity.id) }
                runs[jobId]?.tests[activity.id] = result
            }
        case let .approvalRequested(request):
            await registerApproval(request, jobId: jobId, workItemId: run.workItemId, now: now)
        case let .approvalResolved(id):
            // The agent withdrew the request (e.g. Codex `serverRequest/resolved`).
            guard let live = runs[jobId]?.approvals.removeValue(forKey: id) else { return }
            await updateApproval(live.approvalId, at: now) { $0.withdraw(at: now) }
            if runs[jobId]?.approvals.isEmpty == true, (try? await deps.jobs.fetch(jobId))??.state == .waitingApproval {
                _ = try? await move(jobId, to: .running, at: now)
            }
        case let .quota(signal):
            // K2: only an explicit limit signal stops the run; warnings and provider-side retries do not.
            guard signal.kind == .limitReached, runs[jobId]?.stopIntent == nil else { return }
            runs[jobId]?.quotaSignal = signal
            runs[jobId]?.stopIntent = .quota
            await run.session.cancel()
        case let .effectiveConfiguration(configuration):
            // ADR-0006: record only what the adapter verifiably reported.
            _ = try? await updateJob(jobId, at: now) {
                $0.recordConfirmedEffectiveConfiguration(model: configuration.model, effort: configuration.effort, at: now)
            }
            if !configuration.matchesRequest {
                await appendEvent(run.workItemId, payload: [
                    "type": "effectiveConfigurationMismatch", "jobId": jobId.uuidString,
                    "model": configuration.model?.rawValue ?? AgentJob.unconfirmedText,
                    "effort": configuration.effort?.rawValue ?? AgentJob.unconfirmedText,
                    "note": configuration.note ?? "",
                ], at: now)
            }
        case let .finished(result):
            await complete(jobId, result: result)
        }
    }

    func streamEnded(_ jobId: JobID) async {
        guard let run = runs[jobId], !run.finished else { return }
        await complete(jobId, result: AgentSessionResult(
            outcome: .failed(.protocolViolation(String(localized: "Ereignisstrom ohne Abschluss beendet", bundle: .module))), finalMessage: nil, sessionId: nil))
    }

    /// Mirrors an agent approval request as a synced `PendingApproval` (spec J6 V1 fallback): German
    /// summary, redacted preview (spec Q1), allowed decisions, and an expiry when the timeout policy
    /// stops the run. Nothing answers it automatically (spec L3).
    func registerApproval(_ request: AgentApprovalRequest, jobId: JobID, workItemId: WorkItemID, now: Date) async {
        let timeout = configuration.approvalTimeout
        let expiresAt = timeout.action == .fail ? timeout.timeout.map { now.addingTimeInterval($0) } : nil
        let approval = Self.pendingApproval(for: request, jobId: jobId, workItemId: workItemId, hostId: hostId,
                                            requestedAt: now, expiresAt: expiresAt)
        let fullPreview = approval.isPreviewTruncated
            ? (request.command ?? request.summary).map { String(SecretRedactor.standard.redact($0).prefix(Self.maxFullPreviewLength)) }
            : nil
        runs[jobId]?.approvals[request.id] = LiveApproval(approvalId: approval.id, availableDecisions: request.availableDecisions,
                                                          receivedAt: now, fullPreview: fullPreview)
        do {
            try await deps.approvals.save(approval, at: now)
        } catch {
            runs[jobId]?.lastMessage = "\(error)"
        }
        if (try? await deps.jobs.fetch(jobId))??.state == .running {
            _ = try? await move(jobId, to: .waitingApproval, at: now)
        }
        await appendEvent(workItemId, kind: .approvalRequested, payload: [
            "jobId": jobId.uuidString, "approvalId": approval.id.uuidString, "requestId": request.id.rawValue,
            "kind": Self.describe(request.kind), "summary": approval.summary,
        ], at: now)
    }

    static let maxPreviewLength = 2_000
    /// Upper bound of the host-local full preview shown in the Mac UI (SR-SEC-08).
    static let maxFullPreviewLength = 200_000

    static func pendingApproval(
        for request: AgentApprovalRequest, jobId: JobID, workItemId: WorkItemID, hostId: HostID, requestedAt: Date, expiresAt: Date?
    ) -> PendingApproval {
        let redactor = SecretRedactor.standard
        func clean(_ text: String?) -> String? {
            guard let text, !text.isEmpty else { return nil }
            return String(redactor.redact(text).prefix(maxPreviewLength))
        }
        // SR-SEC-08: a preview that does not show the whole request is marked, and `allow` is withheld
        // from synced devices; it stays possible on the Mac after the full text was shown there.
        let fullPreviewLength = (request.command ?? request.summary).map { redactor.redact($0).count }
        let truncated = (fullPreviewLength ?? 0) > maxPreviewLength
            || request.reason.map { redactor.redact($0).count > maxPreviewLength } == true
        var remoteDecisions = allowedDecisions(request.availableDecisions)
        let hostReviewRequired = truncated && remoteDecisions.contains(.allow)
        if truncated { remoteDecisions.removeAll { $0 == .allow } }
        let kind: ApprovalRequestKind
        var toolName: String?
        let summary: String
        switch request.kind {
        case .commandExecution:
            kind = .commandExecution
            summary = String(localized: "Der Agent möchte einen Befehl ausführen.", bundle: .module)
        case .fileChange:
            kind = .fileChange
            let count = request.filePaths.count
            summary = count > 0
                ? String(localized: "Der Agent möchte \(count) Datei(en) ändern.", bundle: .module)
                : String(localized: "Der Agent möchte Dateien ändern.", bundle: .module)
        case .permissions:
            kind = .permissions
            summary = String(localized: "Der Agent bittet um zusätzliche Berechtigungen.", bundle: .module)
        case let .toolUse(name):
            kind = .toolUse
            toolName = name
            summary = String(localized: "Der Agent möchte das Werkzeug „\(name)“ verwenden.", bundle: .module)
        }
        return PendingApproval(
            jobId: jobId, workItemId: workItemId, hostId: hostId, requestId: request.id.rawValue, kind: kind, toolName: toolName,
            summary: summary, preview: clean(request.command ?? request.summary),
            filePaths: request.filePaths.map { redactor.redact($0) }, reason: clean(request.reason),
            allowedDecisions: remoteDecisions, requestedAt: requestedAt, expiresAt: expiresAt,
            previewFullLength: truncated ? fullPreviewLength : nil, allowRequiresHostReview: hostReviewRequired ? true : nil)
    }

    /// Allow/deny as offered on user devices; an empty agent list means both are accepted. `allow` is
    /// offered only when the agent accepts a plain, one-time allow: it is never turned into
    /// „allow for the session“ (SR-SEC-16), which would grant more than the user saw.
    static func allowedDecisions(_ available: [AgentApprovalDecision]) -> [ApprovalDecisionKind] {
        guard !available.isEmpty else { return ApprovalDecisionKind.allCases }
        var result: [ApprovalDecisionKind] = []
        if available.contains(.allow) {
            result.append(.allow)
        }
        if available.contains(where: { if case .deny = $0 { true } else if case .cancel = $0 { true } else { false } }) {
            result.append(.deny)
        }
        return result
    }

    /// Session ended: decide the job state, capture review data, then release the lock only after
    /// a verified process end (spec M1 step 3, L1).
    func complete(_ jobId: JobID, result: AgentSessionResult) async {
        guard let run = runs[jobId], !run.finished else { return }
        runs[jobId]?.finished = true
        let now = currentTime()
        do {
            try await finalize(run: runs[jobId] ?? run, result: result, now: now)
        } catch {
            let reason = String(localized: "Abschluss konnte nicht erfasst werden: \(String(describing: error))", bundle: .module)
            _ = try? await move(jobId, to: .failed, at: now) { $0.lastError = reason }
        }
        // The session that could transport answers is gone; open requests are withdrawn.
        for live in (runs[jobId] ?? run).approvals.values {
            await updateApproval(live.approvalId, at: now) { $0.withdraw(at: now) }
        }
        runs[jobId]?.approvals = [:]
        if let lock = try? await deps.locks.fetch(run.lockId), !lock.isReleased {
            let job = try? await deps.jobs.fetch(jobId)
            _ = await attemptLockRelease(lock, job: job, now: now)
        }
        // Removed last so `waitUntilSessionEnds` observes the completed bookkeeping.
        runs[jobId] = nil
    }

    func finalize(run: LiveRun, result: AgentSessionResult, now: Date) async throws {
        let jobId = run.jobId
        var quota = run.quotaSignal
        if case let .quotaExhausted(signal) = result.outcome, quota == nil { quota = signal }
        switch run.stopIntent {
        case let .cancel(actor):
            try await move(jobId, to: .cancelled, actor: actor, at: now)
        case let .pause(actor):
            if case .completed = result.outcome {
                try await captureReviewAndFinish(run: run, result: result, now: now)
            } else {
                try await move(jobId, to: .paused, actor: actor, at: now) {
                    $0.lastError = String(localized: "Vom Benutzer pausiert – Agent gestoppt; Fortsetzen startet eine neue Sitzung im selben Worktree.", bundle: .module)
                }
            }
        case .approvalTimeout:
            try await move(jobId, to: .failed, at: now) {
                $0.lastError = String(localized: "Freigabe nicht rechtzeitig beantwortet – Lauf beendet, keine automatische Freigabe.", bundle: .module)
            }
        case .quota, nil:
            if let quota {
                try await enterWaitingQuota(jobId: jobId, workItemId: run.workItemId, signal: quota, now: now)
                return
            }
            switch result.outcome {
            case .completed:
                try await captureReviewAndFinish(run: run, result: result, now: now)
            case let .failed(failure):
                try await move(jobId, to: .failed, at: now) { $0.lastError = failure.description }
            case .cancelled, .quotaExhausted:
                try await move(jobId, to: .failed, at: now) {
                    $0.lastError = String(localized: "Agentensitzung wurde ohne Anforderung beendet.", bundle: .module)
                }
            }
        }
    }

    /// K2: `waiting_quota` with a documented next attempt; bounded attempts, provider signals win.
    func enterWaitingQuota(jobId: JobID, workItemId: WorkItemID, signal: QuotaSignal, now: Date) async throws {
        guard let job = try await deps.jobs.fetch(jobId) else { throw JobOrchestratorError.jobNotFound(jobId) }
        let providerRetry = signal.resetsAt ?? signal.retryAfter.map { now.addingTimeInterval($0.timeInterval) }
        let decision = configuration.quotaRetryPlanner.nextAttempt(
            afterFailureAt: now, previousAttempts: job.retryCount, providerRetryAfter: providerRetry,
            userExpectedReset: nil, using: &rng)
        switch decision {
        case let .retry(state):
            let text = ScheduleStatusText.quota(state, now: now, timeZone: Self.timeZone(of: job.schedule))
            let code = signal.code.map { " (\($0))" } ?? ""
            let message = String(localized: "Kontingent erreicht\(code) – \(text)", bundle: .module)
            try await move(jobId, to: .waitingQuota, at: now) {
                $0.schedule.kind = .retryAfterQuota(state)
                $0.retryCount = state.attempt
                $0.lastError = message
            }
            _ = try? updateRecord(jobId) { $0.lastQuotaMessage = signal.message }
            await appendEvent(workItemId, kind: .quotaWait, payload: [
                "jobId": jobId.uuidString, "attempt": String(state.attempt),
                "nextAttemptAt": Self.iso(state.nextAttemptAt), "basis": state.basis.rawValue, "text": text,
            ], at: now)
        case let .giveUp(attempts):
            try await move(jobId, to: .failed, at: now) {
                $0.lastError = String(localized: "Kontingent nach \(attempts) Versuchen weiterhin erschöpft – keine weiteren automatischen Versuche.", bundle: .module)
            }
        }
    }

    /// Spec M1 steps 2–3: changed files, commits, tests, agent summary → `Review`; job `finished`,
    /// work item `implementation_finished → review` (ADR-0012), never `done`.
    func captureReviewAndFinish(run: LiveRun, result: AgentSessionResult, now: Date) async throws {
        let jobId = run.jobId
        // SR-SEC-02: paths and branch only from the host-local runtime record, never from the synced job.
        guard let job = try await deps.jobs.fetch(jobId), let record = runtime.record(jobId),
              let branch = record.branch, let worktreePath = record.worktreePath,
              let repositoryPath = record.repositoryPath, let defaultBranch = record.defaultBranch
        else { throw JobOrchestratorError.reviewDataUnavailable(jobId) }
        let git = deps.git
        let repository = URL(filePath: repositoryPath, directoryHint: .isDirectory)
        let worktree = URL(filePath: worktreePath, directoryHint: .isDirectory)

        var autoCommitted: [String] = []
        var excludedSecrets: [String] = []
        var excludedDocuments: [String] = []
        var problems: [String] = []
        if configuration.commitAgentChangesOnFinish, let status = try? await git.status(of: worktree), !status.isClean {
            let paths = status.entries.filter { $0.kind != .ignored }.map(\.path)
            do {
                // ADR-0026: commit only in a verified linked worktree of this job below the service's
                // worktree base – never in the main working tree – and never likely secrets (SR-SEC-09).
                try await worktrees.verifyManagedWorktree(worktree, repository: repository, expectedBranch: branch)
                excludedSecrets = paths.filter { Self.looksLikeSecretFile($0, in: worktree) }
                // ADR-0024: Software Regisseur never commits request/ADR files, not even on the job branch.
                let documentFolders = await documentPaths(for: job.projectId, settings: try? await deps.projects.settings(forProject: job.projectId))
                excludedDocuments = paths.filter { path in
                    !excludedSecrets.contains(path) && documentFolders.contains { path == $0 || path.hasPrefix($0 + "/") }
                }
                try await git.run(["add", "-A", "--", "."], in: worktree)
                if !(excludedSecrets + excludedDocuments).isEmpty {
                    try await git.run(["--literal-pathspecs", "reset", "--quiet", "--"] + excludedSecrets + excludedDocuments, in: worktree)
                }
                let staged = try await git.run(["diff", "--cached", "--quiet"], in: worktree, acceptedExitCodes: [0, 1])
                if staged.exitCode == 1 {
                    try await git.run(["commit", "--quiet", "--no-verify", "--no-gpg-sign", "-m",
                                       "Software Regisseur: Agentenergebnis \(job.jobId.shortString)"],
                                      in: worktree, extraConfig: [("core.hooksPath", "/dev/null")])
                    autoCommitted = paths.filter { !excludedSecrets.contains($0) && !excludedDocuments.contains($0) }
                }
            } catch {
                problems.append(String(localized: "Nicht committete Agentenänderungen konnten nicht gesichert werden: \(String(describing: error))", bundle: .module))
            }
        }

        let summary = try await IntegrationService(git: git).diffSummary(repository: repository, base: defaultBranch, head: branch)
        let log = try await git.run(["log", "--reverse", "--format=%H%x1f%s", "\(defaultBranch)..\(branch)", "--"], in: repository)
        let commits = log.lines.compactMap { line -> ReviewCommit? in
            let parts = line.split(separator: "\u{1f}", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            return parts.first.map { ReviewCommit(sha: $0, subject: parts.count > 1 ? parts[1] : "") }
        }
        let head = try await git.run(["rev-parse", "--verify", "refs/heads/\(branch)^{commit}"], in: repository).trimmedOutput

        let tests = run.testOrder.compactMap { run.tests[$0] }
        let agentSummary = (result.finalMessage ?? run.lastMessage ?? (run.currentText.isEmpty ? nil : run.currentText))
            .map { String(SecretRedactor.standard.redact($0).suffix(Self.maxSummaryLength)) }
        var notes = problems
        if !autoCommitted.isEmpty {
            notes.append(String(localized: "\(autoCommitted.count) nicht committete Datei(en) des Agenten wurden auf dem Job-Branch committet.", bundle: .module))
        }
        if !excludedDocuments.isEmpty {
            let shown = excludedDocuments.prefix(10).joined(separator: ", ") + (excludedDocuments.count > 10 ? ", …" : "")
            notes.append(String(localized: "Vom Agenten geänderte Request-/ADR-Dateien wurden nicht committet (ADR-0024): \(shown). Sie liegen weiter im Worktree; die Übernahme ist blockiert, bis sie entfernt oder bewusst selbst committet wurden.", bundle: .module))
        }
        if !excludedSecrets.isEmpty {
            let shown = excludedSecrets.prefix(10).joined(separator: ", ") + (excludedSecrets.count > 10 ? ", …" : "")
            notes.append(String(localized: "Nicht committet, weil sie wie Geheimnisse aussehen: \(shown). Die Dateien liegen weiter im Worktree; die Übernahme ist blockiert, bis sie entfernt oder bewusst selbst committet wurden.", bundle: .module))
        }
        if !result.permissionDenials.isEmpty {
            let denied = result.permissionDenials.joined(separator: ", ")
            notes.append(String(localized: "Abgelehnte Werkzeuge: \(denied)", bundle: .module))
        }
        // Review content is synced (spec M1 step 4: compact summary on the iPhone); paths stay host-local.
        let review = Review(
            jobId: jobId,
            diffSummary: SoftwareRegisseurDomain.DiffSummary(
                filesChanged: summary.files.count, insertions: summary.totalAdditions, deletions: summary.totalDeletions,
                files: summary.files.map(\.path)),
            testResults: tests, summary: agentSummary, commits: commits,
            fileChanges: summary.files.map {
                ReviewFileChange(status: $0.status, path: $0.path, originalPath: $0.originalPath, additions: $0.additions, deletions: $0.deletions)
            },
            testSummary: TestRunSummary(results: tests), headCommit: head, notes: notes)
        try await deps.reviews.save(review, at: now)
        try runtime.save(ReviewHostRecord(
            reviewId: review.reviewId, jobId: jobId, workItemId: job.workItemId, repositoryPath: repositoryPath,
            defaultBranch: defaultBranch, branch: branch, worktreePath: worktreePath, baseCommit: record.baseCommit,
            headCommit: head, autoCommittedPaths: autoCommitted, permissionDenials: result.permissionDenials,
            capturedAt: now, integrationProblem: problems.isEmpty ? nil : problems.joined(separator: " "),
            excludedSecretPaths: excludedSecrets.isEmpty ? nil : excludedSecrets))

        let sessionId = result.sessionId
        try await move(jobId, to: .finished, at: now) {
            if $0.sessionId == nil, let sessionId { $0.sessionId = sessionId }
            $0.lastError = nil
        }
        _ = try await deps.workItems.applyHostStatus(job.workItemId, to: .review, actor: hostActor, at: now)
        await appendEvent(job.workItemId, payload: [
            "type": "reviewCaptured", "jobId": jobId.uuidString, "reviewId": review.reviewId.uuidString,
            "filesChanged": String(summary.files.count), "insertions": String(summary.totalAdditions),
            "deletions": String(summary.totalDeletions), "commits": String(commits.count),
            "tests": tests.map { "\($0.name)=\($0.outcome.rawValue)" }.joined(separator: "; "),
        ], at: now)
    }

    static let maxSummaryLength = 8_000

    /// File names that hold credentials by convention (SR-SEC-09). Templates such as `.env.example` are
    /// only excluded when their content contains a credential.
    static let secretFileNames: Set<String> = [
        ".env", ".netrc", ".npmrc", ".pypirc", ".git-credentials", ".htpasswd", "credentials", "credentials.json",
        "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "secrets.json", "secrets.yml", "secrets.yaml",
    ]
    static let secretFileExtensions: Set<String> = ["pem", "key", "p12", "pfx", "keystore", "jks", "p8", "ppk", "asc", "gpg", "kdbx"]
    static let secretTemplateSuffixes = [".example", ".sample", ".template", ".dist"]

    /// Whether an uncommitted file of the agent looks like a secret: by name (`.env*`, private keys,
    /// keystores, credential files) or by content (a known credential format in the first MiB).
    static func looksLikeSecretFile(_ relativePath: String, in worktree: URL) -> Bool {
        let name = (relativePath as NSString).lastPathComponent.lowercased()
        let isTemplate = secretTemplateSuffixes.contains { name.hasSuffix($0) }
        if !isTemplate {
            if secretFileNames.contains(name) || name.hasPrefix(".env.") { return true }
            let ext = (name as NSString).pathExtension
            if !ext.isEmpty, secretFileExtensions.contains(ext) { return true }
            if name.hasPrefix("id_"), !name.hasSuffix(".pub"), !name.contains(".") { return true }
        }
        let path = worktree.appending(path: relativePath).path(percentEncoded: false)
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1 << 20), !data.contains(0) else { return false }
        return SecretRedactor.standard.containsKnownCredentialFormat(String(decoding: data, as: UTF8.self))
    }

    /// Test runs the agent reported as tool activity (completed/failed shell commands that run tests).
    static func testResult(from activity: ToolActivity) -> TestResult? {
        guard case .command = activity.kind else { return nil }
        let outcome: TestOutcome
        switch activity.phase {
        case .completed: outcome = .passed
        case .failed: outcome = .failed
        case .declined: outcome = .notRun
        case .started: return nil
        }
        let command = activity.summary.lowercased()
        let markers = ["swift test", "xcodebuild test", "npm test", "npm run test", "pnpm test", "yarn test", "pytest",
                       "go test", "cargo test", "make test", "gradle test", "mvn test", "bundle exec rspec", "jest", "vitest"]
        guard markers.contains(where: { command.contains($0) }) else { return nil }
        return TestResult(name: String(activity.summary.prefix(200)), outcome: outcome)
    }

    static func describe(_ kind: ApprovalKind) -> String {
        switch kind {
        case .commandExecution: "commandExecution"
        case .fileChange: "fileChange"
        case .permissions: "permissions"
        case let .toolUse(name): "toolUse:\(name)"
        }
    }
}
