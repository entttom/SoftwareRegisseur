import Foundation
import SoftwareRegisseurAgents
import SoftwareRegisseurAppCore
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC
import SoftwareRegisseurJobs
import SoftwareRegisseurPersistence
import SoftwareRegisseurSync
import SoftwareRegisseurSyncTesting
import Testing

@Suite("Agent Service: Integration mit Fake-Agenten und Fake-CloudKit", .serialized)
struct ServiceRuntimeTests {
    // MARK: iPhone-Jobwunsch → Mac → Review (J3, M1, N3, A15)

    @Test func syncedJobRequestRunsAndEndsInReview() async throws {
        let harness = try await ServiceTestHarness(cloud: true)
        let runtime = try await harness.makeRuntime()
        let project = try await harness.setUp(runtime)
        await runtime.performSync(reason: .manual)

        // iPhone: Projekt und Agentenfähigkeit kommen über CloudKit, Aufgabe + Jobwunsch gehen zurück.
        let phone = try await SimulatedPhone(server: try #require(harness.server), clock: harness.clock)
        try await phone.sync()
        let phoneProject = try #require(try await phone.database.projects.fetch(project.id))
        let macHost = try #require(phoneProject.hostId)
        let capability = try #require(try await phone.database.capabilities.capability(hostId: macHost, providerId: .codex))
        #expect(capability.isReady)
        let item = WorkItem(projectId: project.id, type: .feature, title: "CSV-Export", originalNote: "Bitte CSV-Export",
                            status: .open, createdAt: harness.clock.now())
        try await phone.database.workItems.insert(item, actor: phone.actor, at: harness.clock.now())
        let resolution = ModelEffortResolver.resolve(jobOverride: nil, projectPreference: nil, globalPreference: nil, capability: capability)
        let configuration = try #require(resolution.configuration)
        let job = AgentJob(idempotencyKey: IdempotencyKey(), projectId: project.id, workItemId: item.uuid, hostId: phoneProject.hostId,
                           configSnapshot: configuration.makeSnapshot(createdAt: harness.clock.now()),
                           schedule: JobSchedule(kind: .immediate), priority: .high, workItemStatusBeforeJob: item.status,
                           createdAt: harness.clock.now())
        _ = try await phone.database.jobs.create(job, actor: phone.actor, at: harness.clock.now())
        try await phone.sync()

        // Mac: Sync bringt den Wunsch, der Haushalt legt die Request-Datei an, der Tick startet den Fake-Agenten.
        let result = await runtime.performSync(reason: .manual)
        #expect((result.report?.applied ?? 0) >= 2)
        await runtime.housekeepingPass()
        #expect(harness.requestFiles(in: "docs/requests/open").count == 1)
        await runtime.jobsPass()
        #expect(harness.provider.startCount == 1)
        try await eventually { try await harness.database.workItems.fetch(item.uuid)?.status == .review }
        let finished = try #require(try await harness.database.jobs.fetch(job.jobId))
        #expect(finished.state == .finished)

        // Statuswechsel in die Datei: Request liegt danach im review-Ordner (F5).
        await runtime.jobsPass()
        await runtime.housekeepingPass()
        #expect(harness.requestFiles(in: "docs/requests/review").count == 1)
        #expect(harness.requestFiles(in: "docs/requests/open").isEmpty)

        // Ergebnis zurück aufs iPhone.
        await runtime.performSync(reason: .manual)
        try await phone.sync()
        #expect(try await phone.database.jobs.fetch(job.jobId)?.state == .finished)
        #expect(try await phone.database.workItems.fetch(item.uuid)?.status == .review)

        // Review am Mac freigeben, integrieren, erledigt → Datei im done-Ordner (M1).
        let review = try #require(try await harness.database.reviews.reviews(jobId: job.jobId).first)
        try expectResult(await runtime.handle(.approveReview(reviewId: review.reviewId)))
        // ADR-0024: die vom Dienst angelegte, nicht eingecheckte Request-Datei blockiert die Übernahme
        // nicht, und Software Regisseur committet sie auch nicht selbst.
        let mainBefore = try await harness.git.run(["rev-parse", "main"], in: harness.repo).trimmedOutput
        guard case let .result(.integration(integration)) = try expectResult(await runtime.handle(.integrateReview(reviewId: review.reviewId))) else {
            Issue.record("Integrationsergebnis erwartet")
            return
        }
        #expect(integration.strategy == "squash")
        let integrated = try await harness.git.run(["diff", "--name-only", mainBefore, "main"], in: harness.repo).lines
        #expect(!integrated.contains { $0.hasPrefix("docs/") })
        let untracked = try await harness.git.status(of: harness.repo).untrackedPaths
        #expect(untracked.contains { $0.hasPrefix("docs/requests/") })
        try expectResult(await runtime.handle(.markDone(workItemId: item.uuid)))
        #expect(try await harness.database.workItems.fetch(item.uuid)?.status == .done)
        #expect(harness.requestFiles(in: "docs/requests/done").count == 1)
        #expect(harness.requestFiles(in: "docs/requests/review").isEmpty)
    }

    // MARK: Projekteinrichtung vom iPhone (E2)

    @Test func pendingSetupCommandIsProcessed() async throws {
        let harness = try await ServiceTestHarness()
        let runtime = try await harness.makeRuntime()
        let plain = harness.developer.appending(path: "idee", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        _ = try await harness.setUp(runtime)

        // Wie vom iPhone synchronisiert: Projekt in pendingMacSetup und ein offener CreateProject-Auftrag.
        let projectId = ProjectID()
        let settings = ProjectSettings(updatedAt: t0)
        try await harness.database.projects.create(
            Project(id: projectId, name: "Idee", repositoryKind: .notARepository, status: .pendingMacSetup, settingsId: settings.id, createdAt: t0),
            settings: settings, at: t0)
        let command = ProjectSetupCommand(kind: .createProject, projectId: projectId, projectName: "Idee",
                                          target: .indexedFolder(path: plain.path(percentEncoded: false)), requestedBy: DeviceID(),
                                          createdAt: t0)
        try await harness.database.projectSetupCommands.insert(command, at: t0)

        await runtime.housekeepingPass()

        let processed = try #require(try await harness.database.projectSetupCommands.fetch(command.id))
        #expect(processed.state == .completed)
        let project = try #require(try await harness.database.projects.fetch(projectId))
        #expect(project.status == .ready)
        let runtimeHost = runtime.hostId
        #expect(try await harness.database.projects.locations(projectId: projectId).contains { $0.hostId == runtimeHost })
    }

    // MARK: Freigabe aus der Mac-UI wird an den Agenten weitergegeben (L3, J6)

    @Test func approvalDecisionIsRelayedToTheAgent() async throws {
        let harness = try await ServiceTestHarness()
        let runtime = try await harness.makeRuntime()
        let project = try await harness.setUp(runtime)
        harness.provider.enqueue(Scripts.approval("req-1"))
        let item = try await harness.addWorkItem(project)
        try expectResult(await runtime.handle(.requestJob(JobRequestCommand(workItemId: item.uuid, providerId: .codex))))
        await runtime.jobsPass()

        let approvals = harness.database.approvals
        try await eventually { !(try await approvals.openApprovals(hostId: nil)).isEmpty }
        let approval = try #require(try await approvals.openApprovals(hostId: nil).first)
        #expect(try await harness.database.workItems.fetch(item.uuid)?.status == .waitingApproval)

        try expectResult(await runtime.handle(.answerApproval(approvalId: approval.id, decision: .allow, message: nil)))
        try await eventually { try await harness.database.workItems.fetch(item.uuid)?.status == .review }
        let session = try #require(harness.provider.sessions.first)
        #expect(session.control.isCancelled == false)
        #expect(try await approvals.fetch(approval.id)?.isOpen == false)
        // Eine zweite Antwort auf dieselbe Anfrage wird abgelehnt (nie doppelt).
        guard case .failure = await runtime.handle(.answerApproval(approvalId: approval.id, decision: .deny, message: nil)) else {
            Issue.record("Zweite Antwort hätte abgelehnt werden müssen")
            return
        }
    }

    // MARK: Gekürzte Freigabe (SR-SEC-08)

    @Test func truncatedApprovalNeedsTheFullTextOnTheMacBeforeAllow() async throws {
        let harness = try await ServiceTestHarness()
        let runtime = try await harness.makeRuntime()
        let project = try await harness.setUp(runtime)
        // Der gefährliche Teil steht hinter der Kürzungsgrenze der synchronisierten Vorschau.
        let command = "echo " + String(repeating: "a", count: 2_400) + " && make deploy-production"
        harness.provider.enqueue(Scripts.approval("req-long", command: command))
        let item = try await harness.addWorkItem(project)
        try expectResult(await runtime.handle(.requestJob(JobRequestCommand(workItemId: item.uuid, providerId: .codex))))
        await runtime.jobsPass()

        let approvals = harness.database.approvals
        try await eventually { !(try await approvals.openApprovals(hostId: nil)).isEmpty }
        let approval = try #require(try await approvals.openApprovals(hostId: nil).first)
        #expect(approval.isPreviewTruncated)
        #expect(approval.allowRequiresHostReview == true)
        #expect(!approval.allowedDecisions.contains(.allow))
        #expect(approval.truncationNotice != nil)

        // Alter Befehl und Host-Befehl ohne Bestätigung: kein „Erlauben“.
        #expect(try failureMessage(await runtime.handle(.answerApproval(approvalId: approval.id, decision: .allow, message: nil)))
                .contains("gekürzt"))
        #expect(try failureMessage(await runtime.handle(.answerApprovalOnHost(approvalId: approval.id, decision: .allow, message: nil,
                                                                              fullTextConfirmed: false))).contains("gekürzt"))
        #expect(try await approvals.fetch(approval.id)?.isOpen == true)

        // Volltext nur hostlokal über XPC.
        guard case let .result(.approvalPreview(preview)) = try expectResult(await runtime.handle(.fullApprovalPreview(approvalId: approval.id))) else {
            Issue.record("approvalPreview erwartet")
            return
        }
        #expect(preview.allowRequiresHostReview)
        #expect(preview.fullText?.contains("deploy-production") == true)
        #expect((preview.fullLength ?? 0) > preview.shownLength)

        try expectResult(await runtime.handle(.answerApprovalOnHost(approvalId: approval.id, decision: .allow, message: nil,
                                                                    fullTextConfirmed: true)))
        try await eventually { try await harness.database.workItems.fetch(item.uuid)?.status == .review }
        #expect(try await approvals.fetch(approval.id)?.isOpen == false)
        #expect(try await approvals.fetch(approval.id)?.decision == .allow)
    }

    @Test func truncatedApprovalCanBeDeniedThroughTheOldCommand() async throws {
        let harness = try await ServiceTestHarness()
        let runtime = try await harness.makeRuntime()
        let project = try await harness.setUp(runtime)
        harness.provider.enqueue(Scripts.approval("req-long", command: "echo " + String(repeating: "b", count: 2_400)))
        let item = try await harness.addWorkItem(project)
        try expectResult(await runtime.handle(.requestJob(JobRequestCommand(workItemId: item.uuid, providerId: .codex))))
        await runtime.jobsPass()
        let approvals = harness.database.approvals
        try await eventually { !(try await approvals.openApprovals(hostId: nil)).isEmpty }
        let approval = try #require(try await approvals.openApprovals(hostId: nil).first)
        try expectResult(await runtime.handle(.answerApproval(approvalId: approval.id, decision: .deny, message: "Zu lang")))
        #expect(try await approvals.fetch(approval.id)?.decision == .deny)
        #expect(!FileManager.default.fileExists(atPath: try #require(harness.provider.sessions.first).control.request.workingDirectory
            .appending(path: "approved.txt").path(percentEncoded: false)))
    }

    // MARK: Statusübersicht (D1)

    @Test func statusSummaryReflectsRealState() async throws {
        let harness = try await ServiceTestHarness()
        let runtime = try await harness.makeRuntime()

        let initial = await runtime.statusSummary()
        #expect(initial.macState == .degraded)
        #expect(initial.workspace.rootFolders.isEmpty)
        #expect(initial.sync.state == .unavailable)
        #expect(initial.problems.contains { $0.contains("Stammordner") })

        let project = try await harness.setUp(runtime)
        let item = try await harness.addWorkItem(project)
        let later = harness.clock.now().addingTimeInterval(3_600)
        try expectResult(await runtime.handle(.requestJob(JobRequestCommand(
            workItemId: item.uuid, providerId: .codex, schedule: JobSchedule(kind: .notBefore(later))))))
        await runtime.jobsPass()

        guard case let .statusSummary(summary) = await runtime.handle(.statusSummary) else {
            Issue.record("Statusübersicht erwartet")
            return
        }
        #expect(summary.macState == .ready)
        #expect(summary.runState == .running)
        #expect(summary.workspace.rootFolders == [harness.developerPath])
        #expect(summary.workspace.projectsReady == 1)
        #expect(summary.queue.scheduled == 1)
        #expect(summary.queue.nextPlannedStart == later)
        #expect(summary.queue.reviewsPending == 0)
        let codex = try #require(summary.agents.first { $0.providerId == .codex })
        #expect(codex.ready)
        #expect(codex.activeJobs == 0)
        #expect(summary.activeAgentCount == 0)
        #expect(harness.provider.startCount == 0)
    }

    // MARK: Pause stoppt nur die Zulassung (D1, D3)

    @Test func pauseStopsAdmissionAndSurvivesRestart() async throws {
        let harness = try await ServiceTestHarness()
        let runtime = try await harness.makeRuntime()
        let project = try await harness.setUp(runtime)
        #expect(await runtime.handle(.pause) == .runState(.paused))

        let item = try await harness.addWorkItem(project)
        guard case let .result(.job(job)) = try expectResult(await runtime.handle(.requestJob(JobRequestCommand(
            workItemId: item.uuid, providerId: .codex)))) else {
            Issue.record("Job erwartet")
            return
        }
        await runtime.jobsPass()
        await runtime.jobsPass()
        #expect(harness.provider.startCount == 0)
        #expect(try await harness.database.jobs.fetch(job.jobId)?.state == .scheduled)
        let paused = await runtime.statusSummary()
        #expect(paused.macState == .paused)
        let hostId = runtime.hostId
        #expect(try await harness.database.capabilities.host(hostId)?.ready == false)

        // Neustart: Pause bleibt erhalten (host_state).
        let restarted = try await harness.makeRuntime()
        #expect(await restarted.runState == .paused)

        #expect(await restarted.handle(.resume) == .runState(.running))
        await restarted.jobsPass()
        #expect(harness.provider.startCount == 1)
        try await eventually { try await harness.database.workItems.fetch(item.uuid)?.status == .review }
    }

    // MARK: Wiederherstellung nach Absturz (D3)

    @Test func recoveryAtStartHandlesInterruptedRun() async throws {
        let harness = try await ServiceTestHarness()
        let runtime = try await harness.makeRuntime()
        let project = try await harness.setUp(runtime)
        harness.provider.enqueue(Scripts.hang())
        let item = try await harness.addWorkItem(project)
        guard case let .result(.job(job)) = try expectResult(await runtime.handle(.requestJob(JobRequestCommand(
            workItemId: item.uuid, providerId: .codex)))) else {
            Issue.record("Job erwartet")
            return
        }
        await runtime.jobsPass()
        try await eventually { try await harness.database.jobs.fetch(job.jobId)?.state == .running }
        #expect(try await harness.database.locks.activeLock(forTask: item.uuid) != nil)

        // „Absturz“: neuer Dienstprozess auf derselben Datenbank, der alte Agentenprozess existiert nicht mehr.
        let restarted = try await harness.makeRuntime()
        let report = try #require(await restarted.recoveryReport)
        #expect(report.actions[job.jobId] == .failed(preservedWorktree: true))
        #expect(try await harness.database.jobs.fetch(job.jobId)?.state == .failed)
        #expect(try await harness.database.locks.activeLock(forTask: item.uuid) == nil)
        #expect(harness.provider.startCount == 1) // kein stiller Doppelstart
        harness.provider.sessions.first?.control.cancel()
    }

    // MARK: KI-Ausarbeitung mit Repo-Kontext (H4, A11)

    @Test func macAIElaborationCreatesDraftVersionWithManifest() async throws {
        let harness = try await ServiceTestHarness()
        let runtime = try await harness.makeRuntime()
        let project = try await harness.setUp(runtime)
        let item = try await harness.addWorkItem(project)

        guard case let .result(.macAIElaboration(started)) = try expectResult(await runtime.handle(.requestMacAIElaboration(
            MacAIElaborationCommand(workItemId: item.uuid, providerId: "openai", modelId: "gpt-test", selectedFiles: [".env", "README.md"])))) else {
            Issue.record("Ausarbeitung erwartet")
            return
        }
        var info = started
        try await eventually {
            guard case let .result(.macAIElaboration(current)) = await runtime.handle(.macAIElaborationStatus(requestId: started.requestId))
            else { return false }
            info = current
            return current.state == .completed || current.state == .failed
        }
        #expect(info.state == .completed, "\(info.errorMessage ?? "")")
        #expect(info.draftVersion != nil)
        #expect(info.excluded.contains { $0.path == ".env" })
        #expect(info.included.contains { $0.path == "README.md" })
        let versions = try await harness.database.draftVersions.versions(workItemId: item.uuid)
        #expect(versions.contains { $0.source == .ai && $0.contents.first?.title == "Export als CSV" })
        // Kein Geheimnis im Prompt (Q1).
        let prompt = harness.textProvider.received.map { "\($0)" }.joined()
        #expect(!prompt.contains("sk-geheim"))
        let request = try #require(try await harness.database.aiRecords.request(started.requestId))
        #expect(request.state == .completed)
        let events = try await harness.database.events.events(forWorkItem: item.uuid)
        #expect(events.contains { $0.payload["type"] == ServiceRuntime.aiEventType && $0.payload["state"] == "completed" })
    }

    @Test func aiElaborationWithoutKeyFailsReadablyInGerman() async throws {
        let harness = try await ServiceTestHarness(apiKey: false)
        let runtime = try await harness.makeRuntime()
        let project = try await harness.setUp(runtime)
        let item = try await harness.addWorkItem(project)
        // Wie vom iPhone eingereiht.
        let request = AIRequest(itemId: item.uuid, provider: .openAI, model: "gpt-test", mode: .withRepositoryContext,
                                inputVersion: item.revision, state: .pending, createdAt: t0)
        try await harness.database.aiRecords.saveRequest(request, at: t0)

        await runtime.housekeepingPass()

        #expect(try await harness.database.aiRecords.request(request.id)?.state == .failed)
        guard case let .result(.macAIElaboration(info)) = await runtime.handle(.macAIElaborationStatus(requestId: request.id)) else {
            Issue.record("Status erwartet")
            return
        }
        let message = try #require(info.errorMessage)
        #expect(message.contains("Schlüssel") || message.contains("API"))
        #expect(!info.included.isEmpty) // Manifest auch bei Fehler nachvollziehbar
    }

    // MARK: Stammordner (E1, L2)

    @Test func rootFoldersAreConfirmedNeverAutoScanned() async throws {
        let harness = try await ServiceTestHarness()
        let runtime = try await harness.makeRuntime()
        guard case let .result(.rootFolders(state)) = await runtime.handle(.rootFolders) else {
            Issue.record("Stammordner erwartet")
            return
        }
        #expect(state.folders.isEmpty)
        #expect(state.suggestion == harness.developerPath)
        #expect(await runtime.handle(.refreshScanner) == .notAvailable(.repositoryScanner))
        #expect(try await harness.database.projects.list().isEmpty)

        // Ein Stammordner, der die Dienstablage (Worktrees) enthält, wird abgelehnt.
        guard case .failure = await runtime.handle(.addRootFolder(path: harness.root.path(percentEncoded: false))) else {
            Issue.record("Überlappung hätte abgelehnt werden müssen")
            return
        }
        guard case .failure = await runtime.handle(.addRootFolder(path: "relativ/pfad")) else {
            Issue.record("Relativer Pfad hätte abgelehnt werden müssen")
            return
        }
        try expectResult(await runtime.handle(.addRootFolder(path: harness.developer.path(percentEncoded: false) + "/")))
        guard case let .result(.rootFolders(after)) = await runtime.handle(.removeRootFolder(path: harness.developer.path(percentEncoded: false))) else {
            Issue.record("Stammordner erwartet")
            return
        }
        #expect(after.folders.isEmpty)
    }

    // MARK: Anweisungsdateien nur nach Freigabe (G)

    @Test func instructionProposalIsOnlyWrittenAfterApproval() async throws {
        let harness = try await ServiceTestHarness()
        let runtime = try await harness.makeRuntime()
        _ = try await harness.setUp(runtime)
        let agents = harness.repo.appending(path: "AGENTS.md")
        #expect(!FileManager.default.fileExists(atPath: agents.path(percentEncoded: false)))

        guard case let .result(.instructionProposals(proposals)) = await runtime.handle(.instructionProposals(projectId: nil)),
              let proposal = proposals.first else {
            Issue.record("Vorschlag erwartet")
            return
        }
        #expect(proposal.changes.contains { $0.path == "AGENTS.md" && $0.isNewFile })
        #expect(!FileManager.default.fileExists(atPath: agents.path(percentEncoded: false)))

        try expectResult(await runtime.handle(.applyInstructionProposal(proposalId: proposal.id)))
        let text = try String(contentsOf: agents, encoding: .utf8)
        #expect(text.contains("SOFTWARE-REGISSEUR:BEGIN"))
        guard case .failure = await runtime.handle(.applyInstructionProposal(proposalId: proposal.id)) else {
            Issue.record("Zweites Anwenden hätte scheitern müssen")
            return
        }
    }
}
