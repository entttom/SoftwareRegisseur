import Foundation
import Testing
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC
import SoftwareRegisseurPersistence

/// Ablauflogik der Mac-Schreibwege (IPC-Protokoll 3): Formulare, Verfügbarkeit, Bestätigungen, Merge.
@Suite("Mac-Schreibwege: Aufgaben, ADRs, Einstellungen, Löschen, Konflikte")
struct V3FlowTests {
    static let capability = AgentCapability(
        providerId: .codex, displayName: "Codex", hostId: Fixture.hostId, executablePath: "/opt/homebrew/bin/codex", version: "0.170.0",
        supportsApprovals: true, supportsModelSelection: true, supportsEffortSelection: true,
        modelCatalog: [AgentModelCapability(providerId: .codex, modelId: "modell-a", displayName: "A",
                                            supportedEffortIds: [.low, .medium, .high], source: .verifiedSpike, lastValidatedAt: Fixture.now)],
        defaultModelId: "modell-a", capabilitySource: .verifiedSpike, capabilityRevision: 1, lastChecked: Fixture.now)

    // MARK: Aufgaben

    @Test func newNoteUsesFirstLineAsTitleAndKeepsItsIdAcrossRetries() {
        var form = NewWorkItemForm()
        #expect(!form.isValid)
        form.text = "  PDF-Export prüfen\nmit Kopfzeile"
        form.labelsText = "export, , pdf, export"
        #expect(form.isValid)
        let first = form.command
        #expect(first.title == "PDF-Export prüfen")
        #expect(first.projectId == nil)
        #expect(first.type == .note)
        #expect(first.labels == ["export", "pdf"])
        #expect(form.command.workItemId == first.workItemId)
        form.title = "Eigener Titel"
        #expect(form.command.title == "Eigener Titel")
    }

    @Test func editFormSendsBaseRevisionAndReloadsAfterConflict() {
        let item = Fixture.item("CSV-Export", labels: ["a"], body: "alt")
        var form = WorkItemEditForm(item)
        #expect(!form.hasChanges(comparedTo: item))
        form.body = "neu"
        form.labelsText = "a, b"
        #expect(form.hasChanges(comparedTo: item))
        let command = form.command
        #expect(command.expectedRevision == item.revision)
        #expect(command.labels == ["a", "b"])
        #expect(command.structuredBody == "neu")

        var changedElsewhere = item
        changedElsewhere.title = "Am iPhone geändert"
        changedElsewhere.touch(at: Fixture.now)
        #expect(form.isStale(comparedTo: changedElsewhere))
        form.reload(from: changedElsewhere)
        #expect(!form.isStale(comparedTo: changedElsewhere))
        #expect(form.title == "Am iPhone geändert")
        #expect(form.command.expectedRevision == changedElsewhere.revision)

        let conflict = CommandOutcome.from(.failure("Der Eintrag wurde inzwischen geändert. Bitte neu laden und erneut versuchen."), title: "Speichern")
        #expect(conflict.isRevisionConflict)
        #expect(!CommandOutcome.from(.failure("Anderer Fehler"), title: "X").isRevisionConflict)
    }

    @Test func numberedItemsCannotBeReclassifiedMovedOrDeleted() {
        let numbered = Fixture.item("Mit Nummer", number: 7)
        let numberedActions = WorkItemActionAvailability(item: numbered, hasActiveJob: false, hasDocument: true, jobCount: 0)
        #expect(!numberedActions.canReclassify)
        #expect(!numberedActions.canAssign)
        #expect(!numberedActions.canDelete)
        #expect(numberedActions.reclassifyReason?.contains("Duplizieren") == true)
        #expect(numberedActions.deleteReason?.contains("Archivieren") == true)

        let note = Fixture.item("Notiz", project: nil, type: .note, status: .inbox)
        let free = WorkItemActionAvailability(item: note, hasActiveJob: false, hasDocument: false, jobCount: 0)
        #expect(free.canReclassify && free.canAssign && free.canDelete)
        #expect(!WorkItemActionAvailability(item: note, hasActiveJob: false, hasDocument: false, jobCount: 1).canDelete)
        #expect(!WorkItemActionAvailability(item: note, hasActiveJob: true, hasDocument: false, jobCount: 1).canReclassify)
    }

    @Test func savedWorkItemFeedbackUsesServiceMessage() {
        let info = WorkItemSavedInfo(workItemId: WorkItemID(), revision: 3, status: .open, type: .feature, projectId: nil,
                                     isArchived: false, wasCreated: true, message: "Aufgabe angelegt.")
        let outcome = CommandOutcome.from(.result(.workItemSaved(info)), title: "Anlegen")
        #expect(outcome.feedback == .success("Aufgabe angelegt."))
        #expect(outcome.savedWorkItem == info)
    }

    @Test func rejectedDraftsAreReadFromHistory() {
        let item = Fixture.item("Entwurf")
        let draft = DraftVersion(workItemId: item.uuid, version: 2, source: .ai, text: "Idee", createdAt: Fixture.now)
        #expect(DraftDecisionState.state(of: draft, rejected: []) == .open)
        let event = TaskEvent(workItemId: item.uuid, kind: .comment, actor: .user(DeviceID()), timestamp: Fixture.now,
                              payload: [DraftDecisionEvent.decisionKey: DraftDecisionEvent.rejected,
                                        DraftDecisionEvent.draftIdKey: draft.id.uuidString], sourceRevision: 1)
        let rejected = DraftDecisionState.rejectedIds(in: [event])
        #expect(DraftDecisionState.state(of: draft, rejected: rejected) == .rejected)
        var accepted = draft
        accepted.accept(contentIndexes: [0], at: Fixture.now)
        #expect(DraftDecisionState.state(of: accepted, rejected: rejected) == .accepted)
    }

    // MARK: ADRs

    @Test func adrActionsFollowTheStateMachine() throws {
        let project = ProjectID()
        let proposed = ADR(projectId: project, decisionNumber: try ADRNumber(1), title: "A", status: .proposed, createdAt: Fixture.now)
        let accepted = ADR(projectId: project, decisionNumber: try ADRNumber(2), title: "B", status: .accepted, createdAt: Fixture.now)
        let newer = ADR(projectId: project, decisionNumber: try ADRNumber(3), title: "C", status: .proposed, createdAt: Fixture.now)
        let all = [proposed, accepted, newer]
        #expect(ADRStatusAction.actions(for: proposed, in: all) == [.accept, .deprecate])
        let acceptedActions = ADRStatusAction.actions(for: accepted, in: all)
        #expect(acceptedActions.contains(.deprecate))
        #expect(acceptedActions.contains(.supersede(by: try ADRNumber(3))))
        #expect(!acceptedActions.contains(.accept))
        let request = ADRStatusAction.supersede(by: try ADRNumber(3)).request(for: accepted)
        #expect(request == .changeADRStatus(adrId: accepted.uuid, expectedRevision: accepted.revision, status: .superseded, supersededBy: 3))

        var form = ADRCreateForm()
        #expect(!form.isValid)
        form.title = "Neu"
        form.supersedesText = "2, x 5"
        #expect(form.command(projectId: project).supersedes == [2, 5])
    }

    // MARK: Einstellungen

    @Test func modelChoicesOnlyOfferSupportedCombinations() {
        let options = ModelChoiceOptions(capability: Self.capability)
        #expect(options.models == [.providerDefault, .model("modell-a")])
        #expect(options.efforts(for: .model("modell-a")).contains(.high))
        #expect(!options.efforts(for: .model("modell-a")).contains(.xhigh))
        #expect(!options.isValid(model: .model("modell-a"), effort: .max))
        #expect(options.isValid(model: nil, effort: nil))
    }

    @Test func projectSettingsFormValidatesAndBuildsCommand() {
        let project = ProjectID()
        let settings = ProjectSettings(updatedAt: Fixture.now)
        var form = ProjectSettingsForm(projectId: project, settings: settings)
        form.choices[.codex] = AgentModelChoice(providerId: .codex, model: .model("modell-a"), effort: .xhigh)
        #expect(!form.problems(capabilities: [Self.capability]).isEmpty)
        form.choices[.codex] = AgentModelChoice(providerId: .codex, model: .model("modell-a"), effort: .high)
        form.limitParallelJobs = true
        form.maxParallelJobs = 3
        form.integrationStrategy = .cherryPick
        #expect(form.problems(capabilities: [Self.capability]).isEmpty)
        let command = form.command
        #expect(command.expectedRevision == settings.revision)
        #expect(command.maxParallelJobs == 3)
        #expect(command.modelPreferences == [AgentModelChoice(providerId: .codex, model: .model("modell-a"), effort: .high)])
        // Erben wird nicht gesendet.
        form.choices[.codex] = AgentModelChoice(providerId: .codex)
        #expect(form.command.modelPreferences.isEmpty)
        // Unbekannter Agent: keine Prüfung möglich.
        form.choices[.claudeCode] = AgentModelChoice(providerId: .claudeCode, effort: .high)
        #expect(!form.problems(capabilities: [Self.capability]).isEmpty)
    }

    @Test func globalDefaultsFormRejectsInvalidLayout() {
        var form = GlobalDefaultsForm(.defaults)
        #expect(form.problems.isEmpty)
        #expect(form.command.expectedRevision == 0)
        form.layout.adrPath = "/absolut"
        #expect(!form.problems.isEmpty)
    }

    // MARK: Datenlöschung

    @Test func deletionNeedsPreviewConfirmationAndUnexpiredPlan() {
        let preview = LocalDeletionPreviewInfo(
            planId: UUID(), kind: .localDatabase, confirmationToken: "t", title: "Löschen", summary: "1 Eintrag",
            items: [.init(label: "Datenbankdatei", byteCount: 10, affectsOtherDevices: false)], retained: [], consequences: [],
            totalBytes: 10, expiresAt: Fixture.now.addingTimeInterval(600))
        var confirmation = DeletionConfirmation()
        #expect(!confirmation.canExecute(preview: preview, now: Fixture.now))
        confirmation.confirmed = true
        #expect(confirmation.canExecute(preview: preview, now: Fixture.now))
        #expect(!confirmation.canExecute(preview: preview, now: Fixture.now.addingTimeInterval(601)))
        #expect(!confirmation.canExecute(preview: nil, now: Fixture.now))

        let report = LocalDeletionReportInfo(deleted: ["a", "b"], alreadyMissing: [], failed: [], databaseReopened: true)
        #expect(DeletionConfirmation.summary(report).contains("2 Einträge gelöscht"))
        #expect(DeletionConfirmation.summary(report).contains("neu angelegt"))
        #expect(!CommandOutcome.from(.result(.localDeletionReport(report)), title: "Löschen").feedback.isFailure)
        let failed = LocalDeletionReportInfo(deleted: [], alreadyMissing: [], failed: ["x: gesperrt"], databaseReopened: false)
        #expect(CommandOutcome.from(.result(.localDeletionReport(failed)), title: "Löschen").feedback.isFailure)
    }

    // MARK: Sync-Konflikte

    @Test func mergeEditorShowsDifferingTextsAndBuildsMergedPayload() throws {
        let base = Fixture.item("Titel", body: "Zeile 1")
        var local = base
        local.structuredBody = "Zeile 1\nMac"
        local.touch(at: Fixture.now)
        var remote = base
        remote.structuredBody = "Zeile 1\niPhone"
        remote.title = "Titel (iPhone)"
        remote.touch(at: Fixture.now)
        let merge = try #require(SyncConflictMerge(
            entityType: .workItem, ancestor: try SyncPayloadCodec.encode(base), local: try SyncPayloadCodec.encode(local),
            remote: try SyncPayloadCodec.encode(remote)))
        #expect(merge.fields.map(\.field) == [.title, .structuredBody])
        // Titel nur in iCloud geändert → Vorschlag iCloud; Inhalt auf beiden Seiten → eigener Stand.
        #expect(merge.initialValues[.title] == "Titel (iPhone)")
        #expect(merge.initialValues[.structuredBody] == "Zeile 1\nMac")
        var values = merge.initialValues
        values[.structuredBody] = "Zeile 1\nMac\niPhone"
        let merged = try SyncPayloadCodec.decode(WorkItem.self, from: try merge.mergedPayload(values))
        #expect(merged.title == "Titel (iPhone)")
        #expect(merged.structuredBody == "Zeile 1\nMac\niPhone")
        #expect(merged.uuid == base.uuid)
        #expect(merged.status == local.status)

        // Gelöschte Seite oder Datensätze ohne Text: kein Merge-Editor.
        #expect(SyncConflictMerge(entityType: .workItem, ancestor: nil, local: try SyncPayloadCodec.encode(local), remote: nil) == nil)
        #expect(SyncConflictMerge(entityType: .workItem, ancestor: nil, local: try SyncPayloadCodec.encode(local),
                                  remote: try SyncPayloadCodec.encode(local)) == nil)
    }
}
