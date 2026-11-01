import SwiftUI
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC

/// Aufgabenaktionen am Mac (IPC-Protokoll 3): Bearbeiten, Status, Projekt, Typ, Duplizieren, Archivieren,
/// Löschen. Nicht mögliche Aktionen sind deaktiviert und darunter erklärt.
struct WorkItemCommandBar: View {
    @Environment(LibraryStore.self) private var library
    @Environment(CommandCenter.self) private var commands
    let item: WorkItem
    let hasDocument: Bool
    @State private var showEditor = false
    @State private var confirmDelete = false

    var body: some View {
        let snapshot = library.snapshot
        let options = StatusChangeOptions(item: item, activeJob: snapshot.activeJob(for: item.uuid),
                                          lock: snapshot.lock(for: item.uuid, projectId: item.projectId))
        let availability = WorkItemActionAvailability(item: item, hasActiveJob: snapshot.activeJob(for: item.uuid) != nil,
                                                      hasDocument: hasDocument, jobCount: snapshot.jobs(for: item.uuid).count)
        VStack(alignment: .leading, spacing: 4) {
            // Umbrechend: im schmalen Fenster wurde „Bearbeiten …“ sonst bis auf „B“ gekürzt.
            FlowLayout(spacing: 6) {
                Button {
                    showEditor = true
                } label: {
                    Label("Bearbeiten …", systemImage: "square.and.pencil")
                }
                Menu {
                    ForEach(options.allowedTargets, id: \.self) { status in
                        Button(status.germanDisplayName) {
                            run(String(localized: "Status ändern"),
                                .changeWorkItemStatus(workItemId: item.uuid, expectedRevision: item.revision, status: status))
                        }
                    }
                } label: {
                    Label("Status", systemImage: "arrow.triangle.swap")
                }
                .fixedSize()
                .disabled(options.allowedTargets.isEmpty)
                Menu {
                    Menu("Projekt zuweisen") {
                        Button("Inbox (ohne Projekt)") { assign(nil) }
                            .disabled(item.projectId == nil)
                        ForEach(snapshot.projects.filter { $0.project.status != .archived }) { entry in
                            Button(entry.project.name) { assign(entry.id) }
                                .disabled(item.projectId == entry.id)
                        }
                    }
                    .disabled(!availability.canAssign)
                    Menu("Typ ändern") {
                        ForEach(WorkItemType.allCases.filter { $0 != item.type }, id: \.self) { type in
                            Button(type.germanDisplayName) {
                                run(String(localized: "Typ ändern"),
                                    .reclassifyWorkItem(workItemId: item.uuid, expectedRevision: item.revision, type: type))
                            }
                        }
                    }
                    .disabled(!availability.canReclassify)
                    Button("Duplizieren") {
                        run(String(localized: "Duplizieren"), .duplicateWorkItem(workItemId: item.uuid, newWorkItemId: WorkItemID()))
                    }
                    Button(item.isArchived ? String(localized: "Wiederherstellen") : String(localized: "Archivieren")) {
                        run(item.isArchived ? String(localized: "Wiederherstellen") : String(localized: "Archivieren"),
                            .setWorkItemArchived(workItemId: item.uuid, expectedRevision: item.revision, archived: !item.isArchived))
                    }
                    Divider()
                    Button("Endgültig löschen …", role: .destructive) { confirmDelete = true }
                        .disabled(!availability.canDelete)
                } label: {
                    Label("Weitere Aktionen", systemImage: "ellipsis.circle")
                }
                .fixedSize()
            }
            ForEach(Array(Set([availability.assignReason, availability.deleteReason].compactMap { $0 })).sorted(), id: \.self) { reason in
                Text(reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $showEditor) {
            WorkItemEditSheet(item: item)
        }
        .confirmationDialog(Text("Aufgabe endgültig löschen?"), isPresented: $confirmDelete) {
            Button("Endgültig löschen", role: .destructive) {
                run(String(localized: "Aufgabe löschen"), .deleteWorkItem(workItemId: item.uuid, expectedRevision: item.revision))
            }
        } message: {
            Text("Die Notiz wurde nie als Datei angelegt und wird auf allen Geräten entfernt.")
        }
    }

    private func assign(_ projectId: ProjectID?) {
        run(String(localized: "Projekt zuweisen"), .assignWorkItem(workItemId: item.uuid, expectedRevision: item.revision, projectId: projectId))
    }

    private func run(_ title: String, _ request: ServiceRequest) {
        Task { await commands.perform(title, request) }
    }
}

/// Bearbeiten mit optimistischer Revision; bei Konflikt „Neu laden“ (Pflichtenheft O).
struct WorkItemEditSheet: View {
    @Environment(LibraryStore.self) private var library
    @Environment(CommandCenter.self) private var commands
    @Environment(\.dismiss) private var dismiss
    let item: WorkItem
    @State private var form: WorkItemEditForm
    @State private var conflict = false
    @State private var error: String?
    @State private var saving = false

    init(item: WorkItem) {
        self.item = item
        _form = State(initialValue: WorkItemEditForm(item))
    }

    var body: some View {
        let current = library.snapshot.workItem(item.uuid) ?? item
        VStack(alignment: .leading, spacing: 12) {
            Text("Aufgabe bearbeiten").font(.title2.bold())
            Form {
                TextField("Titel", text: $form.title)
                Picker("Priorität", selection: $form.priority) {
                    ForEach(Priority.allCases, id: \.self) { Text($0.germanDisplayName).tag($0) }
                }
                TextField("Labels (durch Komma getrennt)", text: $form.labelsText)
                let candidates = WorkItemEditForm.dependencyCandidates(for: current, in: library.snapshot.workItems)
                if !candidates.isEmpty {
                    DisclosureGroup("Abhängigkeiten (\(form.dependencies.count))") {
                        ForEach(candidates) { candidate in
                            Toggle(candidate.displayTitle, isOn: Binding(
                                get: { form.dependencies.contains(candidate.uuid) },
                                set: { on in
                                    if on { form.dependencies.append(candidate.uuid) } else { form.dependencies.removeAll { $0 == candidate.uuid } }
                                }))
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Inhalt (Markdown)")
                    TextEditor(text: $form.body)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 220)
                        .accessibilityLabel(Text("Inhalt (Markdown)"))
                }
            }
            .formStyle(.grouped)
            if conflict || form.isStale(comparedTo: current) {
                HStack {
                    Label("Die Aufgabe wurde inzwischen geändert (z. B. am iPhone oder in der Datei).", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Neu laden") {
                        form.reload(from: current)
                        conflict = false
                        error = nil
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Speichern") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!form.isValid || !form.hasChanges(comparedTo: current) || saving)
            }
        }
        .padding(20)
        .frame(width: 640, height: 640)
    }

    private func save() {
        saving = true
        Task {
            let outcome = await commands.perform(String(localized: "Aufgabe speichern"), .updateWorkItem(form.command))
            saving = false
            if outcome.succeeded {
                dismiss()
            } else if outcome.isRevisionConflict {
                conflict = true
            } else {
                error = outcome.feedback.message
            }
        }
    }
}

/// Neue Notiz (Inbox) oder Aufgabe in einem Projekt.
struct NewWorkItemSheet: View {
    @Environment(LibraryStore.self) private var library
    @Environment(CommandCenter.self) private var commands
    @Environment(NavigationModel.self) private var navigation
    @Environment(\.dismiss) private var dismiss
    @State private var form: NewWorkItemForm
    @State private var error: String?
    @State private var saving = false

    init(projectId: ProjectID?) {
        _form = State(initialValue: NewWorkItemForm(projectId: projectId, type: projectId == nil ? .note : .feature))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Neue Notiz oder Aufgabe").font(.title2.bold())
            Form {
                Picker("Projekt", selection: $form.projectId) {
                    Text("Inbox (ohne Projekt)").tag(ProjectID?.none)
                    ForEach(library.snapshot.projects.filter { $0.project.status != .archived }) { entry in
                        Text(entry.project.name).tag(ProjectID?.some(entry.id))
                    }
                }
                Picker("Typ", selection: $form.type) {
                    ForEach(WorkItemType.allCases, id: \.self) { Text($0.germanDisplayName).tag($0) }
                }
                TextField("Titel", text: $form.title, prompt: Text("leer = erste Zeile des Textes"))
                Picker("Priorität", selection: $form.priority) {
                    ForEach(Priority.allCases, id: \.self) { Text($0.germanDisplayName).tag($0) }
                }
                TextField("Labels (durch Komma getrennt)", text: $form.labelsText)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Text")
                    TextEditor(text: $form.text).frame(minHeight: 160).accessibilityLabel(Text("Text"))
                }
            }
            .formStyle(.grouped)
            Text("Die Nummer (z. B. FR-0001) vergibt der Mac, sobald die Request-Datei im Repository angelegt wird.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Anlegen") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!form.isValid || saving)
            }
        }
        .padding(20)
        .frame(width: 560, height: 600)
    }

    private func save() {
        saving = true
        Task {
            let outcome = await commands.perform(String(localized: "Aufgabe anlegen"), .createWorkItem(form.command))
            saving = false
            if let saved = outcome.savedWorkItem {
                if saved.projectId == nil { navigation.selectedInboxItem = saved.workItemId } else { navigation.selectedWorkItem = saved.workItemId }
                dismiss()
            } else {
                error = outcome.feedback.message
            }
        }
    }
}

/// Schnelle Notiz direkt in der Menüleiste (D1): landet in der Inbox.
struct QuickNoteForm: View {
    @Environment(CommandCenter.self) private var commands
    let onFinish: () -> Void
    @State private var form = NewWorkItemForm()
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Titel (optional)", text: $form.title)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $form.text)
                .frame(height: 70)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                .accessibilityLabel(Text("Notiztext"))
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Abbrechen") { onFinish() }
                Spacer()
                Button("In Inbox speichern") {
                    saving = true
                    Task {
                        let outcome = await commands.perform(String(localized: "Neue Notiz"), .createWorkItem(form.command))
                        saving = false
                        if outcome.succeeded {
                            form = NewWorkItemForm()
                            onFinish()
                        } else {
                            error = outcome.feedback.message
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!form.isValid || saving)
            }
        }
    }
}
