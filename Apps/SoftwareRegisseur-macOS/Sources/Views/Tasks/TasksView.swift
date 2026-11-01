import SwiftUI
import SoftwareRegisseurDomain

/// Aufgaben/Requests mit Filter, Suche und Sortierung (D2, P macOS 4).
struct TasksView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(NavigationModel.self) private var navigation
    @State private var query = TaskQuery()

    var body: some View {
        @Bindable var navigation = navigation
        LibraryGate {
            TaskSplitView(query: $query, selection: $navigation.selectedWorkItem, emptyText: String(localized: "Keine Aufgaben"))
        }
    }
}

/// Inbox: spontane Notizen ohne Projekt (P: später zuweisen).
struct InboxView: View {
    @Environment(NavigationModel.self) private var navigation
    @State private var query = TaskQuery(project: .inbox)

    var body: some View {
        @Bindable var navigation = navigation
        LibraryGate {
            TaskSplitView(query: $query, selection: $navigation.selectedInboxItem, lockProjectScope: true,
                          emptyText: String(localized: "Die Inbox ist leer"))
        }
    }
}

/// Liste links, Detail rechts.
struct TaskSplitView: View {
    @Environment(LibraryStore.self) private var library
    @Binding var query: TaskQuery
    @Binding var selection: WorkItemID?
    var lockProjectScope = false
    let emptyText: String
    @State private var showNewItem = false

    var body: some View {
        let items = query.apply(to: library.snapshot.workItems)
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button {
                        showNewItem = true
                    } label: {
                        Label(lockProjectScope ? "Neue Notiz …" : "Neue Aufgabe …", systemImage: "square.and.pencil")
                    }
                    .keyboardShortcut("n", modifiers: .command)
                }
                .padding([.horizontal, .top], 8)
                TaskFilterBar(query: $query, lockProjectScope: lockProjectScope,
                              labels: TaskQuery.labels(in: library.snapshot.workItems))
                Divider()
                List(selection: $selection) {
                    ForEach(items) { item in
                        TaskRow(item: item).tag(item.uuid)
                    }
                }
                .overlay {
                    if items.isEmpty {
                        ContentUnavailableView {
                            Label(emptyText, systemImage: "checklist")
                        } description: {
                            if query.isFiltering && !library.snapshot.workItems.isEmpty {
                                Text("Kein Eintrag passt zu Filter und Suche.")
                            } else {
                                Text("Aufgaben entstehen hier mit „Neu …“, am iPhone, aus Request-Dateien im Repository oder aus GitHub-Importen.")
                            }
                        }
                    }
                }
                Text("\(items.count) Einträge")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
            .frame(minWidth: 240, idealWidth: 380, maxWidth: 520)
            Group {
                if let selection, let item = library.snapshot.workItem(selection) {
                    TaskDetailView(item: item).id(selection)
                } else {
                    ContentUnavailableView("Aufgabe auswählen", systemImage: "doc.text.magnifyingglass")
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .splitViewMinimum(width: 240 + 360)
        .sheet(isPresented: $showNewItem) {
            NewWorkItemSheet(projectId: projectScopeId)
        }
    }

    private var projectScopeId: ProjectID? {
        if case let .project(id) = query.project { return id }
        return nil
    }
}

private struct TaskFilterBar: View {
    @Binding var query: TaskQuery
    let lockProjectScope: Bool
    let labels: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Suchen (Titel, Text, ID, Label)", text: $query.searchText)
                .textFieldStyle(.roundedBorder)
            // Umbrechend: in der schmalen Listenspalte ragten Auswahl und Filter sonst links aus der Spalte.
            FlowLayout(spacing: 6) {
                if !lockProjectScope {
                    ProjectScopePicker(scope: $query.project).labelsHidden()
                }
                Picker("Sortierung", selection: $query.sort) {
                    ForEach(TaskSortOrder.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            FlowLayout(spacing: 6) {
                multiMenu(String(localized: "Status"), all: TaskStatusGroup.allCases, selection: $query.groups) { $0.title }
                multiMenu(String(localized: "Typ"), all: WorkItemType.allCases, selection: $query.types) { $0.germanDisplayName }
                multiMenu(String(localized: "Priorität"), all: Priority.allCases, selection: $query.priorities) { $0.germanDisplayName }
                if !labels.isEmpty {
                    Menu {
                        Button("Alle Labels") { query.label = nil }
                        ForEach(labels, id: \.self) { label in
                            Button(label) { query.label = label }
                        }
                    } label: {
                        Text(query.label ?? String(localized: "Label"))
                    }
                    .fixedSize()
                }
                Toggle("Archivierte", isOn: $query.includeArchived)
                    .toggleStyle(.checkbox)
            }
            .controlSize(.small)
        }
        .padding(8)
    }

    private func multiMenu<Value: Hashable>(_ title: String, all: [Value], selection: Binding<Set<Value>>,
                                            name: @escaping (Value) -> String) -> some View {
        Menu {
            ForEach(all, id: \.self) { value in
                Toggle(name(value), isOn: Binding(
                    get: { selection.wrappedValue.contains(value) },
                    set: { isOn in
                        if isOn { selection.wrappedValue.insert(value) } else { selection.wrappedValue.remove(value) }
                    }
                ))
            }
            if !selection.wrappedValue.isEmpty {
                Divider()
                Button("Filter zurücksetzen") { selection.wrappedValue.removeAll() }
            }
        } label: {
            Text(selection.wrappedValue.isEmpty ? title : "\(title) (\(selection.wrappedValue.count))")
        }
        .fixedSize()
    }
}

struct TaskRow: View {
    @Environment(LibraryStore.self) private var library
    let item: WorkItem

    var body: some View {
        let snapshot = library.snapshot
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.displayTitle).font(.headline).lineLimit(2)
                Spacer()
                if snapshot.lock(for: item.uuid, projectId: item.projectId) != nil {
                    Image(systemName: "lock.fill").foregroundStyle(.orange).accessibilityLabel(Text("Gesperrt"))
                }
                if !snapshot.fileConflicts(for: item.uuid).isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityLabel(Text("Konflikt"))
                }
            }
            FlowLayout(spacing: 4) {
                Badge(text: item.status.germanDisplayName, color: item.status.level.color)
                Badge(text: item.type.germanDisplayName)
                if item.priority >= .high { Badge(text: item.priority.germanDisplayName, color: .orange) }
                if item.isArchived { Badge(text: String(localized: "Archiviert")) }
            }
            Text("\(snapshot.projectName(item.projectId)) · \(item.updatedAt.shortDateTime)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
