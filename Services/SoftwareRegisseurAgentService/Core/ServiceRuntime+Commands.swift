import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurGit
import SoftwareRegisseurIPC
import SoftwareRegisseurJobs
import SoftwareRegisseurPersistence
import SoftwareRegisseurSync
import SoftwareRegisseurWorkspace

/// Ausführung der XPC-Befehle der Mac-UI. Jede Entscheidung läuft als `EventActor.user` dieses Macs.
extension ServiceRuntime {
    func handle(_ request: ServiceRequest) async -> ServiceResponse {
        guard !isShutDownForDeletion else { return .failure(ServiceErrorText.message(for: ServiceError.shutDownForDeletion)) }
        do {
            return try await perform(request)
        } catch {
            let message = ServiceErrorText.message(for: error)
            ServiceLog.ipc.error("Befehl \(Self.name(of: request), privacy: .public) abgelehnt: \(message, privacy: .private)")
            return .failure(message)
        }
    }

    static func name(of request: ServiceRequest) -> String {
        String(String(describing: request).prefix { $0 != "(" })
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func perform(_ request: ServiceRequest) async throws -> ServiceResponse {
        switch request {
        // Dienst
        case .ping:
            return .pong(deps.version)
        case .health:
            return .health(health())
        case .statusSummary:
            return .statusSummary(await statusSummary())
        case .pause:
            return .runState(try await setRunState(.paused))
        case .resume:
            return .runState(try await setRunState(.running))
        case .stop:
            // Wird von `AgentServiceCore` behandelt (Prozessende); hier nur der Vollständigkeit halber.
            return .stopping
        case .serviceSettings:
            return .result(.serviceSettings(settings))
        case let .updateServiceSettings(new):
            return .result(.serviceSettings(try await updateSettings(new)))

        // Sync
        case .syncNow:
            guard coordinator != nil else { return .notAvailable(.cloudSync) }
            return .result(.syncFinished(Self.info(await performSync(reason: .manual))))
        case let .resolveSyncConflict(conflictId, choice):
            guard let coordinator else { return .notAvailable(.cloudSync) }
            let resolution: ConflictResolution = switch choice {
            case .keepLocal: .keepLocal
            case .acceptRemote: .acceptRemote
            case let .merged(data): .merged(data)
            }
            try await coordinator.resolveConflict(conflictId, resolution: resolution)
            sendSoon()
            return .result(.done("Konflikt entschieden."))
        case let .acknowledgeAccountChange(uploadAll):
            guard let coordinator else { return .notAvailable(.cloudSync) }
            try await coordinator.acknowledgeAccountChange(uploadAllLocalData: uploadAll)
            await poller?.resume()
            return .result(.syncFinished(Self.info(await performSync(reason: .manual))))
        case .recreateCloudZone:
            guard let coordinator else { return .notAvailable(.cloudSync) }
            await coordinator.recreateZoneAndResume()
            await poller?.resume()
            return .result(.syncFinished(Self.info(await performSync(reason: .manual))))

        // Stammordner, Scanner, Projekte
        case .refreshScanner:
            guard !rootFolders.isEmpty else { return .notAvailable(.repositoryScanner) }
            return .result(.scanFinished(try await scan()))
        case .rootFolders:
            return .result(.rootFolders(rootFolderState()))
        case let .addRootFolder(path):
            return .result(.rootFolders(try await addRootFolder(path)))
        case let .removeRootFolder(path):
            return .result(.rootFolders(try await removeRootFolder(path)))
        case let .relinkCandidates(projectId):
            return .result(.paths(try await catalog.relinkCandidates(projectId: projectId).map(\.canonicalPath)))
        case let .relinkProject(projectId, path, allowDifferent):
            _ = try await catalog.relink(projectId: projectId, to: URL(filePath: path, directoryHint: .isDirectory),
                                         allowDifferentRepository: allowDifferent)
            await refreshWatchedProjects()
            await repositorySync.reconcile(projectId: projectId)
            sendSoon()
            return .result(.done("Projekt neu verknüpft."))
        case let .reconcileProject(projectId):
            let result = await repositorySync.reconcile(projectId: projectId)
            if let error = result.error { return .failure(ServiceLog.redact(error)) }
            sendSoon()
            return .result(.done(nil))
        case let .submitProjectSetup(command):
            try await setupService.submit(command)
            let executed = try await setupService.execute(command.id)
            await refreshWatchedProjects()
            if executed.state == .completed {
                await refreshInstructionProposals(for: [executed.projectId])
                await repositorySync.reconcile(projectId: executed.projectId)
            }
            sendSoon()
            if let failure = executed.failure { return .failure(failure.message) }
            return .result(.done("Projekt eingerichtet."))
        case let .resolveFileConflict(conflictId, resolution):
            guard let conflict = try await database.fileConflicts.fetch(conflictId) else { throw WorkspaceError.conflictNotFound(conflictId) }
            if conflict.kind == .gitHubDivergence {
                if resolution == .dismissed {
                    _ = try await database.fileConflicts.resolve(conflictId, resolution: .dismissed, at: clock.now())
                } else {
                    try await gitHub.resolveDivergence(conflictId, acceptGitHub: resolution == .acceptedExternal)
                }
            } else {
                let report = try await repositorySync.materializer.resolveConflict(conflictId, resolution: resolution)
                if let error = report.errors.first { return .failure(ServiceLog.redact(error)) }
            }
            sendSoon()
            return .result(.done("Konflikt gelöst."))

        // Anweisungsdateien
        case let .instructionProposals(projectId):
            return .result(.instructionProposals(await proposalInfos(projectId: projectId)))
        case let .proposeInstructions(projectId, createClaude):
            await refreshInstructionProposals(for: [projectId], createClaudeFileIfMissing: createClaude)
            return .result(.instructionProposals(await proposalInfos(projectId: projectId)))
        case let .applyInstructionProposal(proposalId):
            guard let entry = proposals.first(where: { $0.value.id == proposalId }) else { throw ServiceError.proposalNotFound(proposalId) }
            proposals[entry.key] = nil
            let result = try await instructions.apply(proposalId, approvedBy: userActor)
            ServiceLog.workspace.notice("Anweisungsdateien geschrieben: \(result.writtenFiles.count, privacy: .public)")
            let warnings = result.warnings.map(\.description)
            return .result(.done(warnings.isEmpty ? "Anweisungsdateien aktualisiert." : warnings.joined(separator: " ")))
        case let .rejectInstructionProposal(proposalId):
            guard let entry = proposals.first(where: { $0.value.id == proposalId }) else { throw ServiceError.proposalNotFound(proposalId) }
            proposals[entry.key] = nil
            await instructions.discard(proposalId)
            return .result(.done(nil))

        // Ordnerstruktur
        case let .previewFolderMigration(projectId, layout):
            return .result(.folderMigrationPlan(try await previewMigration(projectId: projectId, layout: layout)))
        case let .applyFolderMigration(planId):
            guard migrationPlans[planId] != nil else { throw ServiceError.migrationPlanNotFound(planId) }
            migrationPlans[planId] = nil
            let result = try await migrator.apply(planId, approved: true, approvedBy: userActor)
            needsFullReconcile = true
            housekeepingSignal.signal()
            sendSoon()
            return .result(.done("\(result.movedFiles.count) Datei(en) verschoben\(result.updatedInstructions ? ", AGENTS.md aktualisiert" : "")."))
        case let .discardFolderMigration(planId):
            guard migrationPlans.removeValue(forKey: planId) != nil else { throw ServiceError.migrationPlanNotFound(planId) }
            _ = try? await migrator.apply(planId, approved: false, approvedBy: userActor)
            return .result(.done(nil))

        // Agenten
        case .redetectAgents:
            _ = await detectAgents()
            return .result(.agents(await statusSummary().agents))

        // Jobs
        case let .requestJob(command):
            let orchestrator = try requireOrchestrator()
            let override = (command.model != nil || command.effort != nil)
                ? JobConfigurationOverride(providerId: command.providerId, model: command.model, effort: command.effort) : nil
            let result = try await orchestrator.requestJob(
                workItemId: command.workItemId, providerId: command.providerId, override: override, schedule: command.schedule,
                priority: command.priority, idempotencyKey: command.idempotencyKey, by: userActor)
            jobsSignal.signal()
            sendSoon()
            return .result(.job(Self.info(result.job, created: result.wasCreated)))
        case let .jobStatus(jobId):
            return .result(.jobStatus(try await jobStatus(jobId)))
        case let .fullApprovalPreview(approvalId):
            return .result(.approvalPreview(try await fullApprovalPreview(approvalId)))
        case let .answerApprovalOnHost(approvalId, decision, message, fullTextConfirmed):
            try await answerApprovalOnHost(approvalId, decision: decision, message: message, fullTextConfirmed: fullTextConfirmed)
            return .result(.done(decision == .allow ? "Freigabe erteilt und an den Agenten weitergegeben."
                                 : "Freigabe abgelehnt und an den Agenten weitergegeben."))
        case let .answerApproval(approvalId, decision, message):
            try await answerApproval(approvalId, decision: decision, message: message)
            return .result(.done("Entscheidung an den Agenten übermittelt."))
        case let .cancelJob(jobId):
            return try await jobAction { try await $0.cancel(jobId: jobId, by: self.userActor) }
        case let .pauseJob(jobId):
            return try await jobAction { try await $0.pause(jobId: jobId, by: self.userActor) }
        case let .resumeJob(jobId):
            return try await jobAction { try await $0.resume(jobId: jobId, by: self.userActor) }
        case let .retryJob(jobId, key):
            let result = try await requireOrchestrator().retry(jobId: jobId, idempotencyKey: key, by: userActor)
            jobsSignal.signal()
            sendSoon()
            return .result(.job(Self.info(result.job, created: result.wasCreated)))
        case let .reprioritizeJob(jobId, priority):
            return try await jobAction { try await $0.reprioritize(jobId: jobId, to: priority, by: self.userActor) }
        case let .replaceJobConfiguration(jobId, model, effort):
            let snapshot = try await resolveSnapshot(jobId: jobId, model: model, effort: effort)
            return try await jobAction { try await $0.replaceConfiguration(jobId: jobId, with: snapshot, by: self.userActor) }
        case let .resolveMissedRun(jobId, runNow):
            return try await jobAction { try await $0.resolveMissedRun(jobId: jobId, runNow: runNow, by: self.userActor) }
        case let .setExpectedQuotaReset(jobId, date):
            return try await jobAction { try await $0.setExpectedQuotaReset(jobId: jobId, at: date, by: self.userActor) }
        case let .terminateOrphanedProcess(jobId):
            let terminated = try await requireOrchestrator().terminateOrphanedProcess(jobId: jobId, by: userActor)
            jobsSignal.signal()
            return .result(.done(terminated ? "Agentenprozess beendet." : "Der Prozess lief nicht mehr."))
        case let .removeWorktree(jobId):
            try await requireOrchestrator().removeWorktree(jobId: jobId, by: userActor)
            return .result(.done("Worktree entfernt."))

        // Review
        case let .reviewDetails(reviewId):
            guard let details = await (try requireOrchestrator()).reviewDetails(reviewId) else { throw ServiceError.reviewDetailsUnavailable(reviewId) }
            return .result(.reviewDetails(Self.info(details)))
        case let .approveReview(reviewId):
            try await requireOrchestrator().approveReview(reviewId, by: userActor)
            return reviewChanged("Review freigegeben.")
        case let .requestChanges(reviewId):
            try await requireOrchestrator().requestChanges(reviewId, by: userActor)
            return reviewChanged("Änderungen angefordert.")
        case let .rejectReview(reviewId):
            try await requireOrchestrator().rejectReview(reviewId, by: userActor)
            return reviewChanged("Review abgelehnt.")
        case let .integrateReview(reviewId):
            let result = try await requireOrchestrator().integrate(reviewId: reviewId, approvedBy: userActor)
            _ = reviewChanged(nil)
            return .result(.integration(IntegrationInfo(
                strategy: result.strategy.rawValue, commitSHA: result.commitSHA,
                previousDefaultBranchCommit: result.previousDefaultBranchCommit, integratedCommits: result.integratedCommits)))
        case let .markDone(workItemId):
            _ = try await requireOrchestrator().markDone(workItemId: workItemId, approvedBy: userActor)
            // Die Datei wandert sofort in den done-Ordner (M1 Schritt 6).
            await materializeChanges()
            sendSoon()
            return .result(.done("Als erledigt markiert."))

        // GitHub
        case .gitHubAvailability:
            let availability = await currentGitHubAvailability(force: true)
            return .result(.gitHubAvailability(Self.info(availability)))
        case let .setGitHubEnabled(projectId, enabled):
            try await gitHub.setEnabled(enabled, projectId: projectId)
            if enabled { gitHubSignal.signal() }
            return .result(.done(nil))
        case let .gitHubIssues(projectId, state):
            try await requireGitHub()
            let repo = try await gitHub.repository(for: projectId)
            let issues = try await gitHub.listIssues(repo: repo, state: state.rawValue)
            let links = (try? await database.reviews.issueLinks(repo: repo)) ?? []
            return .result(.gitHubIssues(issues.map { issue in
                GitHubIssueInfo(number: issue.number, title: issue.title, state: issue.state, url: issue.url, updatedAt: issue.updatedAt,
                                labels: issue.labels.map(\.name),
                                linkedWorkItemId: links.first { $0.issueNumber == issue.number }?.workItemId)
            }))
        case let .linkGitHubIssue(workItemId, number):
            try await requireGitHub()
            _ = try await gitHub.link(workItemId: workItemId, issueNumber: number)
            sendSoon()
            return .result(.done("Issue #\(number) verknüpft."))
        case let .importGitHubIssue(projectId, number):
            try await requireGitHub()
            let item = try await gitHub.importIssue(number, projectId: projectId)
            await repositorySync.reconcile(projectId: projectId)
            sendSoon()
            return .result(.workItem(item.uuid))
        case let .exportToGitHub(workItemId):
            try await requireGitHub()
            let link = try await gitHub.export(workItemId: workItemId)
            sendSoon()
            return .result(.done("Als Issue #\(link.issueNumber) angelegt."))
        case let .resolveGitHubDivergence(conflictId, acceptGitHub):
            try await requireGitHub()
            try await gitHub.resolveDivergence(conflictId, acceptGitHub: acceptGitHub)
            housekeepingSignal.signal()
            sendSoon()
            return .result(.done("Abweichung aufgelöst."))
        case let .syncGitHub(projectId):
            try await requireGitHub()
            await gitHubPass(projectId: projectId)
            return .result(.done("GitHub-Abgleich abgeschlossen."))

        // KI
        case let .requestMacAIElaboration(command):
            return .result(.macAIElaboration(try await requestMacAIElaboration(command)))
        case let .macAIElaborationStatus(requestId):
            return .result(.macAIElaboration(try await macAIElaborationStatus(requestId)))

        // Aufgaben (Protokoll 3)
        case let .createWorkItem(command):
            return .result(.workItemSaved(try await createWorkItem(command)))
        case let .updateWorkItem(command):
            return .result(.workItemSaved(try await updateWorkItem(command)))
        case let .changeWorkItemStatus(workItemId, expectedRevision, status):
            return .result(.workItemSaved(try await changeWorkItemStatus(workItemId, expectedRevision: expectedRevision, to: status)))
        case let .assignWorkItem(workItemId, expectedRevision, projectId):
            return .result(.workItemSaved(try await assignWorkItem(workItemId, expectedRevision: expectedRevision, to: projectId)))
        case let .setWorkItemArchived(workItemId, expectedRevision, archived):
            return .result(.workItemSaved(try await setWorkItemArchived(workItemId, expectedRevision: expectedRevision, archived: archived)))
        case let .reclassifyWorkItem(workItemId, expectedRevision, type):
            return .result(.workItemSaved(try await reclassifyWorkItem(workItemId, expectedRevision: expectedRevision, to: type)))
        case let .duplicateWorkItem(workItemId, newWorkItemId):
            return .result(.workItemSaved(try await duplicateWorkItem(workItemId, newId: newWorkItemId)))
        case let .deleteWorkItem(workItemId, expectedRevision):
            try await deleteWorkItem(workItemId, expectedRevision: expectedRevision)
            return .result(.done("Aufgabe endgültig gelöscht."))

        // KI-Entwürfe (Protokoll 3)
        case let .acceptDraftVersion(draftId, contentIndex, expectedRevision):
            return .result(.workItemSaved(try await acceptDraft(draftId, contentIndex: contentIndex, expectedRevision: expectedRevision)))
        case let .rejectDraftVersion(draftId):
            try await rejectDraft(draftId)
            return .result(.done("Entwurf verworfen; die Aufgabe bleibt unverändert."))

        // „Mit KI besprechen“ (Protokoll 4)
        case let .saveConversation(conversation):
            return .result(.conversationSaved(try await saveConversation(conversation)))
        case let .appendConversationDraft(command):
            return .result(.conversationDraft(try await appendConversationDraft(command)))

        // ADRs (Protokoll 3)
        case let .createADR(command):
            return .result(.adrCreated(try await createADR(command)))
        case let .changeADRStatus(adrId, expectedRevision, status, supersededBy):
            return .result(.done(try await changeADRStatus(adrId, expectedRevision: expectedRevision, to: status, supersededBy: supersededBy)))

        // Einstellungen (Protokoll 3)
        case let .updateProjectSettings(command):
            try await updateProjectSettings(command)
            return .result(.done("Projekteinstellungen gespeichert. Sie gelten für neue Jobs."))
        case let .gitHubProjectState(projectId):
            return .result(.gitHubProjectState(try await gitHubProjectState(projectId)))
        case let .updateGlobalSettings(command):
            try await updateGlobalSettings(command)
            return .result(.done("Globale Standards gespeichert."))
        case let .setGlobalModelPreference(choice):
            try await setGlobalModelPreference(choice)
            return .result(.done(choice.inherits ? "Globale Modellwahl entfernt (Anbieterstandard)." : "Globale Modellwahl gespeichert."))
        case let .setAgentExecutablePath(providerId, path):
            return .result(.serviceSettings(try await setAgentExecutablePath(providerId, path: path)))

        // Datenlöschung (Protokoll 3)
        case let .prepareLocalDeletion(kind):
            return .result(.localDeletionPreview(try await prepareLocalDeletion(kind)))
        case let .executeLocalDeletion(planId, token):
            return .result(.localDeletionReport(try await executeLocalDeletion(planId: planId, token: token)))
        case .prepareCloudDeletion:
            guard coordinator != nil else { return .notAvailable(.cloudSync) }
            return .result(.cloudDeletionPreview(await prepareCloudDeletion()))
        case let .confirmCloudDeletion(planId, token):
            guard let coordinator else { return .notAvailable(.cloudSync) }
            try await confirmCloudDeletion(planId: planId, token: token, coordinator: coordinator)
            return .result(.done("iCloud-Daten gelöscht. Die Synchronisierung bleibt pausiert, bis Sie „Wieder mit iCloud synchronisieren“ wählen."))
        case .retryCloudDeletion:
            guard let coordinator else { return .notAvailable(.cloudSync) }
            try await retryCloudDeletion(coordinator: coordinator)
            return .result(.done("iCloud-Daten gelöscht. Die Synchronisierung bleibt pausiert."))
        }
    }

    // MARK: Einstellungen

    private func updateSettings(_ new: ServiceSettings) async throws -> ServiceSettings {
        var clamped = new.clamped
        // Programmpfade ändert nur `setAgentExecutablePath` (Prüfung + Neuerkennung).
        clamped.agentExecutablePaths = settings.agentExecutablePaths
        let pollChanged = clamped.syncPollInterval != settings.syncPollInterval || clamped.syncMaxBackoff != settings.syncMaxBackoff
        let reconcileChanged = clamped.reconcileInterval != settings.reconcileInterval
        try await stateStore.saveSettings(clamped)
        settings = clamped
        if pollChanged, let poller {
            await poller.stop()
            self.poller = nil
            startPoller()
        }
        if reconcileChanged, !loops.isEmpty {
            try? await repositorySync.start(reconcileInterval: .seconds(clamped.reconcileInterval))
        }
        jobsSignal.signal()
        scanSignal.signal()
        return clamped
    }

    // MARK: Stammordner (E1)

    func rootFolderState() -> RootFolderState {
        let folders = rootFolders.map {
            RootFolderState.Folder(path: $0.path, exists: Self.isDirectory($0.path), addedAt: $0.addedAt)
        }
        let developer = deps.homeDirectory.appending(path: "Developer", directoryHint: .isDirectory)
        let suggestionPath = (try? PathGuard.canonicalize(developer))?.path(percentEncoded: false).trimmingTrailingSlash
        let suggestion = suggestionPath.flatMap { path in
            Self.isDirectory(path) && !rootFolders.contains { $0.path == path } ? path : nil
        }
        return RootFolderState(folders: folders, suggestion: suggestion)
    }

    func addRootFolder(_ rawPath: String) async throws -> RootFolderState {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { throw ServiceError.invalidPath(trimmed) }
        guard Self.isDirectory(trimmed) else { throw ServiceError.rootFolderMissing(trimmed) }
        let canonical: String
        do {
            canonical = try PathGuard.canonicalize(URL(filePath: trimmed, directoryHint: .isDirectory)).path(percentEncoded: false).trimmingTrailingSlash
        } catch {
            throw ServiceError.invalidPath(trimmed)
        }
        let storage = (try? PathGuard.canonicalize(deps.storage.rootURL))?.path(percentEncoded: false).trimmingTrailingSlash
            ?? deps.storage.rootURL.path(percentEncoded: false).trimmingTrailingSlash
        // L2: Worktrees liegen außerhalb jedes Stammordners; ein Stammordner darf die Dienstablage nicht enthalten.
        if canonical == "/" || storage == canonical || storage.hasPrefix(canonical + "/") || canonical.hasPrefix(storage + "/") {
            throw ServiceError.rootFolderOverlapsServiceStorage(canonical)
        }
        guard !rootFolders.contains(where: { $0.path == canonical }) else { return rootFolderState() }
        rootFolders.append(.init(path: canonical, addedAt: clock.now()))
        try await stateStore.saveRootFolders(rootFolders)
        await catalog.configure(Self.catalogConfiguration(roots: rootFolders, storage: deps.storage, scanDepth: settings.folderScanDepth))
        ServiceLog.workspace.notice("Stammordner bestätigt (\(self.rootFolders.count, privacy: .public) insgesamt)")
        scanSignal.signal()
        return rootFolderState()
    }

    func removeRootFolder(_ rawPath: String) async throws -> RootFolderState {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines).trimmingTrailingSlash
        let canonical = (try? PathGuard.canonicalize(URL(filePath: trimmed, directoryHint: .isDirectory)))?
            .path(percentEncoded: false).trimmingTrailingSlash
        guard let index = rootFolders.firstIndex(where: { $0.path == trimmed || $0.path == canonical }) else {
            throw ServiceError.rootFolderUnknown(trimmed)
        }
        rootFolders.remove(at: index)
        try await stateStore.saveRootFolders(rootFolders)
        await catalog.configure(Self.catalogConfiguration(roots: rootFolders, storage: deps.storage, scanDepth: settings.folderScanDepth))
        // Projekte und Aufgaben bleiben; nur noch nicht verknüpfte Ordner verschwinden beim nächsten Scan.
        if !rootFolders.isEmpty { scanSignal.signal() }
        return rootFolderState()
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: Vorschläge und Migration

    private func proposalInfos(projectId: ProjectID?) async -> [InstructionProposalInfo] {
        var infos: [InstructionProposalInfo] = []
        for (id, proposal) in proposals where projectId == nil || id == projectId {
            let name = (try? await database.projects.fetch(id))?.name ?? ""
            infos.append(InstructionProposalInfo(
                id: proposal.id, projectId: id, projectName: name,
                changes: proposal.changes.map {
                    .init(path: $0.path, isNewFile: $0.originalText == nil, proposedText: $0.proposedText, unifiedDiff: $0.unifiedDiff)
                },
                warnings: proposal.warnings.map(\.description), createdAt: proposal.createdAt))
        }
        return infos.sorted { $0.projectName.localizedStandardCompare($1.projectName) == .orderedAscending }
    }

    private func previewMigration(projectId: ProjectID, layout: FolderLayoutPaths) async throws -> FolderMigrationPlanInfo {
        var settings = try await environment.settings(projectId)
        settings.adrPath = layout.adrPath
        settings.requestsRoot = layout.requestsRoot
        settings.openPath = layout.openPath
        settings.activePath = layout.activePath
        settings.reviewPath = layout.reviewPath
        settings.donePath = layout.donePath
        let plan = try await migrator.preview(projectId: projectId, newSettings: settings)
        migrationPlans[plan.id] = projectId
        return FolderMigrationPlanInfo(
            planId: plan.id, projectId: projectId, layout: layout,
            moves: plan.moves.map { .init(kind: $0.kind.rawValue, source: $0.source, destination: $0.destination) },
            collisions: plan.collisions.map { .init(destination: $0.destination, sources: $0.sources, reason: $0.reason.rawValue) },
            instructionsDiff: plan.instructionsDiff, isApplicable: plan.isApplicable)
    }

    // MARK: Jobs

    func requireOrchestrator() throws -> JobOrchestrator {
        guard let orchestrator else { throw ServiceError.gitUnavailable }
        return orchestrator
    }

    private func requireGitHub() async throws {
        let availability = await currentGitHubAvailability(force: false)
        if case let .unavailable(reason) = availability { throw ServiceError.gitHubUnavailable(reason.description) }
    }

    private func jobAction(_ action: @Sendable (JobOrchestrator) async throws -> AgentJob) async throws -> ServiceResponse {
        let job = try await action(try requireOrchestrator())
        jobsSignal.signal()
        housekeepingSignal.signal()
        sendSoon()
        return .result(.job(Self.info(job, created: false)))
    }

    private func reviewChanged(_ message: String?) -> ServiceResponse {
        housekeepingSignal.signal()
        sendSoon()
        return .result(.done(message))
    }

    /// Freigabe aus der Mac-UI: als synchronisierte Entscheidung ablegen und sofort weitergeben, auf
    /// genau demselben Weg wie eine iPhone-Entscheidung (L3, J6). Nie automatisch.
    func answerApproval(_ approvalId: PendingApprovalID, decision: ApprovalDecisionKind, message: String?) async throws {
        guard let approval = try await database.approvals.fetch(approvalId) else { throw ServiceError.approvalNotFound(approvalId) }
        let now = clock.now()
        guard approval.isOpen, !approval.isExpired(at: now) else { throw ServiceError.approvalClosed }
        // SR-SEC-08: gekürzte Vorschau → nur über den Host-Weg; ohne bestätigten Volltext kein „Erlauben“.
        if approval.allowRequiresHostReview == true {
            try await answerApprovalOnHost(approvalId, decision: decision, message: message, fullTextConfirmed: false)
            return
        }
        guard approval.allowedDecisions.isEmpty || approval.allowedDecisions.contains(decision) else {
            throw ServiceError.decisionNotAllowed(decision)
        }
        let record = ApprovalDecision(for: approval, decision: decision, decidedBy: deviceId, at: now, message: message)
        try await database.approvals.recordDecision(record)
        await jobsPass()
        jobsSignal.signal()
    }

    /// Vollständiger Text einer gekürzten Vorschau (SR-SEC-08); nur hostlokal aus der laufenden Sitzung.
    func fullApprovalPreview(_ approvalId: PendingApprovalID) async throws -> ApprovalPreviewInfo {
        guard let approval = try await database.approvals.fetch(approvalId) else { throw ServiceError.approvalNotFound(approvalId) }
        let full = await orchestrator?.fullApprovalPreview(approvalId)
        let shown = approval.preview?.count ?? 0
        let text = full ?? (approval.isPreviewTruncated ? nil : approval.preview)
        return ApprovalPreviewInfo(
            approvalId: approvalId, fullText: text, shownLength: shown, fullLength: approval.previewFullLength,
            allowRequiresHostReview: approval.allowRequiresHostReview == true,
            detail: text == nil ? "Der vollständige Text liegt nur vor, solange die Agentensitzung auf diesem Mac läuft. Ohne ihn ist nur Ablehnen möglich." : nil)
    }

    /// Entscheidung am ausführenden Mac (SR-SEC-08). Bei gekürzter Vorschau ist „Erlauben“ nur möglich, wenn die UI
    /// den Volltext angezeigt und der Benutzer das Lesen bestätigt hat; der Orchestrator prüft das zusätzlich.
    func answerApprovalOnHost(_ approvalId: PendingApprovalID, decision: ApprovalDecisionKind, message: String?,
                              fullTextConfirmed: Bool) async throws {
        guard let approval = try await database.approvals.fetch(approvalId) else { throw ServiceError.approvalNotFound(approvalId) }
        guard approval.isOpen, !approval.isExpired(at: clock.now()) else { throw ServiceError.approvalClosed }
        if decision == .allow, approval.allowRequiresHostReview == true, !approval.allowedDecisions.contains(.allow), !fullTextConfirmed {
            throw ServiceError.approvalNeedsFullText
        }
        try await requireOrchestrator().answerApprovalOnHost(approvalId, decision: decision, message: message,
                                                             fullTextConfirmed: fullTextConfirmed, by: userActor)
        jobsSignal.signal()
        sendSoon()
    }

    private func resolveSnapshot(jobId: JobID, model: ModelSelection?, effort: EffortLevel?) async throws -> ConfigurationSnapshot {
        guard let job = try await database.jobs.fetch(jobId) else { throw ServiceError.jobNotFound(jobId) }
        guard let project = try await database.projects.fetch(job.projectId) else { throw ServiceError.projectNotFound(job.projectId) }
        guard let capability = try await database.capabilities.capability(hostId: project.hostId ?? hostId, providerId: job.providerId) else {
            throw ServiceError.capabilityUnknown(job.providerId)
        }
        let settings = try await database.projects.settings(forProject: project.id)
        let projectPreference = try await database.preferences.preference(scope: .project(project.id), providerId: job.providerId)
            ?? settings?.modelPreference(for: job.providerId)
        let globalPreference = try await database.preferences.preference(scope: .global, providerId: job.providerId)
        let resolution = ModelEffortResolver.resolve(
            jobOverride: JobConfigurationOverride(providerId: job.providerId, model: model, effort: effort),
            projectPreference: projectPreference, globalPreference: globalPreference, capability: capability)
        guard let configuration = resolution.configuration else { throw ServiceError.configurationInvalid(resolution.issues) }
        return configuration.makeSnapshot(createdAt: clock.now())
    }

    private func jobStatus(_ jobId: JobID) async throws -> JobStatusInfo {
        let orchestrator = try requireOrchestrator()
        guard let job = try await database.jobs.fetch(jobId) else { throw ServiceError.jobNotFound(jobId) }
        let schedule = try await orchestrator.scheduleStatus(jobId: jobId, now: clock.now())
        let record = await orchestrator.runtimeRecord(for: jobId)
        let approvals = await orchestrator.pendingApprovals(for: jobId)
        return JobStatusInfo(
            job: Self.info(job, created: false), scheduleText: schedule.text, plannedStart: schedule.plannedStart,
            admissionBlock: schedule.admissionBlock?.germanDescription,
            awaitingMissedRunDecision: schedule.missedRun?.resolution == .awaitingUser,
            nextQuotaAttempt: schedule.nextQuotaAttempt?.nextAttemptAt, isLive: await orchestrator.liveJobIds.contains(jobId),
            orphanedProcess: record?.orphanedProcess ?? false, processIdentifier: record?.processIdentifier,
            worktreePath: record?.worktreePath ?? job.worktreePath, branch: record?.branch ?? job.branch,
            repositoryPath: record?.repositoryPath, openApprovals: approvals.map(\.id))
    }

    // MARK: Abbildungen

    static func info(_ job: AgentJob, created: Bool) -> JobInfo {
        JobInfo(jobId: job.jobId, workItemId: job.workItemId, providerId: job.providerId, state: job.state, priority: job.priority,
                lastError: job.lastError.map { ServiceLog.redact($0) }, wasCreated: created)
    }

    static func info(_ details: ReviewDetails) -> ReviewDetailsInfo {
        ReviewDetailsInfo(
            reviewId: details.reviewId, jobId: details.jobId, workItemId: details.workItemId, repositoryPath: details.repositoryPath,
            defaultBranch: details.defaultBranch, branch: details.branch, worktreePath: details.worktreePath,
            baseCommit: details.baseCommit, headCommit: details.headCommit, commits: details.commits, files: details.files,
            agentSummary: details.agentSummary, autoCommittedPaths: details.autoCommittedPaths,
            permissionDenials: details.permissionDenials, capturedAt: details.capturedAt,
            integrationConflictFiles: details.integrationConflictFiles, integrationProblem: details.integrationProblem,
            integratedCommit: details.integratedCommit, integratedAt: details.integratedAt,
            excludedSecretPaths: details.excludedSecretPaths.isEmpty ? nil : details.excludedSecretPaths)
    }

    static func info(_ availability: GitHubAvailability) -> GitHubAvailabilityInfo {
        switch availability {
        case let .available(version): GitHubAvailabilityInfo(isAvailable: true, detail: version)
        case let .unavailable(reason): GitHubAvailabilityInfo(isAvailable: false, detail: ServiceLog.redact(reason.description))
        }
    }

    static func pauseText(_ reason: SyncPauseReason) -> String {
        switch reason {
        case .accountUnavailable: "Kein iCloud-Account verfügbar."
        case .accountSwitched: "iCloud-Account gewechselt – bitte bestätigen."
        case .zoneDeleted: "iCloud-Daten wurden gelöscht – bitte entscheiden, ob neu hochgeladen wird."
        case .notStarted: "Synchronisierung nicht gestartet."
        }
    }

    static func info(_ result: SyncRunResult) -> SyncRunInfo {
        switch result {
        case let .completed(report):
            SyncRunInfo(outcome: .completed, applied: report.applied, sent: report.sent, conflicts: report.conflicts)
        case let .deferred(until):
            SyncRunInfo(outcome: .deferred, message: "iCloud bittet um eine Pause bis \(until.formatted(date: .omitted, time: .shortened)).")
        case let .paused(reason):
            SyncRunInfo(outcome: .paused, message: pauseText(reason))
        case let .failed(failure):
            SyncRunInfo(outcome: .failed, message: ServiceLog.redact(failure.message))
        case .coalesced:
            SyncRunInfo(outcome: .coalesced, message: "Ein Sync läuft bereits; die Anforderung wird angehängt.")
        }
    }
}

extension String {
    var trimmingTrailingSlash: String {
        var value = self
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        return value
    }
}
