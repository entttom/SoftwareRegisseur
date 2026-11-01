import SwiftUI
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC

/// Projektübergreifende Übersicht mit Kanban- und Tabellenansicht (Pflichtenheft D2, P macOS 2).
struct DashboardView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case kanban, table, projects
        var id: Self { self }
        var title: LocalizedStringResource {
            switch self {
            case .kanban: "Kanban"
            case .table: "Tabelle"
            case .projects: "Projekte"
            }
        }
    }

    @Environment(LibraryStore.self) private var library
    @Environment(ServiceMonitor.self) private var monitor
    @Environment(NavigationModel.self) private var navigation
    @SceneStorage("dashboard.mode") private var mode: Mode = .kanban
    @State private var query = TaskQuery()

    var body: some View {
        LibraryGate {
            VStack(alignment: .leading, spacing: 12) {
                StatusCards()
                HStack {
                    AdaptivePicker("Ansicht", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.title).tag($0) }
                    }
                    if mode != .projects {
                        ProjectScopePicker(scope: $query.project)
                            .frame(maxWidth: 260)
                    }
                    Spacer()
                }
                switch mode {
                case .kanban: kanban
                case .table: table
                case .projects: ProjectOverviewTable()
                }
            }
            .padding(16)
            .searchable(text: $query.searchText, prompt: Text("Aufgaben durchsuchen"))
        }
        .toolbar {
            ToolbarItemGroup {
                CommandButton(String(localized: "Jetzt synchronisieren"), systemImage: "arrow.triangle.2.circlepath") { .syncNow }
                CommandButton(String(localized: "Scanner aktualisieren"), systemImage: "magnifyingglass") { .refreshScanner }
            }
        }
    }

    private var filteredItems: [WorkItem] {
        query.apply(to: library.snapshot.workItems)
    }

    private var kanban: some View {
        let board = KanbanBoard(items: filteredItems)
        return Group {
            if library.snapshot.workItems.isEmpty {
                ContentUnavailableView {
                    Label("Noch keine Aufgaben", systemImage: "checklist")
                } description: {
                    Text("Aufgaben entstehen am iPhone oder aus Request-Dateien in Ihren Repositories. Fügen Sie in „Projekte“ einen Stammordner hinzu, damit der Scanner Projekte findet.")
                }
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(board.columns) { column in
                            KanbanColumnView(column: column)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private var table: some View {
        WorkItemTable(items: filteredItems)
    }
}

/// Kennzahlen aus der Statusübersicht des Dienstes und der Datenbank.
private struct StatusCards: View {
    @Environment(ServiceMonitor.self) private var monitor
    @Environment(LibraryStore.self) private var library
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        let state = MacStatePresentation.make(reachable: monitor.isReachable, summary: monitor.currentSummary)
        let snapshot = library.snapshot
        // Wraps into further rows instead of scrolling sideways: in a horizontal ScrollView the last cards were
        // cut off at the window edge without any hint that more follow.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 10, alignment: .topLeading)],
                  alignment: .leading, spacing: 10) {
                card(title: state.title, value: nil, detail: state.detail, level: state.level, symbol: state.symbolName) {
                    navigation.show(.settings)
                }
                if let summary = monitor.currentSummary {
                    let sync = SyncPresentation.make(summary.sync, now: .now)
                    card(title: sync.title, value: nil, detail: sync.detail, level: sync.level, symbol: "icloud") {
                        navigation.show(.settings)
                    }
                    card(title: String(localized: "Aktive Agenten"), value: summary.activeAgentCount,
                         detail: summary.agents.map { "\(AgentPresentation.make($0).name): \($0.activeJobs)" }.joined(separator: " · "),
                         level: summary.activeAgentCount > 0 ? .info : .unknown, symbol: "cpu") {
                        navigation.showQueue(filter: .active)
                    }
                    card(title: String(localized: "Wartend & geplant"), value: summary.queue.waiting + summary.queue.scheduled,
                         detail: QueuePresentation.make(summary.queue, now: .now).nextStartText, level: .info, symbol: "calendar.badge.clock") {
                        navigation.showQueue(filter: .waiting)
                    }
                    card(title: String(localized: "Blockiert & fehlgeschlagen"), value: summary.queue.blocked + summary.queue.failed,
                         detail: nil, level: summary.queue.blocked + summary.queue.failed > 0 ? .error : .ok, symbol: "exclamationmark.triangle") {
                        navigation.showQueue(filter: .problems)
                    }
                    card(title: String(localized: "Offene Freigaben"), value: summary.queue.openApprovals, detail: nil,
                         level: summary.queue.openApprovals > 0 ? .warning : .ok, symbol: "hand.raised") {
                        navigation.showQueue(filter: .active)
                    }
                }
                card(title: String(localized: "Zur Review"), value: snapshot.pendingReviews.count, detail: nil,
                     level: snapshot.pendingReviews.isEmpty ? .ok : .warning, symbol: "eye") {
                    navigation.show(.review)
                }
                card(title: String(localized: "Inbox"), value: snapshot.inboxItems.count, detail: nil, level: .unknown, symbol: "tray") {
                    navigation.show(.inbox)
                }
                if !snapshot.fileConflicts.isEmpty || !snapshot.syncConflicts.isEmpty {
                    card(title: String(localized: "Konflikte"), value: snapshot.fileConflicts.count + snapshot.syncConflicts.count,
                         detail: nil, level: .warning, symbol: "arrow.triangle.branch") {
                        navigation.show(snapshot.fileConflicts.isEmpty ? .settings : .requests)
                    }
                }
        }
        .padding(.bottom, 4)
    }

    private func card(title: String, value: Int?, detail: String?, level: StatusLevel, symbol: String,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: symbol).foregroundStyle(level.color).accessibilityHidden(true)
                    Text(title).font(.callout.weight(.medium)).lineLimit(2)
                }
                if let value {
                    Text(value, format: .number).font(.title.bold())
                }
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

private struct KanbanColumnView: View {
    let column: KanbanBoard.Column

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(column.group.title, systemImage: column.group.symbolName)
                    .font(.headline)
                Spacer()
                Text(column.items.count, format: .number)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            ScrollView {
                LazyVStack(spacing: 6) {
                    if column.items.isEmpty {
                        Text("Leer").foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    ForEach(column.items) { item in
                        KanbanCard(item: item)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 250)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct KanbanCard: View {
    @Environment(LibraryStore.self) private var library
    @Environment(NavigationModel.self) private var navigation
    let item: WorkItem

    var body: some View {
        let snapshot = library.snapshot
        Button {
            navigation.showWorkItem(item)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle)
                    .font(.callout.weight(.medium))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Text(snapshot.projectName(item.projectId))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                FlowLayout(spacing: 4) {
                    Badge(text: item.type.germanDisplayName)
                    Badge(text: item.priority.germanDisplayName, color: item.priority >= .high ? .orange : .secondary)
                    if item.status != .inbox, TaskStatusGroup.group(of: item.status).statuses.count > 1 {
                        Badge(text: item.status.germanDisplayName, color: item.status.level.color)
                    }
                    if let job = snapshot.activeJob(for: item.uuid) {
                        Badge(text: ProviderNames.displayName(job.providerId), color: .blue)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Öffnet die Aufgabe"))
    }
}

/// Tabellenansicht von Aufgaben (Dashboard, Aufgabenliste).
struct WorkItemTable: View {
    @Environment(LibraryStore.self) private var library
    @Environment(NavigationModel.self) private var navigation
    let items: [WorkItem]
    @State private var selection: WorkItemID?

    var body: some View {
        let snapshot = library.snapshot
        Table(items, selection: $selection) {
            TableColumn("ID") { item in Text(item.displayID).monospacedDigit() }
                .width(min: 70, ideal: 90)
            TableColumn("Titel") { item in Text(item.title) }
            TableColumn("Projekt") { item in Text(snapshot.projectName(item.projectId)) }
            TableColumn("Typ") { item in Text(item.type.germanDisplayName) }
                .width(min: 80, ideal: 110)
            TableColumn("Status") { item in
                Text(item.status.germanDisplayName).foregroundStyle(item.status.level.color)
            }
            .width(min: 90, ideal: 130)
            TableColumn("Priorität") { item in Text(item.priority.germanDisplayName) }
                .width(min: 60, ideal: 80)
            TableColumn("Agent") { item in
                Text(snapshot.activeJob(for: item.uuid).map { ProviderNames.displayName($0.providerId) } ?? "–")
            }
            .width(min: 60, ideal: 100)
            TableColumn("Geändert") { item in Text(item.updatedAt.shortDateTime) }
                .width(min: 110, ideal: 140)
        }
        .contextMenu(forSelectionType: WorkItemID.self) { selected in
            if let id = selected.first, let item = snapshot.workItem(id) {
                Button("Öffnen") { navigation.showWorkItem(item) }
            }
        } primaryAction: { selected in
            if let id = selected.first, let item = snapshot.workItem(id) { navigation.showWorkItem(item) }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView("Keine passenden Aufgaben", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
    }
}

/// Projektzusammenfassung als Tabelle (E1: filterbar nach Name, Änderung, offenen Aufgaben, Agentenstatus).
struct ProjectOverviewTable: View {
    @Environment(LibraryStore.self) private var library
    @Environment(NavigationModel.self) private var navigation
    @State private var sort: ProjectSortOrder = .name
    @State private var selection: ProjectID?

    var body: some View {
        let rows = sort.sort(ProjectOverviewRow.rows(snapshot: library.snapshot))
        VStack(alignment: .leading) {
            Picker("Sortieren nach", selection: $sort) {
                ForEach(ProjectSortOrder.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()
            Table(rows, selection: $selection) {
                TableColumn("Projekt") { row in Text(row.name) }
                TableColumn("Status") { row in Text(row.status.germanDisplayName).foregroundStyle(row.status.level.color) }
                TableColumn("Offen") { row in Text(row.openTasks, format: .number) }.width(60)
                TableColumn("In Arbeit") { row in Text(row.inProgress, format: .number) }.width(70)
                TableColumn("Review") { row in Text(row.inReview, format: .number) }.width(60)
                TableColumn("Agenten aktiv") { row in Text(row.activeAgents, format: .number) }.width(90)
                TableColumn("Letzte Änderung") { row in Text(row.lastChange.shortDateTime) }
            }
            .contextMenu(forSelectionType: ProjectID.self) { _ in
            } primaryAction: { selected in
                if let id = selected.first { navigation.showProject(id) }
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView("Noch keine Projekte", systemImage: "folder",
                                           description: Text("Fügen Sie unter „Projekte“ einen Stammordner hinzu."))
                }
            }
        }
    }
}

/// Auswahl „Alle Projekte / Inbox / Projekt“.
struct ProjectScopePicker: View {
    @Environment(LibraryStore.self) private var library
    @Binding var scope: TaskQuery.ProjectScope

    var body: some View {
        Picker("Projekt", selection: $scope) {
            Text("Alle Projekte").tag(TaskQuery.ProjectScope.any)
            Text("Inbox (ohne Projekt)").tag(TaskQuery.ProjectScope.inbox)
            Divider()
            ForEach(library.snapshot.projects) { entry in
                Text(entry.project.name).tag(TaskQuery.ProjectScope.project(entry.id))
            }
        }
    }
}
