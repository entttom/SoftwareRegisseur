import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC
import SoftwareRegisseurMarkdown
import SoftwareRegisseurPersistence
import SoftwareRegisseurSecrets
import SoftwareRegisseurSyncTesting
import Testing

/// Protokoll 3: Schreibwege der Mac-UI im Dienst (temporäre Datenbank und Repositories, Fake-Agent,
/// Fake-CloudKit). Keine echten Agenten, kein echtes CloudKit.
@Suite("Agent Service: IPC-Protokoll 3 (Mac-Schreibwege)", .serialized)
struct ServiceV3CommandTests {
    // MARK: Aufgaben

    @Test func createEditAndConflictOfWorkItems() async throws {
        let harness = try await ServiceTestHarness()
        let runtime = try await harness.makeRuntime()
        let project = try await harness.setUp(runtime)

        // Notiz in der Inbox; Wiederholung mit derselben ID legt nichts doppelt an.
        let note = CreateWorkItemCommand(title: "  Spontane Idee ", text: "Export auch als PDF?")
        let created = try savedInfo(await runtime.handle(.createWorkItem(note)))
        #expect(created.wasCreated)
        #expect(created.status == .inbox)
        #expect(created.projectId == nil)
        let again = try savedInfo(await runtime.handle(.createWorkItem(note)))
        #expect(!again.wasCreated)
        #expect(try await harness.database.workItems.list(WorkItemFilter(project: .withoutProject)).count == 1)
        let stored = try #require(try await harness.database.workItems.fetch(note.workItemId))
        #expect(stored.title == "Spontane Idee")
        #expect(stored.originalNote == "Export auch als PDF?")

        // Aufgabe im Projekt: offen, mit Labels; der Haushalt legt die Request-Datei an.
        let feature = CreateWorkItemCommand(projectId: project.id, type: .feature, title: "CSV-Export", text: "## Ziel\nCSV",
                                            priority: .high, labels: ["export", " export ", ""])
        let featureInfo = try savedInfo(await runtime.handle(.createWorkItem(feature)))
        #expect(featureInfo.status == .open)
        await runtime.housekeepingPass()
        #expect(harness.requestFiles(in: "docs/requests/open").count == 1)
        let item = try #require(try await harness.database.workItems.fetch(feature.workItemId))
        #expect(item.labels == ["export"])

        // Bearbeiten mit aktueller Revision.
        let other = try await harness.addWorkItem(project, title: "Abhängigkeit")
        let edit = WorkItemEditCommand(workItemId: item.uuid, expectedRevision: item.revision, title: "CSV- und PDF-Export",
                                       structuredBody: "## Ziel\nCSV und PDF", priority: .urgent, labels: ["export", "pdf"],
                                       dependencies: [other.uuid])
        let edited = try savedInfo(await runtime.handle(.updateWorkItem(edit)))
        #expect(edited.revision > item.revision)
        let afterEdit = try #require(try await harness.database.workItems.fetch(item.uuid))
        #expect(afterEdit.title == "CSV- und PDF-Export")
        #expect(afterEdit.dependencies == [other.uuid])
        #expect(afterEdit.priority == .urgent)
        let history = try await harness.database.events.events(forWorkItem: item.uuid)
        #expect(history.contains { $0.kind == .edited && $0.actor == .user(runtime.deviceId) })

        // Veraltete Revision: deutsche Meldung mit Aufforderung zum Neuladen, nichts überschrieben.
        let stale = try failureMessage(await runtime.handle(.updateWorkItem(edit)))
        #expect(stale.contains("neu laden"))
        #expect(try await harness.database.workItems.fetch(item.uuid)?.title == "CSV- und PDF-Export")

        // Abhängigkeit auf sich selbst wird abgelehnt.
        var selfDependency = edit
        selfDependency.expectedRevision = afterEdit.revision
        selfDependency.dependencies = [item.uuid]
        #expect(try failureMessage(await runtime.handle(.updateWorkItem(selfDependency))).contains("Abhängigkeiten"))
    }

    @Test func statusChangesRespectHostOnlyStatesAndActiveJobs() async throws {
        let harness = try await ServiceTestHarness()
        let runtime = try await harness.makeRuntime()
        let project = try await harness.setUp(runtime)
        let item = try await harness.addWorkItem(project)

        // Dienst-Status (ADR-0012) sind manuell nicht wählbar.
        let hostOnly = try failureMessage(await runtime.handle(.changeWorkItemStatus(workItemId: item.uuid, expectedRevision: item.revision,
                                                                                       status: .inProgress)))
        #expect(hostOnly.contains("setzt nur der Dienst"))

        // Aktiver Job: manueller Wechsel abgelehnt, nicht still überschrieben.
        try expectResult(await runtime.handle(.requestJob(JobRequestCommand(
            workItemId: item.uuid, providerId: .codex, schedule: JobSchedule(kind: .notBefore(harness.clock.now().addingTimeInterval(86_400)))))))
        let withJob = try #require(try await harness.database.workItems.fetch(item.uuid))
        let blocked = try failureMessage(await runtime.handle(.changeWorkItemStatus(workItemId: item.uuid, expectedRevision: withJob.revision,
                                                                                     status: .cancelled)))
        #expect(blocked.contains("Agentenjob"))
        #expect(try await harness.database.workItems.fetch(item.uuid)?.status == withJob.status)

        // Ohne Job: zulässiger Wechsel mit Verlaufseintrag; veraltete Revision → Konflikt.
        let free = try await harness.addWorkItem(project, title: "Frei")
        let cancelled = try savedInfo(await runtime.handle(.changeWorkItemStatus(workItemId: free.uuid, expectedRevision: free.revision,
                                                                                  status: .cancelled)))
        #expect(cancelled.status == .cancelled)
        #expect(try failureMessage(await runtime.handle(.changeWorkItemStatus(workItemId: free.uuid, expectedRevision: free.revision,
                                                                               status: .open))).contains("neu laden"))
        let events = try await harness.database.events.events(forWorkItem: free.uuid)
        #expect(events.contains { $0.kind == .statusChanged && $0.payload["to"] == "cancelled" })
    }

    @Test func archiveAssignReclassifyDuplicateAndDeleteRules() async throws {
        let harness = try await ServiceTestHarness()
        let runtime = try await harness.makeRuntime()
        let project = try await harness.setUp(runtime)

        // Notiz einem Projekt zuweisen: offen, Typ vor Nummernvergabe änderbar.
        let note = CreateWorkItemCommand(title: "Login-Fehler", text: "Absturz beim Login")
        var info = try savedInfo(await runtime.handle(.createWorkItem(note)))
        info = try savedInfo(await runtime.handle(.reclassifyWorkItem(workItemId: note.workItemId, expectedRevision: info.revision, type: .bug)))
        #expect(info.type == .bug)
        info = try savedInfo(await runtime.handle(.assignWorkItem(workItemId: note.workItemId, expectedRevision: info.revision,
                                                                  projectId: project.id)))
        #expect(info.projectId == project.id)
        #expect(info.status == .open)

        // Nach dem Anlegen der Datei vergibt der Mac die Nummer: Typ und Projekt sind dann fest (ADR-0018).
        await runtime.housekeepingPass()
        let numbered = try #require(try await harness.database.workItems.fetch(note.workItemId))
        let humanId = try #require(numbered.humanId)
        let reclassify = try failureMessage(await runtime.handle(.reclassifyWorkItem(workItemId: numbered.uuid,
                                                                                      expectedRevision: numbered.revision, type: .feature)))
        #expect(reclassify.contains(humanId.formatted))
        #expect(try failureMessage(await runtime.handle(.assignWorkItem(workItemId: numbered.uuid, expectedRevision: numbered.revision,
                                                                        projectId: nil))).contains(humanId.formatted))

        // Löschen nur ohne Datei/Nummer; sonst archivieren (und wiederherstellen).
        let refused = try failureMessage(await runtime.handle(.deleteWorkItem(workItemId: numbered.uuid, expectedRevision: numbered.revision)))
        #expect(refused.contains("archivieren"))
        let archived = try savedInfo(await runtime.handle(.setWorkItemArchived(workItemId: numbered.uuid, expectedRevision: numbered.revision,
                                                                               archived: true)))
        #expect(archived.isArchived)
        #expect(archived.status == numbered.status)
        let restored = try savedInfo(await runtime.handle(.setWorkItemArchived(workItemId: numbered.uuid, expectedRevision: archived.revision,
                                                                               archived: false)))
        #expect(!restored.isArchived)

        // Duplikat: neue UUID, keine Nummer, idempotent.
        let copyId = WorkItemID()
        let copy = try savedInfo(await runtime.handle(.duplicateWorkItem(workItemId: numbered.uuid, newWorkItemId: copyId)))
        #expect(copy.wasCreated)
        #expect(!(try savedInfo(await runtime.handle(.duplicateWorkItem(workItemId: numbered.uuid, newWorkItemId: copyId))).wasCreated))
        let storedCopy = try #require(try await harness.database.workItems.fetch(copyId))
        #expect(storedCopy.humanId == nil)
        #expect(storedCopy.title.hasSuffix("(Kopie)"))
        #expect(storedCopy.type == .bug)

        // Nie materialisierte Notiz darf endgültig gelöscht werden.
        let scratch = CreateWorkItemCommand(title: "Tippfehler")
        let scratchInfo = try savedInfo(await runtime.handle(.createWorkItem(scratch)))
        try expectResult(await runtime.handle(.deleteWorkItem(workItemId: scratch.workItemId, expectedRevision: scratchInfo.revision)))
        #expect(try await harness.database.workItems.fetch(scratch.workItemId) == nil)
    }

    // MARK: KI-Entwürfe

    @Test func acceptingADraftUpdatesTheItemButNeverStartsAnAgent() async throws {
        let harness = try await ServiceTestHarness()
        let runtime = try await harness.makeRuntime()
        let project = try await harness.setUp(runtime)
        let item = try await harness.addWorkItem(project, title: "Rohidee")
        let draft = try await harness.database.draftVersions.append({ next in
            DraftVersion(workItemId: item.uuid, version: next, source: .ai, contents: [
                DraftContent(classification: .feature, title: "CSV-Export mit Filter", goal: "Gefilterte Daten exportieren",
                             acceptanceCriteria: ["Filter wird angewendet"], priority: .high),
            ], createdAt: harness.clock.now())
        }, for: item.uuid, at: harness.clock.now())
        let rejectedDraft = try await harness.database.draftVersions.append({ next in
            DraftVersion(workItemId: item.uuid, version: next, source: .ai, text: "Ganz anderer Ansatz", createdAt: harness.clock.now())
        }, for: item.uuid, at: harness.clock.now())

        let accepted = try savedInfo(await runtime.handle(.acceptDraftVersion(draftId: draft.id, contentIndex: 0, expectedRevision: item.revision)))
        let updated = try #require(try await harness.database.workItems.fetch(item.uuid))
        #expect(updated.title == "CSV-Export mit Filter")
        #expect(updated.structuredBody.contains("## Akzeptanzkriterien"))
        #expect(updated.structuredBody.contains("- [ ] Filter wird angewendet"))
        #expect(updated.priority == .high)
        #expect(updated.originalNote == item.originalNote)
        #expect(accepted.revision == updated.revision)
        #expect(try await harness.database.draftVersions.fetch(draft.id)?.isAccepted == true)
        // Nie ein Agentenstart (H3: Entwurf ist keine Freigabe).
        #expect(try await harness.database.jobs.jobs(forWorkItem: item.uuid).isEmpty)
        await runtime.jobsPass()
        #expect(harness.provider.startCount == 0)

        // Veraltete Revision → Konflikt; Verwerfen hält die Entscheidung im Verlauf fest.
        #expect(try failureMessage(await runtime.handle(.acceptDraftVersion(draftId: rejectedDraft.id, contentIndex: nil,
                                                                            expectedRevision: item.revision))).contains("neu laden"))
        try expectResult(await runtime.handle(.rejectDraftVersion(draftId: rejectedDraft.id)))
        let payloads = try await harness.database.events.events(forWorkItem: item.uuid).map(\.payload)
        #expect(DraftDecisionEvent.rejectedDraftIds(in: payloads) == [rejectedDraft.id.rawValue])
        #expect(try await harness.database.workItems.fetch(item.uuid)?.revision == updated.revision)
    }

    // MARK: ADRs

    @Test func adrDraftsAreNumberedByTheMacAndStatusChangesEditOnlyFrontmatter() async throws {
        let harness = try await ServiceTestHarness()
        let runtime = try await harness.makeRuntime()
        let project = try await harness.setUp(runtime)
        let commitsBefore = try await harness.git.run(["rev-list", "--count", "HEAD"], in: harness.repo).trimmedOutput

        guard case let .result(.adrCreated(first)) = try expectResult(await runtime.handle(.createADR(CreateADRCommand(
            projectId: project.id, title: "Mac-UI liest nur", context: "Ein Schreiber.", decision: "XPC für alle Änderungen.")))) else {
            Issue.record("ADR-Ergebnis erwartet")
            return
        }
        #expect(first.number == 1)
        #expect(first.relativePath == "docs/adr/0001-mac-ui-liest-nur.md")
        #expect(first.adrId != nil)
        let firstURL = harness.repo.appending(path: first.relativePath)
        let firstText = try String(contentsOf: firstURL, encoding: .utf8)
        #expect(firstText.contains("status: proposed"))
        #expect(firstText.contains("# ADR-0001: Mac-UI liest nur"))
        #expect(firstText.contains("XPC für alle Änderungen."))

        guard case let .result(.adrCreated(second)) = try expectResult(await runtime.handle(.createADR(CreateADRCommand(
            projectId: project.id, title: "XPC mit Protokoll 3")))) else {
            Issue.record("ADR-Ergebnis erwartet")
            return
        }
        #expect(second.number == 2)

        // Annahme nur auf ausdrücklichen Befehl; ersetzen geht nur von „accepted“ aus.
        let adr1 = try #require(try await harness.database.adrs.fetch(projectId: project.id, number: try ADRNumber(1)))
        #expect(adr1.status == .proposed)
        #expect(try failureMessage(await runtime.handle(.changeADRStatus(adrId: adr1.uuid, expectedRevision: adr1.revision,
                                                                         status: .superseded, supersededBy: 2))).contains("proposed"))
        try expectResult(await runtime.handle(.changeADRStatus(adrId: adr1.uuid, expectedRevision: adr1.revision, status: .accepted,
                                                               supersededBy: nil)))
        let accepted = try #require(try await harness.database.adrs.fetch(adr1.uuid))
        #expect(accepted.status == .accepted)
        let acceptedText = try String(contentsOf: firstURL, encoding: .utf8)
        #expect(Self.changedLines(firstText, acceptedText) == ["status: accepted"])

        // Ersetzen: beide Frontmatter chirurgisch, Rest unverändert.
        let secondURL = harness.repo.appending(path: second.relativePath)
        let secondBefore = try String(contentsOf: secondURL, encoding: .utf8)
        try expectResult(await runtime.handle(.changeADRStatus(adrId: accepted.uuid, expectedRevision: accepted.revision,
                                                               status: .superseded, supersededBy: 2)))
        let supersededText = try String(contentsOf: firstURL, encoding: .utf8)
        #expect(Self.changedLines(acceptedText, supersededText) == ["status: superseded by 0002"])
        let secondAfter = try String(contentsOf: secondURL, encoding: .utf8)
        #expect(Self.changedLines(secondBefore, secondAfter) == ["supersedes: 0001"])
        let superseded = try #require(try await harness.database.adrs.fetch(adr1.uuid))
        #expect(superseded.status == .superseded)
        #expect(superseded.supersededBy?.value == 2)
        #expect(try await harness.database.adrs.fetch(projectId: project.id, number: try ADRNumber(2))?.supersedes.map(\.value) == [1])

        // ADR-0024: nichts committet, die Dateien liegen ungetrackt im Arbeitsbaum.
        #expect(try await harness.git.run(["rev-list", "--count", "HEAD"], in: harness.repo).trimmedOutput == commitsBefore)
        let untracked = try await harness.git.status(of: harness.repo).untrackedPaths
        #expect(untracked.contains { $0.hasPrefix("docs/adr") })
    }

    // MARK: Einstellungen

    @Test func settingsAreValidatedAgainstTheCapabilityMatrix() async throws {
        let harness = try await ServiceTestHarness()
        let runtime = try await harness.makeRuntime()
        let project = try await harness.setUp(runtime)
        let settings = try #require(try await harness.database.projects.settings(forProject: project.id))

        func command(effort: EffortLevel, revision: Int) -> ProjectSettingsCommand {
            ProjectSettingsCommand(
                projectId: project.id, expectedRevision: revision, defaultAgentId: .codex,
                modelPreferences: [AgentModelChoice(providerId: .codex, model: .model(codexModel), effort: effort)],
                integrationStrategy: .mergeCommit, allowParallel: true, maxParallelJobs: 2, projectWideLock: true,
                reviewPolicy: .testsAndManualReview, agentInstructionsPolicy: .managedBlock)
        }

        // `xhigh` meldet der Fake-Agent nicht: abgelehnt, nichts gespeichert (ADR-0006, kein stiller Fallback).
        let unsupported = try failureMessage(await runtime.handle(.updateProjectSettings(command(effort: .xhigh, revision: settings.revision))))
        #expect(!unsupported.isEmpty)
        #expect(try await harness.database.projects.settings(forProject: project.id)?.revision == settings.revision)

        try expectResult(await runtime.handle(.updateProjectSettings(command(effort: .high, revision: settings.revision))))
        let saved = try #require(try await harness.database.projects.settings(forProject: project.id))
        #expect(saved.integrationStrategy == .mergeCommit)
        #expect(saved.projectWideLock)
        #expect(saved.maxParallelJobs == 2)
        #expect(saved.modelPreference(for: .codex)?.effort == .high)
        #expect(try await harness.database.preferences.preference(scope: .project(project.id), providerId: .codex)?.effort == .high)
        #expect(try failureMessage(await runtime.handle(.updateProjectSettings(command(effort: .low, revision: settings.revision))))
            .contains("neu laden"))
        var tooMany = command(effort: .low, revision: saved.revision)
        tooMany.maxParallelJobs = 99
        #expect(try failureMessage(await runtime.handle(.updateProjectSettings(tooMany))).contains("parallel"))

        // Global: gleiche Prüfung; ohne Wahl wird die Voreinstellung entfernt.
        #expect(!(try failureMessage(await runtime.handle(.setGlobalModelPreference(
            AgentModelChoice(providerId: .codex, model: .model(codexModel), effort: .max))))).isEmpty)
        try expectResult(await runtime.handle(.setGlobalModelPreference(AgentModelChoice(providerId: .codex, effort: .medium))))
        #expect(try await harness.database.preferences.preference(scope: .global, providerId: .codex)?.effort == .medium)
        try expectResult(await runtime.handle(.setGlobalModelPreference(AgentModelChoice(providerId: .codex))))
        #expect(try await harness.database.preferences.preference(scope: .global, providerId: .codex) == nil)

        let global = try await harness.database.globalSettings.fetch()
        try expectResult(await runtime.handle(.updateGlobalSettings(GlobalSettingsCommand(
            expectedRevision: global.revision, defaultAgentId: .codex,
            folderLayout: FolderLayoutPaths(adrPath: "doc/adr", requestsRoot: "doc/requests", openPath: "open", activePath: "doing",
                                            reviewPath: "review", donePath: "done"),
            allowParallel: false, projectWideLock: true, maxParallelJobs: nil, reviewPolicy: .manualReview,
            integrationStrategy: .squash, agentInstructionsPolicy: .proposeOnly, proposeGitInitForNewFolders: false))))
        let storedGlobal = try await harness.database.globalSettings.fetch()
        #expect(storedGlobal.defaultAgentId == .codex)
        #expect(storedGlobal.folderLayout.adrPath == "doc/adr")
        #expect(!storedGlobal.workspace.allowParallel)

        // GitHub-Zustand wird gemeldet.
        guard case let .result(.gitHubProjectState(state)) = try expectResult(await runtime.handle(.gitHubProjectState(projectId: project.id))) else {
            Issue.record("GitHub-Zustand erwartet")
            return
        }
        #expect(!state.enabled)
    }

    @Test func executablePathOverrideRebuildsProvidersWithoutRestart() async throws {
        let harness = try await ServiceTestHarness()
        let runtime = try await harness.makeRuntime()
        _ = try await harness.setUp(runtime)
        let detections = harness.provider.detectionCount

        #expect(try failureMessage(await runtime.handle(.setAgentExecutablePath(providerId: .codex, path: "/nonexistent/codex")))
            .contains("ausführbar"))
        guard case let .result(.serviceSettings(saved)) = try expectResult(await runtime.handle(
            .setAgentExecutablePath(providerId: .codex, path: "/usr/bin/true"))) else {
            Issue.record("Einstellungen erwartet")
            return
        }
        #expect(saved.executablePath(for: .codex) == "/usr/bin/true")
        #expect(harness.providers.recordedOverrides.last?[.codex] == URL(filePath: "/usr/bin/true"))
        #expect(harness.provider.detectionCount > detections)

        // Normale Einstellungen ändern den Pfad nicht; Entfernen setzt die automatische Suche wieder ein.
        guard case let .result(.serviceSettings(after)) = try expectResult(await runtime.handle(.updateServiceSettings(ServiceSettings()))) else {
            Issue.record("Einstellungen erwartet")
            return
        }
        #expect(after.executablePath(for: .codex) == "/usr/bin/true")
        try expectResult(await runtime.handle(.setAgentExecutablePath(providerId: .codex, path: nil)))
        #expect(harness.providers.recordedOverrides.last?[.codex] == nil)
    }

    // MARK: Datenlöschung (A34)

    @Test func localDeletionNeedsTheTokenReopensTheDatabaseAndKeepsRepositories() async throws {
        let harness = try await ServiceTestHarness()
        let runtime = try await harness.makeRuntime()
        _ = try await harness.setUp(runtime)
        let core = AgentServiceCore(version: ServiceVersion(shortVersion: "1.0.0", build: "7"), stopHandler: {})
        core.attach(runtime)
        // Eine Agenten-Arbeitskopie im Worktree-Ordner (L2) muss erhalten bleiben.
        let worktree = harness.storage.worktreesURL.appending(path: "job-1", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try Data("gitdir: /elsewhere\n".utf8).write(to: worktree.appending(path: ".git"))
        try Data("Arbeit\n".utf8).write(to: worktree.appending(path: "datei.txt"))

        guard case let .result(.localDeletionPreview(preview)) = try expectResult(await core.handle(.prepareLocalDeletion(.everythingLocal))) else {
            Issue.record("Vorschau erwartet")
            return
        }
        // Die Datenbankdateien stecken im Ordner „Database“ der Dienstablage.
        #expect(preview.items.contains { $0.label.contains("Database") || $0.label.contains("SoftwareRegisseur.sqlite") })
        #expect(!preview.items.contains { $0.label.contains("Worktrees") })
        #expect(!preview.consequences.isEmpty)

        // Falsches Token: nichts gelöscht, Dienst arbeitet weiter.
        #expect(!(try failureMessage(await core.handle(.executeLocalDeletion(planId: preview.planId, confirmationToken: "falsch")))).isEmpty)
        #expect(core.runtime === runtime)
        #expect(try await harness.database.projects.list().count == 1)

        guard case let .result(.localDeletionPreview(fresh)) = try expectResult(await core.handle(.prepareLocalDeletion(.everythingLocal))) else {
            Issue.record("Vorschau erwartet")
            return
        }
        guard case let .result(.localDeletionReport(report)) = try expectResult(await core.handle(
            .executeLocalDeletion(planId: fresh.planId, confirmationToken: fresh.confirmationToken))) else {
            Issue.record("Bericht erwartet")
            return
        }
        #expect(report.databaseReopened)
        #expect(report.isComplete)

        // Neue Laufzeit mit leerer Datenbank; die alte nimmt keine Befehle mehr an.
        let reopened = try #require(core.runtime)
        #expect(reopened !== runtime)
        #expect(try await reopened.database.projects.list().isEmpty)
        #expect(reopened.hostId != runtime.hostId)
        #expect(try failureMessage(await runtime.handle(.rootFolders)).contains("gelöscht"))
        try expectResult(await core.handle(.statusSummary))
        // Repository, Stammordner und Worktree unberührt.
        #expect(FileManager.default.fileExists(atPath: harness.repo.appending(path: ".git").path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: harness.repo.appending(path: "README.md").path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: worktree.appending(path: "datei.txt").path(percentEncoded: false)))
        #expect(try harness.keychain.listAccounts().isEmpty)
    }

    @Test func cloudDeletionReachesTheCoordinatorAndCanBeUndoneByReupload() async throws {
        let harness = try await ServiceTestHarness(cloud: true)
        let runtime = try await harness.makeRuntime()
        _ = try await harness.setUp(runtime)
        await runtime.performSync(reason: .manual)
        let server = try #require(harness.server)

        guard case let .result(.cloudDeletionPreview(preview)) = try expectResult(await runtime.handle(.prepareCloudDeletion)) else {
            Issue.record("Vorschau erwartet")
            return
        }
        #expect(!preview.consequences.isEmpty)
        #expect(await server.zoneDeletionRequests == 0)
        try expectResult(await runtime.handle(.confirmCloudDeletion(planId: preview.planId, confirmationToken: preview.confirmationToken)))
        #expect(await server.zoneDeletionRequests >= 1)
        let summary = await runtime.statusSummary()
        #expect(summary.sync.cloudDataDeletion == .deleted)
        #expect(summary.sync.state == .paused)
        // Lokale Daten bleiben erhalten.
        #expect(try await harness.database.projects.list().count == 1)
        // Token ist verbraucht.
        #expect(!(try failureMessage(await runtime.handle(.confirmCloudDeletion(planId: preview.planId,
                                                                                confirmationToken: preview.confirmationToken)))).isEmpty)

        // „Wieder mit iCloud synchronisieren“.
        try expectResult(await runtime.handle(.recreateCloudZone))
        #expect(await runtime.statusSummary().sync.cloudDataDeletion == nil)
    }

    // MARK: Hilfen

    /// Zeilen in `after`, die in `before` nicht vorkommen.
    static func changedLines(_ before: String, _ after: String) -> [String] {
        let old = Set(before.components(separatedBy: "\n"))
        let removed = before.components(separatedBy: "\n").filter { !after.components(separatedBy: "\n").contains($0) }
        let added = after.components(separatedBy: "\n").filter { !old.contains($0) }
        // Höchstens die geänderte Zeile darf fehlen.
        return removed.count <= added.count ? added : added + removed.map { "-" + $0 }
    }
}

func savedInfo(_ response: ServiceResponse, sourceLocation: SourceLocation = #_sourceLocation) throws -> WorkItemSavedInfo {
    guard case let .result(.workItemSaved(info)) = try expectResult(response, sourceLocation: sourceLocation) else {
        Issue.record("Aufgabenergebnis erwartet: \(response)", sourceLocation: sourceLocation)
        throw TestFailure("kein workItemSaved")
    }
    return info
}

func failureMessage(_ response: ServiceResponse, sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
    guard case let .failure(message) = response else {
        Issue.record("Ablehnung erwartet, erhalten: \(response)", sourceLocation: sourceLocation)
        throw TestFailure("kein failure")
    }
    return message
}
