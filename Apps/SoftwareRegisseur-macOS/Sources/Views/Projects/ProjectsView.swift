import AppKit
import SwiftUI
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC

/// Git-Projektverwaltung mit Stammordnern, Scanner, Re-Link, Einstellungen, Anweisungsdateien und
/// Ordnermigration (Pflichtenheft E1–E3, F2, G, P macOS 3).
struct ProjectsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(NavigationModel.self) private var navigation
    @State private var searchText = ""
    @State private var statusFilter: ProjectStatus?
    @State private var sort: ProjectSortOrder = .name
    @State private var showSetupSheet = false

    var body: some View {
        @Bindable var navigation = navigation
        LibraryGate {
            HSplitView {
                VStack(spacing: 0) {
                    RootFoldersPanel()
                    Divider()
                    filterBar
                    List(selection: $navigation.selectedProject) {
                        ForEach(rows) { row in
                            ProjectRow(row: row).tag(row.projectId)
                        }
                    }
                    .overlay {
                        if rows.isEmpty {
                            ContentUnavailableView {
                                Label("Keine Projekte", systemImage: "folder")
                            } description: {
                                Text(library.snapshot.projects.isEmpty
                                     ? "Fügen Sie oben einen Stammordner hinzu und aktualisieren Sie den Scanner."
                                     : "Kein Projekt passt zum Filter.")
                            }
                        }
                    }
                }
                .frame(minWidth: 240, idealWidth: 340, maxWidth: 460)
                Group {
                    if let id = navigation.selectedProject, let entry = library.snapshot.project(id) {
                        ProjectDetailView(entry: entry)
                            .id(id)
                    } else {
                        ContentUnavailableView("Projekt auswählen", systemImage: "folder",
                                               description: Text("Wählen Sie links ein Projekt, um Details, Einstellungen und Vorschläge zu sehen."))
                    }
                }
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            }
            .splitViewMinimum(width: 240 + 320)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showSetupSheet = true
                } label: {
                    Label("Projekt anlegen oder verknüpfen …", systemImage: "folder.badge.plus")
                }
                CommandButton(String(localized: "Scanner aktualisieren"), systemImage: "magnifyingglass") { .refreshScanner }
            }
        }
        .sheet(isPresented: $showSetupSheet) {
            ProjectSetupSheet()
        }
    }

    private var filterBar: some View {
        VStack(spacing: 6) {
            TextField("Projekte suchen", text: $searchText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Picker("Status", selection: $statusFilter) {
                    Text("Alle Status").tag(ProjectStatus?.none)
                    ForEach(ProjectStatus.allCases, id: \.self) { status in
                        Text(status.germanDisplayName).tag(ProjectStatus?.some(status))
                    }
                }
                Picker("Sortierung", selection: $sort) {
                    ForEach(ProjectSortOrder.allCases) { Text($0.title).tag($0) }
                }
            }
            .labelsHidden()
        }
        .padding(8)
    }

    private var rows: [ProjectOverviewRow] {
        let needle = searchText.trimmingCharacters(in: .whitespaces)
        let all = ProjectOverviewRow.rows(snapshot: library.snapshot).filter { row in
            (statusFilter == nil || row.status == statusFilter) && (needle.isEmpty || row.name.localizedStandardContains(needle))
        }
        return sort.sort(all)
    }
}

private struct ProjectRow: View {
    let row: ProjectOverviewRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(row.name).font(.headline)
                Spacer()
                if row.activeAgents > 0 {
                    Label("\(row.activeAgents)", systemImage: "cpu")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .accessibilityLabel(Text("\(row.activeAgents) aktive Agenten"))
                }
            }
            HStack(spacing: 6) {
                Text(row.status.germanDisplayName).foregroundStyle(row.status.level.color)
                Text("· \(row.openTasks) offen · \(row.inReview) Review")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Stammordner (E1): Hinzufügen per NSOpenPanel, Entfernen löscht keine Projekte.
private struct RootFoldersPanel: View {
    @Environment(CommandCenter.self) private var commands
    @Environment(ServiceMonitor.self) private var monitor
    @State private var state: RootFolderState?
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Stammordner").font(.headline)
                Spacer()
                Button {
                    chooseFolder()
                } label: {
                    Label("Hinzufügen …", systemImage: "plus")
                }
                .help(Text("Git-Stammordner wählen, dessen Unterordner indiziert werden"))
            }
            if let state {
                if state.folders.isEmpty {
                    Text("Noch kein Stammordner. Ohne Stammordner scannt der Dienst nichts.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let suggestion = state.suggestion {
                        Button {
                            add(suggestion)
                        } label: {
                            Label("Vorschlag übernehmen: \(suggestion)", systemImage: "lightbulb")
                        }
                    }
                }
                ForEach(state.folders, id: \.path) { folder in
                    HStack {
                        Image(systemName: folder.exists ? "folder" : "folder.badge.questionmark")
                            .foregroundStyle(folder.exists ? Color.secondary : Color.orange)
                            .accessibilityHidden(true)
                        Text(verbatim: folder.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(folder.path)
                        if !folder.exists {
                            Text("fehlt").font(.caption).foregroundStyle(.orange)
                        }
                        Spacer()
                        CommandButton(String(localized: "Entfernen"), systemImage: "minus.circle", role: .destructive,
                                      confirmation: String(localized: "Der Ordner wird nicht mehr gescannt. Projekte und Aufgaben bleiben erhalten.")) {
                            .removeRootFolder(path: folder.path)
                        } onResult: { outcome in
                            apply(outcome)
                        }
                        .labelStyle(.iconOnly)
                    }
                }
            } else if let loadError {
                Text(loadError).font(.callout).foregroundStyle(.red)
            } else {
                ProgressView().controlSize(.small)
            }
            ScanStatusLine()
        }
        .padding(10)
        .buttonStyle(.borderless)
        .task(id: monitor.isReachable) { await load() }
    }

    private func load() async {
        let outcome = await commands.perform(String(localized: "Stammordner laden"), .rootFolders, quiet: true)
        if !apply(outcome) { loadError = outcome.feedback.message }
    }

    @discardableResult
    private func apply(_ outcome: CommandOutcome) -> Bool {
        if case let .rootFolders(state)? = outcome.result {
            self.state = state
            loadError = nil
            return true
        }
        return false
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Als Stammordner verwenden")
        panel.message = String(localized: "Wählen Sie einen Ordner, unter dem Ihre Git-Projekte liegen.")
        if let suggestion = state?.suggestion { panel.directoryURL = URL(filePath: suggestion) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        add(url.path(percentEncoded: false))
    }

    private func add(_ path: String) {
        Task {
            let outcome = await commands.perform(String(localized: "Stammordner hinzufügen"), .addRootFolder(path: path))
            apply(outcome)
        }
    }
}

/// Scannerstatus aus der Statusübersicht (E1: keine Blockade der UI durch Repo-Scans).
private struct ScanStatusLine: View {
    @Environment(ServiceMonitor.self) private var monitor

    var body: some View {
        if let workspace = monitor.currentSummary?.workspace {
            VStack(alignment: .leading, spacing: 2) {
                if workspace.isScanning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Scanner läuft …")
                    }
                } else if let last = workspace.lastScanAt {
                    Text("Letzter Scan: \(last.shortDateTime)")
                } else {
                    Text("Noch kein Scan.")
                }
                if let error = workspace.lastScanError {
                    Text(error).foregroundStyle(.red)
                }
                Text("\(workspace.projectsReady) bereit · \(workspace.projectsUnavailable) nicht erreichbar · \(workspace.projectsNeedingAttention) mit Hinweisen · \(workspace.projectsPendingSetup) Einrichtung ausstehend")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }
}
