import Foundation
import SoftwareRegisseurAgents
import SoftwareRegisseurDomain
import SoftwareRegisseurGit
import SoftwareRegisseurJobs
import SoftwareRegisseurPersistence
import Testing

/// Orchestrator-level fixes of the security audit 2026-10-30 (ADR-0026).
@Suite("Security audit 2026-10-30: jobs")
struct SecurityAuditJobTests {
    /// Agent asks for approval of `command` and waits for the answer; on allow it writes a file.
    static func approval(_ id: String, command: String, available: [AgentApprovalDecision]) -> FakeScript {
        { control in
            control.emit(.sessionIdentified(sessionId: "session-\(control.request.sessionUUID)", threadId: nil))
            control.emit(.approvalRequested(AgentApprovalRequest(
                id: ApprovalRequestID(id), kind: .commandExecution, summary: "Befehl", command: command,
                availableDecisions: available, receivedAt: Date())))
            while control.decisions[id] == nil, !control.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            if control.decisions[id] == .allow { Scripts.writeFile(control, "approved.txt", "ok\n") }
            control.finish(.completed, message: "Fertig.")
        }
    }

    static func writeFiles(_ files: [String: String]) -> FakeScript {
        { control in
            control.emit(.sessionIdentified(sessionId: "session-\(control.request.sessionUUID)", threadId: nil))
            for (name, content) in files { Scripts.writeFile(control, name, content) }
            control.finish(.completed, message: "Fertig.")
        }
    }

    // MARK: SR-SEC-01

    @Test("SR-SEC-01: repository location outside the confirmed roots → repositoryUnavailable")
    func locationOutsideRootsIsUnavailable() async throws {
        let env = try await TestEnvironment()
        let outside = env.root.appending(path: "elsewhere/app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try await env.git.run(["init", "--quiet", "--initial-branch=main"], in: outside)
        try await env.database.projects.saveLocation(
            RepositoryLocation(projectId: env.project.id, hostId: env.hostId, canonicalPath: outside.path(percentEncoded: false)), at: t0)
        let orchestrator = try env.orchestrator()
        let item = try await env.addWorkItem("Außerhalb")
        let job = try await env.request(orchestrator, item)
        let report = await orchestrator.tick(now: t0)
        #expect(report.blocked[job.jobId] == .repositoryUnavailable)
        #expect(report.started.isEmpty)

        // A live root source is strict: without a confirmed root nothing starts, with it the repo is fine.
        try await env.database.projects.saveLocation(
            RepositoryLocation(projectId: env.project.id, hostId: env.hostId, canonicalPath: env.repo.path(percentEncoded: false)), at: t0)
        let strict = try env.orchestrator(allowedRepositoryRoots: { [] })
        #expect(await strict.tick(now: t0.addingTimeInterval(1)).blocked[job.jobId] == .repositoryUnavailable)
    }

    // MARK: SR-SEC-02

    @Test("SR-SEC-02: synced worktreePath = main working tree → new worktree, main tree untouched")
    func syncedWorktreePathIsIgnored() async throws {
        let env = try await TestEnvironment()
        let orchestrator = try env.orchestrator()
        let item = try await env.addWorkItem("Umlenkung")
        try Data("Benutzerarbeit\n".utf8).write(to: env.repo.appending(path: "user-wip.txt"))
        let mainBefore = try await env.output(["rev-parse", "main"])
        env.codex.enqueue(Self.writeFiles(["agent.txt": "Agent\n"]))
        let requested = try await env.request(orchestrator, item)
        // Another device rewrites the synced job to point at the main working tree and branch.
        _ = try await env.database.jobs.update(requested.jobId, expectedRevision: requested.revision, actor: env.user, at: t0) {
            $0.worktreePath = env.repo.path(percentEncoded: false)
            $0.branch = "main"
        }
        await orchestrator.tick(now: t0)
        await orchestrator.waitUntilSessionEnds(requested.jobId)

        let job = try await env.job(requested.jobId)
        #expect(job.state == .finished)
        let worktree = try #require(job.worktreePath)
        #expect(worktree.hasPrefix(env.root.appending(path: "worktrees").path(percentEncoded: false)))
        #expect(env.codex.requests.first?.workingDirectory.path(percentEncoded: false).hasPrefix(
            env.root.appending(path: "worktrees").path(percentEncoded: false)) == true)
        #expect(try await env.output(["rev-parse", "main"]) == mainBefore)
        #expect(!env.fileExists("agent.txt", in: env.repo))
        #expect(try await env.git.status(of: env.repo).untrackedPaths == ["user-wip.txt"])
    }

    // MARK: SR-SEC-09

    @Test("SR-SEC-09: agent writes .env → not committed, reported in the review")
    func secretLookingOutputIsNotCommitted() async throws {
        let env = try await TestEnvironment()
        let orchestrator = try env.orchestrator()
        let item = try await env.addWorkItem("Konfiguration")
        env.codex.enqueue(Self.writeFiles([
            ".env": "OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwxyz0123\n",
            "config/deploy.yml": "token: ghp_abcdefghijklmnopqrstuvwxyz0123456789\n",
            "src.swift": "let token = makeToken()\n",
            "docs/requests/open/FR-0001-x.md": "---\nstatus: done\n---\n",
        ]))
        let job = try await env.request(orchestrator, item)
        await orchestrator.tick(now: t0)
        await orchestrator.waitUntilSessionEnds(job.jobId)

        let review = try #require(try await env.database.reviews.reviews(jobId: job.jobId).first)
        let details = try #require(await orchestrator.reviewDetails(review.reviewId))
        #expect(details.autoCommittedPaths == ["src.swift"])
        #expect(Set(details.excludedSecretPaths) == [".env", "config/deploy.yml"])
        #expect(review.notes.contains { $0.contains("wie Geheimnisse") })
        // ADR-0024/ADR-0026: request files changed by the agent are not committed by Software Regisseur either.
        #expect(review.notes.contains { $0.contains("ADR-0024") && $0.contains("docs/requests/open/FR-0001-x.md") })
        #expect(review.diffSummary.files == ["src.swift"])
        let branch = try #require(try await env.job(job.jobId).branch)
        let tree = try await env.output(["ls-tree", "-r", "--name-only", branch])
        #expect(!tree.contains(".env") && !tree.contains("deploy.yml") && !tree.contains("FR-0001-x.md"))
    }

    // MARK: SR-SEC-06

    @Test("SR-SEC-06: commit after the review → integration refused, default branch unchanged")
    func integrationRefusesMovedBranch() async throws {
        let env = try await TestEnvironment()
        let orchestrator = try env.orchestrator()
        let item = try await env.addWorkItem("Nachgeschoben")
        env.codex.enqueue(Scripts.writeAndCommit(commitWith: env.git))
        let job = try await env.request(orchestrator, item)
        await orchestrator.tick(now: t0)
        await orchestrator.waitUntilSessionEnds(job.jobId)
        let review = try #require(try await env.database.reviews.reviews(jobId: job.jobId).first)
        try await orchestrator.approveReview(review.reviewId, by: env.user)

        let worktree = URL(filePath: try #require(await orchestrator.runtimeRecord(for: job.jobId)?.worktreePath), directoryHint: .isDirectory)
        try Data("ungeprüft\n".utf8).write(to: worktree.appending(path: "late.txt"))
        try await env.git.run(["add", "-A"], in: worktree)
        try await env.git.run(["commit", "--quiet", "-m", "after review"], in: worktree)
        let mainBefore = try await env.output(["rev-parse", "main"])
        await #expect(throws: JobOrchestratorError.self) {
            _ = try await orchestrator.integrate(reviewId: review.reviewId, approvedBy: env.user)
        }
        #expect(try await env.output(["rev-parse", "main"]) == mainBefore)
        #expect(try await env.item(item.uuid).status == .review)
    }

    // MARK: SR-SEC-08 / SR-SEC-16

    @Test("SR-SEC-08: truncated preview → remote allow impossible; Mac allow only after full-text confirmation")
    func truncatedPreviewNeedsHostReview() async throws {
        let env = try await TestEnvironment()
        let orchestrator = try env.orchestrator(approvalTimeout: ApprovalTimeoutPolicy(timeout: nil))
        let item = try await env.addWorkItem("Langer Befehl")
        let command = "echo " + String(repeating: "a", count: 4_990) + " && rm -rf ~/Documents"
        env.codex.enqueue(Self.approval("long-1", command: command, available: [.allow, .deny(message: nil), .cancel]))
        let job = try await env.request(orchestrator, item)
        await orchestrator.tick(now: t0)
        try await eventually { try await env.job(job.jobId).state == .waitingApproval }
        let approval = try #require(await orchestrator.pendingApprovals(for: job.jobId).first)
        #expect(approval.isPreviewTruncated)
        #expect(approval.preview?.count == 2_000)
        #expect(approval.previewFullLength == command.count)
        #expect(approval.allowedDecisions == [.deny])
        #expect(approval.allowRequiresHostReview == true)
        #expect(approval.truncationNotice != nil)

        // iPhone: allow is not accepted.
        let phone = DeviceID()
        await #expect(throws: StoreError.approvalDecisionNotAllowed(approval.id, .allow)) {
            try await env.database.approvals.recordDecision(ApprovalDecision(for: approval, decision: .allow, decidedBy: phone, at: t0))
        }
        // Mac: full text available; allow requires the explicit confirmation.
        #expect(await orchestrator.fullApprovalPreview(approval.id)?.hasSuffix("rm -rf ~/Documents") == true)
        await #expect(throws: JobOrchestratorError.userDecisionRequired) {
            try await orchestrator.answerApprovalOnHost(approval.id, decision: .allow, fullTextConfirmed: false, by: env.user)
        }
        try await orchestrator.answerApprovalOnHost(approval.id, decision: .allow, fullTextConfirmed: true, by: env.user)
        await orchestrator.waitUntilSessionEnds(job.jobId)
        #expect(try await env.database.approvals.fetch(approval.id)?.decision == .allow)
        #expect(try await env.job(job.jobId).state == .finished)
    }

    @Test("SR-SEC-16: allow is never widened to allow-for-session")
    func allowForSessionIsNotOfferedAsAllow() async throws {
        let env = try await TestEnvironment()
        let orchestrator = try env.orchestrator(approvalTimeout: ApprovalTimeoutPolicy(timeout: nil))
        let item = try await env.addWorkItem("Sitzung")
        env.codex.enqueue(Self.approval("s-1", command: "make", available: [.allowForSession, .deny(message: nil)]))
        let job = try await env.request(orchestrator, item)
        await orchestrator.tick(now: t0)
        try await eventually { try await env.job(job.jobId).state == .waitingApproval }
        let approval = try #require(await orchestrator.pendingApprovals(for: job.jobId).first)
        #expect(approval.allowedDecisions == [.deny])
        #expect(!approval.isPreviewTruncated)
        await #expect(throws: JobOrchestratorError.self) {
            try await orchestrator.answerApprovalOnHost(approval.id, decision: .allow, fullTextConfirmed: true, by: env.user)
        }
        try await orchestrator.answerApprovalOnHost(approval.id, decision: .deny, fullTextConfirmed: false, by: env.user)
        await orchestrator.waitUntilSessionEnds(job.jobId)
        #expect(try await env.database.approvals.fetch(approval.id)?.decision == .deny)
    }
}
