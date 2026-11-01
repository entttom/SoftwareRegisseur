import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC

/// Formular „Neue Notiz/Aufgabe“ (H1, F1). Die ID entsteht einmal pro Dialog, damit eine Wiederholung nach
/// einer Zeitüberschreitung keine zweite Aufgabe anlegt (IPC-Protokoll 3).
struct NewWorkItemForm: Hashable, Sendable {
    let workItemId: WorkItemID
    var projectId: ProjectID?
    var type: WorkItemType
    var title = ""
    var text = ""
    var priority: Priority = .medium
    var labelsText = ""

    init(projectId: ProjectID? = nil, type: WorkItemType = .note, workItemId: WorkItemID = WorkItemID()) {
        self.workItemId = workItemId
        self.projectId = projectId
        self.type = type
    }

    /// Ohne eigenen Titel wird die erste Textzeile verwendet (schnelle Notiz aus der Menüleiste).
    var effectiveTitle: String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return String(firstLine.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
    }

    var isValid: Bool { !effectiveTitle.isEmpty }

    var command: CreateWorkItemCommand {
        CreateWorkItemCommand(workItemId: workItemId, projectId: projectId, type: type, title: effectiveTitle, text: text,
                              priority: priority, labels: LabelText.parse(labelsText))
    }
}

/// Labels als kommagetrennter Text.
enum LabelText {
    static func parse(_ text: String) -> [String] {
        WorkItemCommandRules.normalizedLabels(text.split(separator: ",").map(String.init))
    }

    static func format(_ labels: [String]) -> String {
        labels.joined(separator: ", ")
    }
}

/// Bearbeitungsformular mit optimistischer Revision (Pflichtenheft O). `baseRevision` ist der Stand, auf
/// dem die Eingaben beruhen; weicht die Datenbank davon ab, lehnt der Dienst ab und die UI bietet
/// „Neu laden“ an.
struct WorkItemEditForm: Hashable, Sendable {
    let workItemId: WorkItemID
    private(set) var baseRevision: Int
    var title: String
    var body: String
    var priority: Priority
    var labelsText: String
    var dependencies: [WorkItemID]

    init(_ item: WorkItem) {
        workItemId = item.uuid
        baseRevision = item.revision
        title = item.title
        body = item.structuredBody
        priority = item.priority
        labelsText = LabelText.format(item.labels)
        dependencies = item.dependencies
    }

    var isValid: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func hasChanges(comparedTo item: WorkItem) -> Bool {
        title != item.title || body != item.structuredBody || priority != item.priority
            || LabelText.parse(labelsText) != item.labels || dependencies != item.dependencies
    }

    /// Die Aufgabe wurde seit dem Öffnen geändert (z. B. am iPhone oder in der Datei).
    func isStale(comparedTo current: WorkItem) -> Bool { current.revision != baseRevision }

    var command: WorkItemEditCommand {
        WorkItemEditCommand(workItemId: workItemId, expectedRevision: baseRevision, title: title, structuredBody: body,
                            priority: priority, labels: LabelText.parse(labelsText), dependencies: dependencies)
    }

    /// Neu laden: alle Eingaben durch den aktuellen Stand ersetzen.
    mutating func reload(from item: WorkItem) {
        self = WorkItemEditForm(item)
    }

    /// Kandidaten für Abhängigkeiten: andere, nicht archivierte Aufgaben desselben Projekts bzw. der Inbox.
    static func dependencyCandidates(for item: WorkItem, in items: [WorkItem]) -> [WorkItem] {
        items.filter { $0.uuid != item.uuid && $0.projectId == item.projectId && !$0.isArchived }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

/// Welche Aufgabenaktionen gerade möglich sind und warum nicht (keine toten Schaltflächen).
struct WorkItemActionAvailability: Hashable, Sendable {
    var canReclassify: Bool
    var reclassifyReason: String?
    var canAssign: Bool
    var assignReason: String?
    var canDelete: Bool
    var deleteReason: String?

    /// `hasDocument`: Für die Aufgabe existiert eine Request-Datei. `jobCount`: alle Jobs der Aufgabe.
    init(item: WorkItem, hasActiveJob: Bool, hasDocument: Bool, jobCount: Int) {
        if let humanId = item.humanId {
            canReclassify = false
            reclassifyReason = String(localized: "Der Mac hat bereits die Nummer \(humanId.formatted) vergeben (ADR-0018); der Typ ist damit fest. Duplizieren Sie die Aufgabe, um eine Kopie umzuklassifizieren.")
            canAssign = false
            assignReason = String(localized: "Die Nummer \(humanId.formatted) gilt nur in diesem Repository; die Projektzuordnung ist fest. Duplizieren Sie die Aufgabe für ein anderes Projekt.")
        } else if hasActiveJob {
            canReclassify = false
            reclassifyReason = String(localized: "Während ein Agentenjob läuft, bleiben Typ und Projekt unverändert (ADR-0012).")
            canAssign = false
            assignReason = reclassifyReason
        } else {
            canReclassify = true
            reclassifyReason = nil
            canAssign = true
            assignReason = nil
        }
        if item.humanId != nil || hasDocument || jobCount > 0 || !item.agentJobIds.isEmpty {
            canDelete = false
            deleteReason = String(localized: "Endgültig löschen geht nur bei Notizen, für die noch keine Datei, Nummer oder kein Job entstanden ist. Archivieren Sie diese Aufgabe stattdessen.")
        } else {
            canDelete = true
            deleteReason = nil
        }
    }
}

/// Verworfene/übernommene KI-Entwürfe (H3). Verworfen wird über einen synchronisierten Verlaufseintrag.
enum DraftDecisionState: Hashable, Sendable {
    case open
    case accepted
    case rejected

    static func state(of draft: DraftVersion, rejected: Set<UUID>) -> DraftDecisionState {
        if draft.isAccepted { return .accepted }
        if rejected.contains(draft.id.rawValue) { return .rejected }
        return .open
    }

    static func rejectedIds(in events: [TaskEvent]) -> Set<UUID> {
        DraftDecisionEvent.rejectedDraftIds(in: events.map(\.payload))
    }
}

extension CommandOutcome {
    /// Der Dienst hat wegen veralteter Revision abgelehnt (StoreError.revisionConflict).
    var isRevisionConflict: Bool {
        guard case let .failure(message) = feedback else { return false }
        return message.contains("inzwischen geändert")
    }

    /// Neue Revision nach einem Aufgabenbefehl.
    var savedWorkItem: WorkItemSavedInfo? {
        if case let .workItemSaved(info)? = result { return info }
        return nil
    }
}
