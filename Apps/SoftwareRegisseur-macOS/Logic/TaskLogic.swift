import Foundation
import SoftwareRegisseurDomain

/// Statusgruppen für Filter und Kanban (F5, ADR-0012: nur Aufgabenstatus, keine Jobzustände).
enum TaskStatusGroup: String, CaseIterable, Identifiable, Hashable, Sendable {
    case inbox
    case open
    case planned
    case inProgress
    case review
    case integrated
    case done
    case attention
    case cancelled

    var id: Self { self }

    var title: String {
        switch self {
        case .inbox: String(localized: "Inbox")
        case .open: String(localized: "Offen")
        case .planned: String(localized: "Eingeplant")
        case .inProgress: String(localized: "In Arbeit")
        case .review: String(localized: "Review")
        case .integrated: String(localized: "Integriert")
        case .done: String(localized: "Erledigt")
        case .attention: String(localized: "Braucht Aufmerksamkeit")
        case .cancelled: String(localized: "Abgebrochen")
        }
    }

    var symbolName: String {
        switch self {
        case .inbox: "tray"
        case .open: "circle"
        case .planned: "calendar.badge.clock"
        case .inProgress: "gearshape.2"
        case .review: "eye"
        case .integrated: "arrow.triangle.merge"
        case .done: "checkmark.circle"
        case .attention: "exclamationmark.triangle"
        case .cancelled: "xmark.circle"
        }
    }

    var statuses: Set<WorkItemStatus> {
        switch self {
        case .inbox: [.inbox]
        case .open: [.open]
        case .planned: [.queued, .scheduled]
        case .inProgress: [.inProgress, .waitingApproval]
        case .review: [.implementationFinished, .review]
        case .integrated: [.integrated]
        case .done: [.done]
        case .attention: [.blocked, .failed, .paused]
        case .cancelled: [.cancelled]
        }
    }

    static func group(of status: WorkItemStatus) -> TaskStatusGroup {
        allCases.first { $0.statuses.contains(status) } ?? .open
    }
}

enum TaskSortOrder: String, CaseIterable, Identifiable, Hashable, Sendable {
    case updated
    case created
    case priority
    case title
    case identifier

    var id: Self { self }

    var title: String {
        switch self {
        case .updated: String(localized: "Zuletzt geändert")
        case .created: String(localized: "Zuletzt angelegt")
        case .priority: String(localized: "Priorität")
        case .title: String(localized: "Titel")
        case .identifier: String(localized: "ID")
        }
    }
}

/// Filter, Suche und Sortierung der Aufgabenliste (Pflichtenheft D2, E1: filterbar und sortierbar).
struct TaskQuery: Hashable, Sendable {
    enum ProjectScope: Hashable, Sendable {
        case any
        case inbox
        case project(ProjectID)
    }

    var project: ProjectScope = .any
    var groups: Set<TaskStatusGroup> = []
    var types: Set<WorkItemType> = []
    var priorities: Set<Priority> = []
    var label: String?
    var searchText = ""
    var includeArchived = false
    var sort: TaskSortOrder = .updated

    var isFiltering: Bool {
        project != .any || !groups.isEmpty || !types.isEmpty || !priorities.isEmpty || label != nil
            || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || includeArchived
    }

    func matches(_ item: WorkItem) -> Bool {
        if item.isArchived, !includeArchived { return false }
        switch project {
        case .any: break
        case .inbox: if item.projectId != nil { return false }
        case let .project(id): if item.projectId != id { return false }
        }
        if !groups.isEmpty, !groups.contains(TaskStatusGroup.group(of: item.status)) { return false }
        if !types.isEmpty, !types.contains(item.type) { return false }
        if !priorities.isEmpty, !priorities.contains(item.priority) { return false }
        if let label, !item.labels.contains(label) { return false }
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty {
            let haystack = [item.title, item.originalNote, item.transcript ?? "", item.structuredBody,
                            item.humanId?.formatted ?? "", item.labels.joined(separator: " ")]
            guard haystack.contains(where: { $0.localizedStandardContains(needle) }) else { return false }
        }
        return true
    }

    func apply(to items: [WorkItem]) -> [WorkItem] {
        items.filter(matches).sorted(by: Self.comparator(sort))
    }

    static func comparator(_ order: TaskSortOrder) -> (WorkItem, WorkItem) -> Bool {
        switch order {
        case .updated:
            return { ($0.updatedAt, $0.uuid.uuidString) > ($1.updatedAt, $1.uuid.uuidString) }
        case .created:
            return { ($0.createdAt, $0.uuid.uuidString) > ($1.createdAt, $1.uuid.uuidString) }
        case .priority:
            return { lhs, rhs in
                lhs.priority != rhs.priority ? lhs.priority > rhs.priority : lhs.updatedAt > rhs.updatedAt
            }
        case .title:
            return { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .identifier:
            return { lhs, rhs in
                switch (lhs.humanId, rhs.humanId) {
                case let (left?, right?): left < right
                case (.some, nil): true
                case (nil, .some): false
                case (nil, nil): lhs.createdAt < rhs.createdAt
                }
            }
        }
    }

    static func labels(in items: [WorkItem]) -> [String] {
        Array(Set(items.flatMap(\.labels))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// Kanban-Spalten des Dashboards (P: projektübergreifende Kanban-Ansicht).
struct KanbanBoard: Hashable, Sendable {
    struct Column: Hashable, Sendable, Identifiable {
        var group: TaskStatusGroup
        var items: [WorkItem]
        var id: TaskStatusGroup { group }
    }

    var columns: [Column]

    /// `hideEmptyTerminal`: leere Spalten „Abgebrochen“ blendet das Board aus, alle anderen bleiben sichtbar.
    init(items: [WorkItem], limitPerColumn: Int? = nil) {
        var grouped: [TaskStatusGroup: [WorkItem]] = [:]
        for item in items where !item.isArchived {
            grouped[TaskStatusGroup.group(of: item.status), default: []].append(item)
        }
        columns = TaskStatusGroup.allCases.compactMap { group in
            let items = (grouped[group] ?? []).sorted(by: TaskQuery.comparator(.priority))
            if group == .cancelled, items.isEmpty { return nil }
            if let limitPerColumn { return Column(group: group, items: Array(items.prefix(limitPerColumn))) }
            return Column(group: group, items: items)
        }
    }

    func count(_ group: TaskStatusGroup) -> Int {
        columns.first { $0.group == group }?.items.count ?? 0
    }
}

/// Zusammenfassung je Projekt für Dashboard und Projektübersicht (E1: Name, Änderung, offene Aufgaben, Agentenstatus).
struct ProjectOverviewRow: Hashable, Sendable, Identifiable {
    var projectId: ProjectID
    var name: String
    var status: ProjectStatus
    var openTasks: Int
    var inProgress: Int
    var inReview: Int
    var activeAgents: Int
    var lastChange: Date

    var id: ProjectID { projectId }

    static func rows(snapshot: LibrarySnapshot) -> [ProjectOverviewRow] {
        snapshot.projects.map { entry in
            let items = snapshot.workItems.filter { $0.projectId == entry.id && !$0.isArchived }
            let active = snapshot.jobs.filter { $0.projectId == entry.id && QueueFilter.active.states.contains($0.state) }
            let lastChange = ([entry.project.updatedAt] + items.map(\.updatedAt)).max() ?? entry.project.updatedAt
            return ProjectOverviewRow(
                projectId: entry.id,
                name: entry.project.name,
                status: entry.project.status,
                openTasks: items.filter { ![.done, .cancelled, .integrated].contains($0.status) }.count,
                inProgress: items.filter { TaskStatusGroup.group(of: $0.status) == .inProgress }.count,
                inReview: items.filter { TaskStatusGroup.group(of: $0.status) == .review }.count,
                activeAgents: active.count,
                lastChange: lastChange
            )
        }
    }
}

enum ProjectSortOrder: String, CaseIterable, Identifiable, Hashable, Sendable {
    case name
    case lastChange
    case openTasks
    case agents

    var id: Self { self }

    var title: String {
        switch self {
        case .name: String(localized: "Name")
        case .lastChange: String(localized: "Letzte Änderung")
        case .openTasks: String(localized: "Offene Aufgaben")
        case .agents: String(localized: "Aktive Agenten")
        }
    }

    func sort(_ rows: [ProjectOverviewRow]) -> [ProjectOverviewRow] {
        rows.sorted { lhs, rhs in
            switch self {
            case .name: lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .lastChange: lhs.lastChange > rhs.lastChange
            case .openTasks: lhs.openTasks != rhs.openTasks ? lhs.openTasks > rhs.openTasks : lhs.name < rhs.name
            case .agents: lhs.activeAgents != rhs.activeAgents ? lhs.activeAgents > rhs.activeAgents : lhs.name < rhs.name
            }
        }
    }
}

/// Manuelle Statuswechsel (F5, L1, ADR-0012): erlaubte Ziele und Sperrhinweis.
struct StatusChangeOptions: Hashable, Sendable {
    var allowedTargets: [WorkItemStatus]
    /// Deutscher Grund, warum gerade kein manueller Wechsel möglich ist.
    var blockReason: String?

    init(item: WorkItem, activeJob: AgentJob?, lock: TaskLock?) {
        if let activeJob {
            allowedTargets = []
            blockReason = String(localized: "Ein Agentenjob ist aktiv (\(activeJob.state.germanDisplayName)). Der Status folgt dem Job; manuelle Änderungen werden abgelehnt (ADR-0012).")
            return
        }
        if let lock, !lock.isReleased {
            allowedTargets = []
            blockReason = String(localized: "Die Aufgabe ist gesperrt (\(lock.scope.displayName), seit \(lock.acquiredAt.formatted(date: .abbreviated, time: .shortened))). Änderungen bitte als neue Notiz erfassen.")
            return
        }
        // `integrated` setzt nur der Dienst nach echter Integration (M1); `done` nach Integration nur über „Als erledigt markieren“.
        let hostOnly: Set<WorkItemStatus> = [.integrated, .queued, .scheduled, .inProgress, .waitingApproval, .implementationFinished]
        allowedTargets = WorkItemStatus.allCases.filter { item.status.canTransition(to: $0) && !hostOnly.contains($0) }
        blockReason = nil
    }
}
