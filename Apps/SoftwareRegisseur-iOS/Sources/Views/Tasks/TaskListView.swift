import SwiftUI
import SoftwareRegisseurAppCore
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

/// „Aufgaben“ (spec P 4, H1): filter/search by project, status, type, label, priority, agent.
struct TaskListView: View {
    @Environment(AppModel.self) private var model
    let title: LocalizedStringResource
    @State private var filter: TaskFilter
    @State private var statusGroup: TaskFilter.StatusGroup = .all
    @State private var items: [WorkItem] = []
    @State private var catalog = Catalog()
    @State private var labels: [String] = []
    @State private var error: String?
    @State private var showsFilter = false
    @State private var showsCapture = false
    @FocusState private var searchFocused: Bool
    /// Root of the „Aufgaben“ section: takes the ⌘F search focus.
    private let isSectionRoot: Bool

    init(initialFilter: TaskFilter, title: LocalizedStringResource, isSectionRoot: Bool = false) {
        _filter = State(initialValue: initialFilter)
        self.title = title
        self.isSectionRoot = isSectionRoot
    }

    var body: some View {
        RouteList {
            Section {
                Picker(selection: $statusGroup) {
                    Text("Alle").tag(TaskFilter.StatusGroup.all)
                    Text("Offen").tag(TaskFilter.StatusGroup.open)
                    Text("Aktiv").tag(TaskFilter.StatusGroup.active)
                    Text("Review").tag(TaskFilter.StatusGroup.review)
                    Text("Fertig").tag(TaskFilter.StatusGroup.finished)
                } label: {
                    Text("Status")
                }
                .pickerStyle(.segmented)
                if filter.isActive {
                    Button("Filter zurücksetzen") {
                        let project = filter.project
                        filter = TaskFilter(project: project)
                        statusGroup = .all
                    }
                }
            }
            if let error { ErrorText(message: error) }
            if items.isEmpty {
                ContentUnavailableView {
                    Label(filter.isActive ? "Keine Treffer" : "Keine Aufgaben", systemImage: "checklist")
                } description: {
                    Text(filter.isActive
                        ? "Keine Aufgabe passt zu Suche und Filter."
                        : "Erfassen Sie eine Idee über „+“, die Inbox oder das Diktat.")
                }
            }
            ForEach(items) { item in
                NavigationLink(value: AppRoute.task(item.uuid)) {
                    WorkItemRow(item: item, projectName: catalog.projectName(item.projectId))
                }
            }
        }
        .navigationTitle(Text(title))
        .sectionSearchable(text: $filter.searchText, prompt: Text("Titel, Notiz, Transkript"))
        .searchFocused($searchFocused)
        .onChange(of: model.pendingSearch, initial: true) { _, pending in
            guard isSectionRoot, pending == .tasks else { return }
            model.pendingSearch = nil
            searchFocused = true
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsCapture = true
                } label: {
                    Label("Neue Aufgabe", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    showsFilter = true
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .sheet(isPresented: $showsFilter) {
            TaskFilterSheet(filter: $filter, catalog: catalog, labels: labels)
        }
        .sheet(isPresented: $showsCapture) {
            if case let .project(id) = filter.project {
                QuickCaptureView(defaultProject: id)
            } else {
                QuickCaptureView(defaultProject: nil)
            }
        }
        .onChange(of: statusGroup) { _, group in filter.statuses = group.statuses }
        .task(id: filter) { await load() }
        .refreshable { await model.sync(.pullToRefresh) }
        .reloadOnDataChange { await load() }
    }

    private func load() async {
        guard let database = model.database else { return }
        do {
            catalog = try await model.loadCatalog(includeAgents: true)
            items = try await TaskQuery(workItems: database.workItems, jobs: database.jobs).run(filter)
            labels = TaskFilter.labels(in: catalog.items)
            error = nil
        } catch {
            self.error = errorMessage(error)
        }
    }
}

struct TaskFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var filter: TaskFilter
    let catalog: Catalog
    let labels: [String]

    var body: some View {
        NavigationStack {
            Form {
                Picker(selection: $filter.project) {
                    Text("Alle Projekte").tag(TaskFilter.ProjectScope.any)
                    Text("Ohne Projekt (Inbox)").tag(TaskFilter.ProjectScope.withoutProject)
                    ForEach(catalog.projects) { project in
                        Text(verbatim: project.name).tag(TaskFilter.ProjectScope.project(project.id))
                    }
                } label: {
                    Text("Projekt")
                }
                Section {
                    ForEach(WorkItemStatus.allCases, id: \.self) { status in
                        Toggle(isOn: binding(for: status, in: \.statuses)) { Text(status.title) }
                    }
                } header: {
                    Text("Status")
                }
                Section {
                    ForEach(WorkItemType.allCases, id: \.self) { type in
                        Toggle(isOn: binding(for: type, in: \.types)) { Text(type.title) }
                    }
                } header: {
                    Text("Typ")
                }
                Section {
                    ForEach(Priority.allCases.reversed(), id: \.self) { priority in
                        Toggle(isOn: binding(for: priority, in: \.priorities)) { Text(priority.title) }
                    }
                } header: {
                    Text("Priorität")
                }
                Picker(selection: $filter.label) {
                    Text("Alle Labels").tag(String?.none)
                    ForEach(labels, id: \.self) { Text(verbatim: $0).tag(String?.some($0)) }
                } label: {
                    Text("Label")
                }
                Picker(selection: $filter.agent) {
                    Text("Alle Agenten").tag(ProviderID?.none)
                    ForEach(Array(Set(catalog.jobs.map(\.providerId) + catalog.capabilities.map(\.providerId))).sorted(), id: \.self) {
                        Text(verbatim: $0.rawValue).tag(ProviderID?.some($0))
                    }
                } label: {
                    Text("Agent")
                }
            }
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Zurücksetzen") {
                        filter = TaskFilter(searchText: filter.searchText)
                    }
                }
            }
        }
    }

    private func binding<Value: Hashable>(for value: Value, in keyPath: WritableKeyPath<TaskFilter, Set<Value>>) -> Binding<Bool> {
        Binding(
            get: { filter[keyPath: keyPath].contains(value) },
            set: { isOn in
                if isOn { filter[keyPath: keyPath].insert(value) } else { filter[keyPath: keyPath].remove(value) }
            }
        )
    }
}
