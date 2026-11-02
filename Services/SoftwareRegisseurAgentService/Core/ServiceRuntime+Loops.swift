import Foundation
import SoftwareRegisseurAgents
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC
import SoftwareRegisseurJobs
import SoftwareRegisseurPersistence
import SoftwareRegisseurWorkspace

extension ServiceRuntime {
    // MARK: Jobs (J3, K1–K3, L1, M1)

    /// Ein Durchlauf der Job-Schleife. Liefert den nächsten Weckzeitpunkt des Orchestrators.
    @discardableResult
    func jobsPass() async -> Date {
        let now = clock.now()
        await heartbeatIfDue(now: now)
        guard let orchestrator else { return now.addingTimeInterval(settings.jobsIdleInterval) }
        gate.set(open: runState == .running)
        let report = await orchestrator.tick(now: now)
        lastTick = report
        let live = await orchestrator.liveJobIds
        let liveChanged = live != lastLiveJobs
        lastLiveJobs = live
        deps.sleepAssertion.setPreventIdleSleep(settings.preventIdleSleepWhileAgentsRun && !live.isEmpty,
                                                reason: "Software Regisseur: Coding-Agent arbeitet")
        log(report)
        let changed = !report.takenOver.isEmpty || !report.started.isEmpty || !report.failed.isEmpty
            || !report.missed.isEmpty || !report.needsConfiguration.isEmpty || !report.approvalsAnswered.isEmpty
            || !report.approvalsClosed.isEmpty || !report.releasedLocks.isEmpty || !report.approvalTimeouts.isEmpty
        if changed || liveChanged {
            housekeepingSignal.signal()
            sendSoon()
        }
        return report.nextWakeDate
    }

    private func log(_ report: TickReport) {
        guard !report.skipped else { return }
        if !report.started.isEmpty || !report.takenOver.isEmpty || !report.failed.isEmpty || !report.needsConfiguration.isEmpty {
            ServiceLog.jobs.notice("Tick: \(report.takenOver.count, privacy: .public) übernommen, \(report.started.count, privacy: .public) gestartet, \(report.needsConfiguration.count, privacy: .public) brauchen Konfiguration, \(report.failed.count, privacy: .public) fehlgeschlagen")
        }
        for (job, reason) in report.failed {
            ServiceLog.jobs.error("Job \(job.shortString, privacy: .public) fehlgeschlagen: \(ServiceLog.redact(reason), privacy: .private)")
        }
        for error in report.errors {
            ServiceLog.jobs.error("Tick-Fehler: \(ServiceLog.redact(error), privacy: .private)")
        }
    }

    /// Host-Heartbeat (synchronisiert, N4): höchstens jede Minute, sofort bei Wechsel „bereit/pausiert“.
    func heartbeatIfDue(now: Date) async {
        let ready = runState == .running && orchestrator != nil
        if let last = lastHeartbeat, now.timeIntervalSince(last) < 60, lastHeartbeatReady == ready { return }
        do {
            try await database.capabilities.recordHeartbeat(hostId, ready: ready, at: now)
            lastHeartbeat = now
            lastHeartbeatReady = ready
        } catch {
            ServiceLog.jobs.error("Heartbeat nicht gespeichert: \(ServiceLog.redact(error), privacy: .private)")
        }
    }

    // MARK: Pause (D1)

    /// Pausiert oder setzt fort. Pause stoppt nur die Zulassung neuer Läufe; laufende Jobs, Freigaben,
    /// Sync, Scanner und Steuerbefehle laufen weiter.
    func setRunState(_ state: ServiceRunState) async throws -> ServiceRunState {
        guard state != runState else { return runState }
        try await stateStore.saveRunState(state)
        runState = state
        gate.set(open: state == .running)
        ServiceLog.lifecycle.notice("Dienst \(state == .paused ? "pausiert" : "fortgesetzt", privacy: .public)")
        await heartbeatIfDue(now: clock.now())
        jobsSignal.signal()
        sendSoon()
        return state
    }

    // MARK: Haushalt

    /// Einrichtung, Konfliktlösungen, Markdown-Abgleich, KI-Ausarbeitungen. Fehler werden protokolliert,
    /// nie geworfen.
    func housekeepingPass() async {
        await processProjectSetup()
        await applyRequestedResolutions()
        await materializeChanges()
        // Eingereihte Ausarbeitungen kommen per Sync; zusätzlich alle 10 min nachsehen.
        if aiQueueDirty || lastAIQueueScan.map({ clock.now().timeIntervalSince($0) > 600 }) ?? true {
            aiQueueDirty = false
            lastAIQueueScan = clock.now()
            await processAIQueue()
        }
    }

    func processProjectSetup() async {
        do {
            let processed = try await setupService.processPending()
            guard !processed.isEmpty else { return }
            for command in processed {
                ServiceLog.workspace.notice("Projekteinrichtung \(command.id.shortString, privacy: .public): \(command.state.rawValue, privacy: .public)")
            }
            await refreshWatchedProjects()
            await refreshInstructionProposals(for: processed.filter { $0.state == .completed }.map(\.projectId))
            needsFullReconcile = true
            sendSoon()
        } catch {
            ServiceLog.workspace.error("Projekteinrichtung: \(ServiceLog.redact(error), privacy: .private)")
        }
    }

    func applyRequestedResolutions() async {
        do {
            let report = try await repositorySync.materializer.applyRequestedResolutions()
            if !report.isEmpty { sendSoon() }
            for error in report.errors {
                ServiceLog.workspace.error("Konfliktlösung: \(ServiceLog.redact(error), privacy: .private)")
            }
        } catch {
            ServiceLog.workspace.error("Konfliktlösungen: \(ServiceLog.redact(error), privacy: .private)")
        }
        do {
            let handled = try await gitHub.applyRequestedResolutions()
            if !handled.isEmpty { sendSoon() }
        } catch {
            ServiceLog.workspace.error("GitHub-Konfliktlösungen: \(ServiceLog.redact(error), privacy: .private)")
        }
    }

    /// Bringt Markdown-Dateien auf den Stand der Datenbank (neue/geänderte Aufgaben, Statuswechsel aus
    /// Jobs, done nach „Erledigt“) und übernimmt externe Änderungen (E3, F5, M1, U4).
    ///
    /// Nach einem Sync mit eingegangenen Daten, nach dem Aufwachen und beim Start: alle Projekte.
    /// Sonst nur Projekte, deren Aufgaben seit dem letzten Durchlauf Verlaufseinträge erhielten.
    func materializeChanges() async {
        let now = clock.now()
        if needsFullReconcile {
            needsFullReconcile = false
            do {
                let results = try await repositorySync.reconcileAll()
                logReconciliations(results)
                if results.contains(where: { !$0.requests.isEmpty || ($0.adrs.map { !$0.imported.isEmpty || !$0.updated.isEmpty } ?? false) }) {
                    sendSoon()
                }
            } catch {
                needsFullReconcile = true
                ServiceLog.workspace.error("Abgleich aller Projekte: \(ServiceLog.redact(error), privacy: .private)")
            }
            eventCursor = now
            processedEvents = [:]
            return
        }
        let since = (eventCursor ?? startedAt).addingTimeInterval(-3_600)
        let limit = 2_000
        guard let events = try? await database.events.events(since: since, limit: limit) else { return }
        if events.count == limit { needsFullReconcile = true }
        let fresh = events.filter { processedEvents[$0.eventId] == nil }
        var projects = Set<ProjectID>()
        for workItemId in Set(fresh.map(\.workItemId)) {
            if let projectId = try? await database.workItems.fetch(workItemId)?.projectId, watchedProjects.contains(projectId) {
                projects.insert(projectId)
            }
        }
        for event in fresh { processedEvents[event.eventId] = event.timestamp }
        processedEvents = processedEvents.filter { $0.value >= since }
        eventCursor = now
        var results: [ProjectReconciliation] = []
        for projectId in projects.sorted(by: { $0.uuidString < $1.uuidString }) {
            results.append(await repositorySync.reconcile(projectId: projectId))
        }
        logReconciliations(results)
        if results.contains(where: { !$0.requests.isEmpty }) { sendSoon() }
    }

    private func logReconciliations(_ results: [ProjectReconciliation]) {
        for result in results {
            if let error = result.error {
                ServiceLog.workspace.error("Abgleich \(result.projectId.shortString, privacy: .public): \(ServiceLog.redact(error), privacy: .private)")
            }
            let requests = result.requests
            if !requests.isEmpty {
                ServiceLog.workspace.info("Abgleich \(result.projectId.shortString, privacy: .public): \(requests.createdFiles.count, privacy: .public) neu, \(requests.updatedFiles.count, privacy: .public) aktualisiert, \(requests.movedFiles.count, privacy: .public) verschoben, \(requests.importedItems.count, privacy: .public) importiert, \(requests.conflicts.count, privacy: .public) Konflikte")
            }
        }
    }

    // MARK: Scanner (E1)

    /// Scan der bestätigten Stammordner. Parallele Anforderungen teilen sich einen Lauf.
    func scan() async throws -> ScanInfo {
        if let scanTask { return try await scanTask.value }
        guard !rootFolders.isEmpty else { throw ServiceError.noRootFolders }
        let task = Task { try await self.performScan() }
        scanTask = task
        defer { scanTask = nil }
        do {
            let info = try await task.value
            lastScan = info
            lastScanError = nil
            return info
        } catch {
            lastScanError = ServiceErrorText.message(for: error)
            throw error
        }
    }

    private func performScan() async throws -> ScanInfo {
        await catalog.configure(Self.catalogConfiguration(roots: rootFolders, storage: deps.storage, scanDepth: settings.folderScanDepth))
        let report = try await catalog.scan()
        let info = ScanInfo(
            createdProjects: report.createdProjects.count, updatedProjects: report.updatedProjects.count,
            movedProjects: report.movedProjects.count, unavailableProjects: report.unavailableProjects.count,
            relinkCandidates: report.relinkCandidates.values.reduce(0) { $0 + $1.count },
            indexedFolders: report.indexedFolderCount, issues: report.issues.prefix(50).map { ServiceLog.redact($0) },
            finishedAt: clock.now()
        )
        ServiceLog.workspace.notice("Scan: \(info.createdProjects, privacy: .public) neue, \(info.movedProjects, privacy: .public) verschobene, \(info.unavailableProjects, privacy: .public) nicht erreichbare Projekte, \(info.indexedFolders, privacy: .public) Ordner")
        let firstScan = lastScan == nil
        await refreshWatchedProjects()
        let candidates = firstScan ? Array(watchedProjects) : report.createdProjects + Array(report.movedProjects.keys)
        await refreshInstructionProposals(for: candidates)
        needsFullReconcile = true
        housekeepingSignal.signal()
        gitHubSignal.signal()
        sendSoon()
        return info
    }

    /// Startet die Dateisystem-Beobachtung neu, wenn sich die Menge der Projekte auf diesem Mac änderte.
    func refreshWatchedProjects() async {
        let current = Set(((try? await repositorySync.watchedProjects()) ?? []).map(\.0))
        guard current != watchedProjects else { return }
        watchedProjects = current
        guard !loops.isEmpty else { return }
        do {
            try await repositorySync.start(reconcileInterval: .seconds(settings.reconcileInterval))
        } catch {
            ServiceLog.workspace.error("Dateisystem-Beobachtung nicht neu startbar: \(ServiceLog.redact(error), privacy: .private)")
        }
    }

    // MARK: AGENTS.md / CLAUDE.md (G)

    /// Berechnet Vorschläge neu und hält sie zur Freigabe in der UI bereit. Nie automatisch angewendet.
    func refreshInstructionProposals(for projectIds: [ProjectID], createClaudeFileIfMissing: Bool = false) async {
        let claudeInstalled = (try? await database.capabilities.capability(hostId: hostId, providerId: .claudeCode))?.installed ?? false
        for projectId in Set(projectIds) {
            guard let project = try? await database.projects.fetch(projectId), project.hostId == hostId,
                  project.status == .ready || project.status == .needsAttention
            else { continue }
            do {
                let proposal = try await instructions.propose(
                    projectId: projectId,
                    capabilities: InstructionCapabilities(claudeSupportsImports: claudeInstalled,
                                                          createClaudeFileIfMissing: createClaudeFileIfMissing))
                if let previous = proposals[projectId], previous.id != proposal.id { await instructions.discard(previous.id) }
                proposals[projectId] = proposal.hasChanges ? proposal : nil
            } catch {
                if let previous = proposals.removeValue(forKey: projectId) { await instructions.discard(previous.id) }
                if case WorkspaceError.instructionsDisabled = error { continue }
                ServiceLog.workspace.error("Anweisungsvorschlag \(projectId.shortString, privacy: .public): \(ServiceLog.redact(error), privacy: .private)")
            }
        }
    }

    // MARK: Agentenerkennung (J1)

    /// Erkennung aller Anbieter; Ergebnis als synchronisierte Fähigkeiten dieses Hosts.
    @discardableResult
    func detectAgents() async -> [AgentDetectionReport] {
        if let detectionTask { return await detectionTask.value }
        let task = Task { await self.performDetection() }
        detectionTask = task
        defer { detectionTask = nil }
        return await task.value
    }

    private func performDetection() async -> [AgentDetectionReport] {
        let previousList = (try? await database.capabilities.capabilities(hostId: hostId)) ?? []
        let previous = Dictionary(previousList.map { ($0.providerId, $0) }, uniquingKeysWith: { first, _ in first })
        let reports = await providers.detectAll(previous: previous)
        let now = clock.now()
        let capabilities = reports.map(\.capability).filter { $0.hostId == hostId }
        do {
            _ = try await database.capabilities.replaceCapabilities(hostId: hostId, with: capabilities, at: now)
            lastDetection = now
        } catch {
            ServiceLog.agents.error("Fähigkeiten nicht gespeichert: \(ServiceLog.redact(error), privacy: .private)")
        }
        for report in reports {
            let capability = report.capability
            ServiceLog.agents.notice("Agent \(capability.providerId.rawValue, privacy: .public): installiert \(capability.installed, privacy: .public), einsatzbereit \(capability.isReady, privacy: .public), Version \(capability.version, privacy: .public), \(capability.modelCatalog.count, privacy: .public) Modelle")
            for diagnostic in report.diagnostics where diagnostic.severity != .info {
                ServiceLog.agents.info("Agent \(capability.providerId.rawValue, privacy: .public) [\(diagnostic.code, privacy: .public)]: \(ServiceLog.redact(diagnostic.message), privacy: .private)")
            }
        }
        jobsSignal.signal()
        sendSoon()
        return reports
    }

    // MARK: GitHub (M3)

    /// Abgleich verknüpfter Aufgaben aktivierter Projekte. Ohne `gh`-Anmeldung passiert nichts.
    func gitHubPass(projectId: ProjectID?) async {
        let availability = await currentGitHubAvailability(force: projectId != nil)
        guard availability.isAvailable else { return }
        let projectIds: [ProjectID]
        if let projectId {
            projectIds = [projectId]
        } else {
            projectIds = Array(watchedProjects)
        }
        for projectId in projectIds {
            guard (try? await gitHub.isEnabled(projectId: projectId)) == true,
                  let repo = try? await gitHub.repository(for: projectId),
                  let links = try? await database.reviews.issueLinks(repo: repo)
            else { continue }
            for link in links {
                do {
                    let outcome = try await gitHub.synchronize(workItemId: link.workItemId)
                    if case .divergence = outcome {
                        ServiceLog.workspace.notice("GitHub-Abweichung bei Issue #\(link.issueNumber, privacy: .public) – Konflikthinweis angelegt")
                    }
                } catch {
                    ServiceLog.workspace.error("GitHub-Abgleich #\(link.issueNumber, privacy: .public): \(ServiceLog.redact(error), privacy: .private)")
                }
            }
        }
        sendSoon()
    }

    func currentGitHubAvailability(force: Bool) async -> GitHubAvailability {
        let now = clock.now()
        if !force, let cached = gitHubAvailability, let checked = gitHubAvailabilityCheckedAt, now.timeIntervalSince(checked) < 600 {
            return cached
        }
        let availability = await gitHub.availability()
        gitHubAvailability = availability
        gitHubAvailabilityCheckedAt = now
        return availability
    }
}
