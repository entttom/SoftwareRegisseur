import Foundation
import SoftwareRegisseurAppCore
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC
import SoftwareRegisseurPersistence
import SoftwareRegisseurWorkspace

/// Aufgaben und KI-Entwürfe aus der Mac-UI (seit Protokoll 3; H1, H3, F1, ADR-0012, ADR-0018).
///
/// Jede Änderung läuft über `WorkItemRepository`/`DraftVersionRepository` als `EventActor.user` dieses Macs:
/// Revision, Verlaufseintrag und Sync-Outbox entstehen dort in einer Transaktion. Die Request-Datei folgt
/// beim nächsten Haushaltsdurchlauf über die Verlaufseinträge (Markdown-Abgleich).
extension ServiceRuntime {
    /// Überschriften für übernommene KI-Entwürfe (gleich wie am iPhone).
    static let draftHeadings = DraftBodyHeadings(
        goal: "Ziel", context: "Kontext", acceptanceCriteria: "Akzeptanzkriterien", technicalNotes: "Technische Hinweise",
        testCases: "Testfälle", dependencies: "Abhängigkeiten", openQuestions: "Offene Fragen")

    // MARK: Anlegen

    func createWorkItem(_ command: CreateWorkItemCommand) async throws -> WorkItemSavedInfo {
        if let existing = try await database.workItems.fetch(command.workItemId) {
            return Self.saved(existing, created: false, message: "Die Aufgabe war bereits angelegt.")
        }
        let title = command.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ServiceError.titleMissing }
        if let projectId = command.projectId { try await requireUsableProject(projectId) }
        let now = clock.now()
        let item = WorkItem(
            uuid: command.workItemId, projectId: command.projectId, type: command.type, title: title,
            originalNote: command.text, structuredBody: command.text, status: command.projectId == nil ? .inbox : .open,
            priority: command.priority, labels: WorkItemCommandRules.normalizedLabels(command.labels), createdAt: now)
        try await database.workItems.insert(item, actor: userActor, at: now)
        workItemsChanged()
        return Self.saved(item, created: true,
                          message: command.projectId == nil ? "Notiz in der Inbox angelegt." : "Aufgabe angelegt.")
    }

    func duplicateWorkItem(_ id: WorkItemID, newId: WorkItemID) async throws -> WorkItemSavedInfo {
        if let existing = try await database.workItems.fetch(newId) {
            return Self.saved(existing, created: false, message: "Die Kopie war bereits angelegt.")
        }
        let source = try await requireWorkItem(id)
        let now = clock.now()
        // Wie `TaskEditor.duplicate`: neue UUID, keine Nummer, keine Jobs, kein Verlauf (ADR-0018).
        let copy = WorkItem(
            uuid: newId, projectId: source.projectId, type: source.type, title: source.title + " (Kopie)",
            originalNote: source.originalNote, transcript: source.transcript, structuredBody: source.structuredBody,
            status: source.projectId == nil ? .inbox : .open, priority: source.priority, complexity: source.complexity,
            labels: source.labels, dependencies: source.dependencies, createdAt: now)
        try await database.workItems.insert(copy, actor: userActor, at: now)
        workItemsChanged()
        return Self.saved(copy, created: true, message: "Kopie angelegt.")
    }

    // MARK: Bearbeiten

    func updateWorkItem(_ command: WorkItemEditCommand) async throws -> WorkItemSavedInfo {
        let title = command.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ServiceError.titleMissing }
        var dependencies: [WorkItemID] = []
        for dependency in command.dependencies where !dependencies.contains(dependency) {
            guard dependency != command.workItemId, try await database.workItems.fetch(dependency) != nil else {
                throw ServiceError.dependencyInvalid
            }
            dependencies.append(dependency)
        }
        let labels = WorkItemCommandRules.normalizedLabels(command.labels)
        let validDependencies = dependencies
        let updated = try await database.workItems.update(
            command.workItemId, expectedRevision: command.expectedRevision, actor: userActor, at: clock.now()
        ) { item in
            item.title = title
            item.structuredBody = command.structuredBody
            item.priority = command.priority
            item.labels = labels
            item.dependencies = validDependencies
        }
        workItemsChanged()
        return Self.saved(updated, message: "Änderungen gespeichert.")
    }

    /// Manueller Statuswechsel (F5). Abgelehnt bei aktivem Job oder gehaltener Sperre (ADR-0012), für
    /// Status, die nur der Dienst setzt, und bei veralteter Revision.
    func changeWorkItemStatus(_ id: WorkItemID, expectedRevision: Int, to status: WorkItemStatus) async throws -> WorkItemSavedInfo {
        let item = try await requireWorkItem(id)
        if item.status == .integrated, status == .done {
            guard item.revision == expectedRevision else { throw Self.revisionConflict(item, expected: expectedRevision) }
            // Gleicher Weg wie „Als erledigt markieren“: die Datei wandert sofort in den done-Ordner (M1).
            _ = try await requireOrchestrator().markDone(workItemId: id, approvedBy: userActor)
            await materializeChanges()
            sendSoon()
            return Self.saved(try await requireWorkItem(id), message: "Als erledigt markiert.")
        }
        guard !WorkItemCommandRules.hostOnlyStatuses.contains(status) else { throw ServiceError.manualStatusNotAllowed(status) }
        if let lock = try await database.locks.activeLock(forTask: id), !lock.isReleased {
            throw ServiceError.workItemLocked(lock.scope)
        }
        let updated = try await database.workItems.changeStatus(id, to: status, expectedRevision: expectedRevision,
                                                                actor: userActor, at: clock.now())
        workItemsChanged()
        return Self.saved(updated, message: "Status: \(updated.status.germanDisplayName).")
    }

    /// Projekt zuweisen oder zurück in die Inbox. Nach Vergabe einer Nummer nicht mehr möglich (ADR-0018).
    func assignWorkItem(_ id: WorkItemID, expectedRevision: Int, to projectId: ProjectID?) async throws -> WorkItemSavedInfo {
        let item = try await requireWorkItem(id)
        guard item.revision == expectedRevision else { throw Self.revisionConflict(item, expected: expectedRevision) }
        guard item.projectId != projectId else { return Self.saved(item, message: "Keine Änderung.") }
        if let humanId = item.humanId { throw ServiceError.workItemNumbered(humanId) }
        if try await database.workItems.hasActiveJob(id) { throw WorkspaceError.activeJob(id) }
        if let projectId { try await requireUsableProject(projectId) }
        let now = clock.now()
        var updated = try await database.workItems.update(id, expectedRevision: expectedRevision, actor: userActor, at: now) {
            $0.projectId = projectId
        }
        // Wie am iPhone (`TaskEditor.assign`): zugewiesene Notizen werden offen, zurückgelegte wieder Inbox.
        if projectId != nil, updated.status == .inbox {
            updated = try await database.workItems.changeStatus(id, to: .open, expectedRevision: updated.revision, actor: userActor, at: now)
        } else if projectId == nil, updated.status == .open {
            updated = try await database.workItems.changeStatus(id, to: .inbox, expectedRevision: updated.revision, actor: userActor, at: now)
        }
        workItemsChanged()
        let name = if let projectId { (try? await database.projects.fetch(projectId))?.name ?? "Projekt" } else { "Inbox" }
        return Self.saved(updated, message: "Zugeordnet: \(name).")
    }

    func setWorkItemArchived(_ id: WorkItemID, expectedRevision: Int, archived: Bool) async throws -> WorkItemSavedInfo {
        let updated = try await database.workItems.setArchived(id, archived, expectedRevision: expectedRevision,
                                                               actor: userActor, at: clock.now())
        workItemsChanged()
        return Self.saved(updated, message: archived ? "Archiviert." : "Wiederhergestellt.")
    }

    /// Typwechsel (H3/F1). Das Repository lehnt ab, sobald der Mac eine Nummer vergeben hat oder ein Job läuft.
    func reclassifyWorkItem(_ id: WorkItemID, expectedRevision: Int, to type: WorkItemType) async throws -> WorkItemSavedInfo {
        let updated = try await database.workItems.reclassify(id, to: type, expectedRevision: expectedRevision,
                                                              actor: userActor, at: clock.now())
        workItemsChanged()
        return Self.saved(updated, message: "Typ: \(updated.type.germanDisplayName).")
    }

    /// Endgültiges Löschen nur für Aufgaben, die nie eine Datei, Nummer, Jobs oder ein GitHub-Issue hatten.
    /// Alles andere wird archiviert, damit Verweise und Verlauf erhalten bleiben.
    func deleteWorkItem(_ id: WorkItemID, expectedRevision: Int) async throws {
        let item = try await requireWorkItem(id)
        guard item.revision == expectedRevision else { throw Self.revisionConflict(item, expected: expectedRevision) }
        guard try await Self.isNeverMaterialized(item, database: database) else { throw ServiceError.workItemAlreadyMaterialized }
        try await database.workItems.delete(id, expectedRevision: expectedRevision, at: clock.now())
        workItemsChanged()
    }

    static func isNeverMaterialized(_ item: WorkItem, database: AppDatabase) async throws -> Bool {
        guard item.humanId == nil, item.agentJobIds.isEmpty else { return false }
        if try await database.documentFiles.fetch(entityId: item.uuid.rawValue) != nil { return false }
        if try await !database.jobs.jobs(forWorkItem: item.uuid).isEmpty { return false }
        if try await database.reviews.issueLink(workItemId: item.uuid) != nil { return false }
        return true
    }

    // MARK: KI-Entwürfe (H3/H4)

    /// Übernimmt einen Entwurf in die Aufgabe (Titel, Inhalt, Priorität wie am iPhone). Startet nie einen Agenten.
    func acceptDraft(_ draftId: DraftVersionID, contentIndex: Int?, expectedRevision: Int) async throws -> WorkItemSavedInfo {
        guard let draft = try await database.draftVersions.fetch(draftId) else { throw ServiceError.draftNotFound(draftId) }
        let item = try await requireWorkItem(draft.workItemId)
        guard item.revision == expectedRevision else { throw Self.revisionConflict(item, expected: expectedRevision) }
        let now = clock.now()
        let updated: WorkItem
        if let contentIndex {
            guard draft.contents.indices.contains(contentIndex) else { throw ServiceError.draftContentMissing }
            let adopter = DraftAdopter(workItems: database.workItems, headings: Self.draftHeadings)
            updated = try await adopter.apply(DraftMapping.structuredDraft(draft.contents[contentIndex]), to: item, actor: userActor, at: now)
        } else {
            guard let text = draft.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ServiceError.draftContentMissing
            }
            updated = try await database.workItems.update(item.uuid, expectedRevision: expectedRevision, actor: userActor, at: now) {
                $0.structuredBody = text
            }
        }
        _ = try await database.draftVersions.accept(draftId, contentIndexes: [contentIndex ?? 0], at: now)
        workItemsChanged()
        return Self.saved(updated, message: "Entwurf Version \(draft.version) übernommen. Es wurde kein Agent gestartet.")
    }

    /// Verwirft einen Entwurf: synchronisierter Verlaufseintrag, die Aufgabe bleibt unverändert.
    func rejectDraft(_ draftId: DraftVersionID) async throws {
        guard let draft = try await database.draftVersions.fetch(draftId) else { throw ServiceError.draftNotFound(draftId) }
        let item = try await requireWorkItem(draft.workItemId)
        let existing = try await database.events.events(forWorkItem: item.uuid).map(\.payload)
        guard !DraftDecisionEvent.rejectedDraftIds(in: existing).contains(draftId.rawValue) else { return }
        try await database.events.append(TaskEvent(
            workItemId: item.uuid, kind: .comment, actor: userActor, timestamp: clock.now(),
            payload: [
                DraftDecisionEvent.decisionKey: DraftDecisionEvent.rejected,
                DraftDecisionEvent.draftIdKey: draftId.uuidString,
                DraftDecisionEvent.versionKey: String(draft.version),
            ],
            sourceRevision: item.revision))
        sendSoon()
    }

    // MARK: Hilfen

    func requireWorkItem(_ id: WorkItemID) async throws -> WorkItem {
        guard let item = try await database.workItems.fetch(id) else { throw ServiceError.workItemNotFound(id) }
        return item
    }

    func requireUsableProject(_ projectId: ProjectID) async throws {
        guard let project = try await database.projects.fetch(projectId), project.status != .archived else {
            throw ServiceError.projectNotUsable(projectId)
        }
    }

    /// Markdown-Abgleich und Senden nach einer Änderung anstoßen.
    func workItemsChanged() {
        housekeepingSignal.signal()
        sendSoon()
    }

    static func revisionConflict(_ item: WorkItem, expected: Int) -> StoreError {
        .revisionConflict(entity: .workItem, id: item.uuid.uuidString, expected: expected, actual: item.revision)
    }

    static func saved(_ item: WorkItem, created: Bool = false, message: String) -> WorkItemSavedInfo {
        WorkItemSavedInfo(workItemId: item.uuid, revision: item.revision, status: item.status, type: item.type,
                          projectId: item.projectId, isArchived: item.isArchived, wasCreated: created, message: message)
    }
}
