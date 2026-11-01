import SwiftUI
import SoftwareRegisseurAppCore
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

/// Edits the user-owned fields (spec H1). Type, original note and number are fixed by design.
struct TaskEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: WorkItem
    let onSaved: (WorkItemEdit) -> Void

    @State private var edit: WorkItemEdit
    @State private var labelsText: String
    @State private var catalog = Catalog()
    @State private var error: String?

    init(item: WorkItem, onSaved: @escaping (WorkItemEdit) -> Void) {
        self.item = item
        self.onSaved = onSaved
        _edit = State(initialValue: WorkItemEdit(item))
        _labelsText = State(initialValue: item.labels.joined(separator: ", "))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Titel", text: $edit.title, axis: .vertical)
                    Picker(selection: $edit.priority) {
                        ForEach(Priority.allCases, id: \.self) { Text($0.title).tag($0) }
                    } label: {
                        Text("Priorität")
                    }
                    Picker(selection: $edit.complexity) {
                        Text("Nicht angegeben").tag(TaskComplexity?.none)
                        ForEach(TaskComplexity.allCases, id: \.self) { Text($0.title).tag(TaskComplexity?.some($0)) }
                    } label: {
                        Text("Komplexität (Planung)")
                    }
                    TextField("Labels, durch Komma getrennt", text: $labelsText)
                        .textInputAutocapitalization(.never)
                }
                Section {
                    Picker(selection: $edit.projectId) {
                        Text("Kein Projekt (Inbox)").tag(ProjectID?.none)
                        ForEach(catalog.projects.filter { $0.status != .archived }) { project in
                            Text(verbatim: project.name).tag(ProjectID?.some(project.id))
                        }
                    } label: {
                        Text("Projekt")
                    }
                    .disabled(item.humanId != nil)
                } footer: {
                    if item.humanId != nil {
                        Text("Aufgaben mit vergebener Nummer bleiben im Projekt (Nummern sind pro Repository eindeutig).")
                    }
                }
                Section {
                    let candidates = catalog.items.filter { $0.uuid != item.uuid && $0.projectId == edit.projectId }
                    if candidates.isEmpty {
                        Text("Keine anderen Aufgaben im selben Projekt.").foregroundStyle(.secondary)
                    }
                    ForEach(candidates) { other in
                        Toggle(isOn: Binding(
                            get: { edit.dependencies.contains(other.uuid) },
                            set: { on in
                                if on { edit.dependencies.append(other.uuid) } else { edit.dependencies.removeAll { $0 == other.uuid } }
                            }
                        )) {
                            Text(verbatim: other.title)
                        }
                    }
                } header: {
                    Text("Abhängig von")
                }
                Section {
                    TextEditor(text: $edit.structuredBody)
                        .frame(minHeight: 160)
                        .font(.body.monospaced())
                } header: {
                    Text("Beschreibung (Markdown)")
                }
                if item.transcript != nil {
                    Section {
                        TextEditor(text: Binding(get: { edit.transcript ?? "" }, set: { edit.transcript = $0 }))
                            .frame(minHeight: 100)
                    } header: {
                        Text("Transkript")
                    }
                }
                Section {
                    Text(verbatim: item.originalNote.isEmpty ? "–" : item.originalNote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Originalnotiz (unveränderlich)")
                }
                if let error { ErrorText(message: error) }
            }
            .navigationTitle("Bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") { Task { await save() } }
                        .disabled(edit.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .task { catalog = (try? await model.loadCatalog(includeAgents: false)) ?? Catalog() }
        }
    }

    private func save() async {
        guard let database = model.database else { return }
        edit.labels = labelsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        do {
            let current = try await database.workItems.fetch(item.uuid) ?? item
            let (_, previous) = try await TaskEditor(workItems: database.workItems).save(edit, to: current, actor: model.actor, at: .now)
            model.noteLocalChange()
            onSaved(previous)
            dismiss()
        } catch {
            self.error = errorMessage(error)
        }
    }
}

/// Assigns an inbox note to a project later (spec H1, P 3).
struct AssignProjectView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: WorkItem
    @State private var projects: [Project] = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if projects.isEmpty {
                    ContentUnavailableView("Keine Projekte", systemImage: "folder",
                                           description: Text("Legen Sie unter „Projekte“ einen Entwurf an oder warten Sie auf die Synchronisierung vom Mac."))
                }
                ForEach(projects) { project in
                    Button {
                        Task { await assign(project) }
                    } label: {
                        ProjectRow(project: project, host: nil)
                    }
                }
                if let error { ErrorText(message: error) }
            }
            .navigationTitle("Projekt zuweisen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
            }
            .task {
                projects = ((try? await model.database?.projects.list()) ?? []).filter { $0.status != .archived }
            }
        }
    }

    private func assign(_ project: Project) async {
        guard let database = model.database else { return }
        do {
            let current = try await database.workItems.fetch(item.uuid) ?? item
            _ = try await TaskEditor(workItems: database.workItems).assign(current, to: project.id, actor: model.actor, at: .now)
            model.noteLocalChange()
            dismiss()
        } catch {
            self.error = errorMessage(error)
        }
    }
}

/// Quick capture by text (spec H1: „Schnellerfassung über prominente Aktion“). Works offline.
struct QuickCaptureView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let defaultProject: ProjectID?

    @State private var text = ""
    @State private var type: WorkItemType = .note
    @State private var projectID: ProjectID?
    @State private var projects: [Project] = []
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Idee, Aufgabe oder Fehler beschreiben …", text: $text, axis: .vertical)
                        .lineLimit(4...12)
                        .focused($focused)
                        .accessibilityIdentifier("quickCapture.text")
                }
                Section {
                    Picker(selection: $type) {
                        ForEach(WorkItemType.allCases, id: \.self) { Text($0.title).tag($0) }
                    } label: {
                        Text("Typ")
                    }
                    Picker(selection: $projectID) {
                        Text("Ohne Projekt (Inbox)").tag(ProjectID?.none)
                        ForEach(projects) { Text(verbatim: $0.name).tag(ProjectID?.some($0.id)) }
                    } label: {
                        Text("Projekt")
                    }
                } footer: {
                    Text("Die Nummer (z. B. FR-0001) vergibt der Mac beim Anlegen der Request-Datei.")
                }
                if let error { ErrorText(message: error) }
            }
            // Short title: between „Abbrechen“ and „Sichern“ „Schnell erfassen“ was cut off on the iPhone.
            .navigationTitle("Erfassen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") { Task { await save() } }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("quickCapture.save")
                }
            }
            .task {
                projectID = defaultProject
                projects = ((try? await model.database?.projects.list()) ?? []).filter { $0.status != .archived }
                focused = true
            }
        }
    }

    private func save() async {
        guard let database = model.database else { return }
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = WorkItem(projectId: projectID, type: type, title: CaptureTitle.make(from: note), originalNote: note,
                            status: projectID == nil ? .inbox : .open, createdAt: .now)
        do {
            try await database.workItems.insert(item, actor: model.actor, at: .now)
            model.noteLocalChange()
            dismiss()
        } catch {
            self.error = errorMessage(error)
        }
    }
}

enum CaptureTitle {
    /// First line, at most 80 characters.
    static func make(from note: String) -> String {
        let firstLine = note.split(whereSeparator: \.isNewline).first.map(String.init) ?? note
        return firstLine.count > 80 ? String(firstLine.prefix(79)) + "…" : firstLine
    }
}

/// Open sync conflicts (spec N2/N3, A24).
struct ConflictListView: View {
    @Environment(AppModel.self) private var model
    @State private var conflicts: [SyncConflict] = []
    @State private var error: String?

    var body: some View {
        List {
            if let error { ErrorText(message: error) }
            if conflicts.isEmpty {
                ContentUnavailableView("Keine offenen Konflikte", systemImage: "checkmark.icloud")
            }
            ForEach(conflicts) { conflict in
                NavigationLink {
                    ConflictResolutionView(conflict: conflict)
                } label: {
                    VStack(alignment: .leading) {
                        Text(conflict.entityType.title)
                        Text(conflict.detectedAt, format: .dateTime).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Konflikte")
        .reloadOnDataChange {
            do {
                conflicts = try await model.database?.sync.openConflicts() ?? []
            } catch {
                self.error = errorMessage(error)
            }
        }
    }
}

/// Shows both versions and lets the user decide; nothing is resolved silently.
struct ConflictResolutionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let conflict: SyncConflict
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Text("Dieser Eintrag wurde auf zwei Geräten gleichzeitig geändert. Beide Fassungen sind erhalten; wählen Sie, welche gilt.")
            }
            if conflict.entityType == .workItem, let comparison = try? WorkItemConflictComparison(conflict: conflict) {
                ForEach(comparison.differingFields, id: \.self) { field in
                    Section {
                        LabeledContent { Text(verbatim: value(field, comparison.local)) } label: {
                            Text(DeviceKind.current.pick(phone: "Dieses iPhone", pad: "Dieses iPad") as LocalizedStringResource)
                        }
                        LabeledContent { Text(verbatim: value(field, comparison.remote)) } label: { Text("Anderes Gerät") }
                    } header: {
                        Text(field.title)
                    }
                }
            } else {
                Section {
                    LabeledContent { Text(conflict.entityType.title) } label: { Text("Datensatz") }
                    LabeledContent { Text("\(conflict.localVersion) / \(conflict.remoteVersion)") } label: { Text("Versionen lokal/entfernt") }
                    if conflict.remotePayload == nil {
                        Text("Auf dem anderen Gerät wurde der Eintrag gelöscht.")
                    }
                }
            }
            Section {
                Button {
                    Task { await resolve(.keepLocal) }
                } label: {
                    Text(DeviceKind.current.pick(phone: "Fassung dieses iPhones behalten", pad: "Fassung dieses iPads behalten") as LocalizedStringResource)
                }
                Button("Fassung des anderen Geräts übernehmen") { Task { await resolve(.acceptRemote) } }
            }
            if let error { ErrorText(message: error) }
        }
        .navigationTitle("Konflikt lösen")
    }

    private func value(_ field: WorkItemConflictComparison.Field, _ item: WorkItem?) -> String {
        guard let item else { return String(localized: "gelöscht") }
        switch field {
        case .title: return item.title
        case .status: return String(localized: item.status.title)
        case .priority: return String(localized: item.priority.title)
        case .transcript: return item.transcript ?? "–"
        case .structuredBody: return item.structuredBody.isEmpty ? "–" : item.structuredBody
        case .labels: return item.labels.joined(separator: ", ")
        case .dependencies: return "\(item.dependencies.count)"
        case .projectId: return item.projectId?.uuidString ?? String(localized: "Kein Projekt (Inbox)")
        case .reviewState: return item.reviewState.rawValue
        case .complexity: return item.complexity.map { String(localized: $0.title) } ?? "–"
        }
    }

    private func resolve(_ resolution: ConflictResolution) async {
        do {
            try await model.resolveConflict(conflict.id, resolution: resolution)
            dismiss()
        } catch {
            self.error = errorMessage(error)
        }
    }
}
