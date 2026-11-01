import AppKit
import SwiftUI
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC

/// ADRs je Projekt (F4, P macOS 4): ansehen, neuen Entwurf anlegen, Status ausdrücklich ändern. Angenommen
/// wird ein ADR nur durch Ihre Entscheidung, nie automatisch; Software Regisseur committet nicht (ADR-0024).
struct ADRsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(NavigationModel.self) private var navigation
    @State private var projectId: ProjectID?
    @State private var showDraft = false

    var body: some View {
        @Bindable var navigation = navigation
        LibraryGate {
            VStack(spacing: 0) {
                HStack {
                    Picker("Projekt", selection: $projectId) {
                        Text("Bitte wählen").tag(ProjectID?.none)
                        ForEach(library.snapshot.projects) { entry in
                            Text("\(entry.project.name) (\(entry.adrs.count))").tag(ProjectID?.some(entry.id))
                        }
                    }
                    .frame(maxWidth: 360)
                    Spacer()
                    Button {
                        showDraft = true
                    } label: {
                        Label("Neuen ADR-Entwurf anlegen …", systemImage: "plus")
                    }
                    .disabled(projectId == nil)
                }
                .padding(10)
                Divider()
                if let entry = library.snapshot.project(projectId) {
                    HSplitView {
                        List(selection: $navigation.selectedADR) {
                            ForEach(entry.adrs.sorted { $0.decisionNumber > $1.decisionNumber }) { adr in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: "\(adr.decisionNumber.displayID) · \(adr.title)").font(.headline).lineLimit(2)
                                    HStack(spacing: 4) {
                                        Badge(text: adr.status.displayName, color: color(adr.status))
                                        if let date = adr.date { Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                                .tag(adr.uuid)
                            }
                        }
                        .overlay {
                            if entry.adrs.isEmpty {
                                ContentUnavailableView("Keine ADRs", systemImage: "doc.text",
                                                       description: Text("Im ADR-Ordner dieses Projekts wurden keine Entscheidungen gefunden."))
                            }
                        }
                        .frame(minWidth: 220, idealWidth: 340, maxWidth: 480)
                        Group {
                            if let id = navigation.selectedADR, let adr = entry.adrs.first(where: { $0.uuid == id }) {
                                ADRDetailView(adr: adr, entry: entry).id(id)
                            } else {
                                ContentUnavailableView("ADR auswählen", systemImage: "doc.text")
                            }
                        }
                        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .splitViewMinimum(width: 220 + 320)
                } else {
                    ContentUnavailableView("Projekt wählen", systemImage: "folder",
                                           description: Text("ADRs werden je Projekt verwaltet."))
                }
            }
        }
        .onAppear {
            if projectId == nil { projectId = navigation.selectedProject ?? library.snapshot.projects.first?.id }
        }
        .sheet(isPresented: $showDraft) {
            if let entry = library.snapshot.project(projectId) {
                ADRDraftSheet(entry: entry)
            }
        }
    }

    private func color(_ status: ADRStatus) -> Color {
        switch status {
        case .proposed: .orange
        case .accepted: .green
        case .deprecated, .superseded: .secondary
        }
    }
}

private struct ADRDetailView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(ServiceMonitor.self) private var monitor
    @Environment(CommandCenter.self) private var commands
    let adr: ADR
    let entry: ProjectEntry
    @State private var relativePath: String?
    @State private var pendingAction: ADRStatusAction?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: "\(adr.decisionNumber.displayID): \(adr.title)").font(.title2.bold()).textSelection(.enabled)
                HStack {
                    Badge(text: adr.status.displayName)
                    if let date = adr.date { Text(date.formatted(date: .long, time: .omitted)).foregroundStyle(.secondary) }
                    if !adr.supersedes.isEmpty {
                        Text("ersetzt \(adr.supersedes.map(\.displayID).joined(separator: ", "))").foregroundStyle(.secondary)
                    }
                    if let by = adr.supersededBy { Text("ersetzt durch \(by.displayID)").foregroundStyle(.secondary) }
                }
                HStack {
                    if let path = filePath {
                        Button { _ = LocalOpener.openFile(path) } label: { Label("Im Editor öffnen", systemImage: "square.and.pencil") }
                        Button { LocalOpener.revealInFinder(path) } label: { Label("Im Finder zeigen", systemImage: "folder") }
                    }
                    CommandButton(String(localized: "Mit Datei abgleichen"), systemImage: "arrow.triangle.2.circlepath") {
                        .reconcileProject(projectId: entry.id)
                    }
                }
                let actions = ADRStatusAction.actions(for: adr, in: entry.adrs)
                if !actions.isEmpty {
                    HStack {
                        ForEach(actions.filter { $0.supersededBy == nil }) { action in
                            CommandButton(action.title, systemImage: action == .accept ? "checkmark.seal" : "archivebox",
                                          confirmation: action.confirmation) { action.request(for: adr) }
                        }
                        let supersede = actions.filter { $0.supersededBy != nil }
                        if !supersede.isEmpty {
                            Menu("Ersetzt durch …") {
                                ForEach(supersede) { action in
                                    Button(action.title) { pendingAction = action }
                                }
                            }
                            .fixedSize()
                        }
                    }
                    Text("Statuswechsel nur auf Ihre ausdrückliche Entscheidung. Geändert wird nur das Frontmatter der Datei; Software Regisseur committet nicht.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                section("Kontext", adr.context)
                section("Entscheidung", adr.decision)
                section("Erwogene Alternativen", adr.alternatives)
                section("Konsequenzen", adr.consequences)
            }
            .padding(16)
        }
        .task(id: adr.revision) {
            relativePath = await library.documentPath(entityId: adr.uuid.rawValue)
        }
        .confirmationDialog(Text(pendingAction?.title ?? ""), isPresented: Binding(
            get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } })) {
            if let action = pendingAction {
                Button(action.title) {
                    pendingAction = nil
                    Task { await commands.perform(action.title, action.request(for: adr)) }
                }
            }
            Button("Abbrechen", role: .cancel) { pendingAction = nil }
        } message: {
            Text(pendingAction?.confirmation ?? "")
        }
    }

    private var filePath: String? {
        guard let relativePath, let location = entry.location(hostId: monitor.currentSummary?.hostId) else { return nil }
        let path = URL(filePath: location.canonicalPath, directoryHint: .isDirectory).appending(path: relativePath).path(percentEncoded: false)
        return LocalOpener.exists(path) ? path : nil
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, _ text: String) -> some View {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(title).font(.title3.bold()).accessibilityAddTraits(.isHeader)
            MarkdownPreview(text: text)
        }
    }
}

/// Neuer ADR-Entwurf (Status `proposed`): Nummer vergibt der Mac (ADR-0018), der Dienst rendert die Datei
/// aus der `TEMPLATE.md` des Repositorys, schreibt sie atomar in den ADR-Ordner und committet nicht.
private struct ADRDraftSheet: View {
    @Environment(CommandCenter.self) private var commands
    @Environment(NavigationModel.self) private var navigation
    @Environment(\.dismiss) private var dismiss
    let entry: ProjectEntry
    @State private var form = ADRCreateForm()
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Neuer ADR-Entwurf").font(.title2.bold())
            Text("Der Entwurf startet als „proposed“. Die Nummer vergibt der Mac; angenommen wird nur durch Ihre ausdrückliche Entscheidung.")
                .foregroundStyle(.secondary)
            Form {
                TextField("Titel", text: $form.title)
                TextField("Ersetzt ADR-Nummern (optional, z. B. 3, 5)", text: $form.supersedesText)
                editor("Kontext", text: $form.context)
                editor("Entscheidung", text: $form.decision)
                editor("Erwogene Alternativen", text: $form.alternatives)
                editor("Konsequenzen", text: $form.consequences)
            }
            .formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Text("Leere Abschnitte behalten den Text der Vorlage.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Entwurf anlegen") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!form.isValid || saving)
            }
        }
        .padding(20)
        .frame(width: 640, height: 680)
    }

    private func editor(_ title: LocalizedStringKey, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            TextEditor(text: text)
                .font(.body)
                .frame(minHeight: 60)
                .accessibilityLabel(Text(title))
        }
    }

    private func save() {
        saving = true
        Task {
            let outcome = await commands.perform(String(localized: "ADR-Entwurf anlegen"), .createADR(form.command(projectId: entry.id)))
            saving = false
            if case let .adrCreated(info)? = outcome.result {
                if let adrId = info.adrId { navigation.selectedADR = adrId }
                dismiss()
            } else {
                error = outcome.feedback.message
            }
        }
    }
}
