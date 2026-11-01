import SwiftUI
import SoftwareRegisseurAppCore
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

/// „Projekte“ (spec P 2, E2): synced catalog, search, folder assignment, new/link, missing Mac host.
struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    @State private var catalog = Catalog()
    @State private var search = ""
    @State private var showsArchived = false
    @State private var showsCreate = false
    @State private var loadError: String?
    @FocusState private var searchFocused: Bool

    private var visible: [Project] {
        catalog.projects
            .filter { showsArchived || $0.status != .archived }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || ($0.remote ?? "").localizedCaseInsensitiveContains(search) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        RouteList {
            if let loadError { ErrorText(message: loadError) }
            if visible.isEmpty {
                ContentUnavailableView {
                    Label(search.isEmpty ? "Keine Projekte" : "Keine Treffer", systemImage: "folder")
                } description: {
                    Text(search.isEmpty
                        ? "Projekte erscheinen hier, sobald der Mac Ihre Stammordner indiziert und per iCloud synchronisiert hat. Unterwegs können Sie einen Projektentwurf ohne Repository anlegen."
                        : "Kein Projekt passt zur Suche.")
                }
            }
            ForEach(visible) { project in
                NavigationLink(value: AppRoute.project(project.id)) {
                    ProjectRow(project: project, host: catalog.host(project.hostId))
                }
            }
            Section {
                Toggle("Archivierte Projekte anzeigen", isOn: $showsArchived)
            }
        }
        .navigationTitle("Projekte")
        .sectionSearchable(text: $search, prompt: Text("Projekte suchen"))
        .searchFocused($searchFocused)
        .onChange(of: model.pendingSearch, initial: true) { _, pending in
            guard pending == .projects else { return }
            model.pendingSearch = nil
            searchFocused = true
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsCreate = true
                } label: {
                    Label("Neues Projekt", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showsCreate) { CreateProjectView() }
        .refreshable { await model.sync(.pullToRefresh) }
        .reloadOnDataChange { await load() }
    }

    private func load() async {
        do {
            catalog = try await model.loadCatalog()
            loadError = nil
        } catch {
            loadError = errorMessage(error)
        }
    }
}

struct ProjectRow: View {
    let project: Project
    let host: AgentHost?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(project.name).font(.headline)
            Text(project.repositoryKind.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            // Stacked: side by side both badges wrapped into narrow columns, at large text sizes syllable by syllable.
            VStack(alignment: .leading, spacing: 2) {
                StatusBadge(title: project.status.title, symbol: "circle.fill", tint: project.status.tint)
                if project.hostId == nil {
                    StatusBadge(title: "Kein Mac-Host zugeordnet", symbol: "desktopcomputer.trianglebadge.exclamationmark", tint: .orange)
                } else if HostAvailability.isOffline(host, now: .now) {
                    StatusBadge(title: "Mac derzeit offline", symbol: "desktopcomputer", tint: .orange)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// State of the latest `CreateProject`/`LinkProject` command (spec E2: Projektstatus sichtbar).
struct SetupCommandStatusRow: View {
    let status: SetupCommandStatus

    var body: some View {
        switch status {
        case .waitingForMac:
            Label("Einrichtung wartet auf den Mac", systemImage: "hourglass").foregroundStyle(.secondary)
        case let .completed(path):
            Label {
                VStack(alignment: .leading) {
                    Text("Am Mac eingerichtet")
                    if let path { Text(verbatim: path).font(.caption.monospaced()).foregroundStyle(.secondary) }
                }
            } icon: {
                Image(systemName: "checkmark.circle").foregroundStyle(.green)
            }
        case let .failed(failure):
            Label {
                VStack(alignment: .leading) {
                    Text("Einrichtung fehlgeschlagen")
                    Text(verbatim: failure.message).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
    }
}

/// New project from the iPhone (spec E2): existing indexed folder, new subfolder of an allowed root,
/// existing Git repository or draft without repository. The iPhone never touches the Mac file system;
/// it creates a validated command that the Mac executes when reachable.
struct CreateProjectView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable, Identifiable {
        case existingFolder, newSubfolder, repository, draft
        var id: String { rawValue }

        var title: LocalizedStringResource {
            switch self {
            case .existingFolder: "Vorhandener Ordner"
            case .newSubfolder: "Neuer Unterordner"
            case .repository: "Git-Repository verknüpfen"
            case .draft: "Entwurf ohne Repository"
            }
        }
    }

    @State private var name = ""
    @State private var mode: Mode = .draft
    @State private var choices = FolderChoices(folders: [])
    @State private var selectedFolder: IndexedFolderID?
    @State private var scope: RepositoryScopeChoice?
    @State private var parentPath = ""
    @State private var folderName = ""
    @State private var gitInitConsent = false
    @State private var error: String?
    @State private var isSaving = false

    private var input: NewProjectInput {
        let folder = choices.folders.first { $0.id == selectedFolder }
        let option: NewProjectOption = switch mode {
        case .draft: .draft
        case .newSubfolder: .newSubfolder(parentPath: parentPath, name: folderName)
        case .existingFolder: folder.map { .existingFolder($0, scope: scope) } ?? .draft
        case .repository: folder.map { .linkRepository($0) } ?? .draft
        }
        return NewProjectInput(name: name, option: option, gitInitConsent: gitInitConsent)
    }

    private var blockers: [NewProjectBlocker] {
        if (mode == .existingFolder || mode == .repository), selectedFolder == nil { return [.folderNotSelectable] }
        return NewProjectPlanner.blockers(input, choices: choices)
    }

    private var selected: IndexedFolder? { choices.folders.first { $0.id == selectedFolder } }

    private var allowsGitInit: Bool {
        switch mode {
        case .newSubfolder: true
        case .existingFolder: selected?.kind == .plainFolder
        case .repository, .draft: false
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Projektname", text: $name)
                        .textInputAutocapitalization(.words)
                    Picker("Art", selection: $mode) {
                        ForEach(Mode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                } footer: {
                    Text("Der Mac führt die Einrichtung aus, sobald er erreichbar ist. Bis dahin hat das Projekt den Status „Einrichtung am Mac ausstehend“.")
                }
                switch mode {
                case .existingFolder: folderSection(kinds: [.plainFolder, .repositorySubfolder])
                case .repository: folderSection(kinds: [.gitRepository])
                case .newSubfolder: subfolderSection
                case .draft:
                    Section {
                        Text("Der Entwurf wird sofort angelegt; Aufgaben können ihm schon zugeordnet werden. Einen Ordner verknüpfen Sie später.")
                            .foregroundStyle(.secondary)
                    }
                }
                if mode == .existingFolder, selected?.kind == .repositorySubfolder {
                    Section {
                        Picker("Umfang", selection: $scope) {
                            Text("Bitte wählen").tag(RepositoryScopeChoice?.none)
                            Text("Ganzes Repository").tag(RepositoryScopeChoice?.some(.wholeRepository))
                            Text("Nur dieser Unterordner").tag(RepositoryScopeChoice?.some(.subfolderOnly))
                        }
                    } header: {
                        Text("Unterordner eines Repositories")
                    } footer: {
                        Text("Der Ordner liegt in einem bestehenden Git-Repository. Ist das gesamte Repository oder nur dieser Teilbereich gemeint?")
                    }
                }
                if allowsGitInit {
                    Section {
                        Toggle("Git-Repository anlegen („git init“)", isOn: $gitInitConsent)
                    } footer: {
                        Text("Nur mit Ihrer Zustimmung legt der Mac in diesem Ordner ein neues Git-Repository an. Ohne Zustimmung bleibt der Ordner unverändert.")
                    }
                }
                if !blockers.isEmpty, !name.isEmpty {
                    Section {
                        ForEach(blockers, id: \.self) { blocker in
                            Text(blocker.title).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                if let error { ErrorText(message: error) }
            }
            .navigationTitle("Neues Projekt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Anlegen") { Task { await create() } }
                        .disabled(!blockers.isEmpty || isSaving)
                }
            }
            .onChange(of: mode) { _, _ in
                selectedFolder = nil
                scope = nil
                gitInitConsent = model.globalSettings.workspace.proposeGitInitForNewFolders && mode == .newSubfolder
            }
            .onChange(of: selectedFolder) { _, _ in scope = nil }
            .task { await loadFolders() }
        }
    }

    private func folderSection(kinds: Set<IndexedFolderKind>) -> some View {
        let folders = choices.folders.filter { kinds.contains($0.kind) && $0.projectId == nil }
        return Section {
            if folders.isEmpty {
                Text("Der Mac hat noch keine passenden Ordner gemeldet. Die Liste stammt aus dem Ordnerindex des Mac und ist auch offline verfügbar.")
                    .foregroundStyle(.secondary)
            }
            Picker("Ordner", selection: $selectedFolder) {
                Text("Bitte wählen").tag(IndexedFolderID?.none)
                ForEach(folders) { folder in
                    VStack(alignment: .leading) {
                        Text(verbatim: folder.displayName)
                        Text(verbatim: folder.canonicalPath).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(IndexedFolderID?.some(folder.id))
                }
            }
            .pickerStyle(.navigationLink)
            if let folder = selected {
                LabeledContent { Text(folder.kind.repositoryKind?.title ?? "Ordner") } label: { Text("Art") }
                if let documents = folder.documents {
                    DetectedDocumentsRows(documents: documents)
                }
            }
        } header: {
            Text("Ordner am Mac")
        }
    }

    private var subfolderSection: some View {
        Section {
            Picker("Übergeordneter Ordner", selection: $parentPath) {
                Text("Bitte wählen").tag("")
                ForEach(choices.subfolderParents, id: \.self) { path in
                    Text(verbatim: path).tag(path)
                }
            }
            .pickerStyle(.navigationLink)
            TextField("Name des neuen Ordners", text: $folderName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Neuer Unterordner")
        } footer: {
            Text("Nur innerhalb der am Mac freigegebenen Stammordner. Keine „/“, „:“ oder führenden Punkte.")
        }
    }

    private func loadFolders() async {
        guard let database = model.database else { return }
        choices = FolderChoices(folders: (try? await database.indexedFolders.selectable()) ?? [])
        if parentPath.isEmpty, let root = choices.roots.first { parentPath = root }
    }

    private func create() async {
        guard let database = model.database else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let plan = try NewProjectPlanner.plan(input, choices: choices, globalSettings: model.globalSettings,
                                                  device: model.deviceId, now: .now)
            try await NewProjectSubmitter(projects: database.projects, commands: database.projectSetupCommands).submit(plan, at: .now)
            model.noteLocalChange()
            dismiss()
        } catch let NewProjectError.blocked(list) {
            error = list.map { String(localized: $0.title) }.joined(separator: " ")
        } catch {
            self.error = errorMessage(error)
        }
    }
}

/// Existing project documents the Mac detected in a folder (spec E3).
struct DetectedDocumentsRows: View {
    let documents: DetectedProjectDocuments

    var body: some View {
        if documents.hasAgentsFile { Label("AGENTS.md vorhanden", systemImage: "doc.text") }
        if documents.hasClaudeFile { Label("CLAUDE.md vorhanden", systemImage: "doc.text") }
        if let adr = documents.adrFolder {
            Label { Text(verbatim: "\(adr) (\(documents.adrFileCount))") } icon: { Image(systemName: "books.vertical") }
        }
        if let requests = documents.requestsFolder {
            Label { Text(verbatim: "\(requests) (\(documents.requestFileCount))") } icon: { Image(systemName: "tray.full") }
        }
    }
}

extension NewProjectBlocker {
    var title: LocalizedStringResource {
        switch self {
        case .emptyName: "Bitte einen Projektnamen eingeben."
        case .invalidFolderName: "Der Ordnername ist nicht zulässig."
        case .noAllowedRoots: "Der Mac hat noch keine Stammordner freigegeben."
        case .parentNotAllowed: "Bitte einen freigegebenen Stammordner wählen."
        case .folderNotSelectable: "Bitte einen Ordner wählen."
        case .folderAlreadyLinked: "Dieser Ordner ist bereits mit einem Projekt verknüpft."
        case .notARepository: "Der Ordner ist kein Git-Repository."
        case .scopeChoiceRequired: "Bitte wählen, ob das ganze Repository oder nur der Unterordner gemeint ist."
        case .gitInitNotPossible: "Hier kann kein Git-Repository angelegt werden."
        case .draftCannotBeLinked: "Ein Entwurf kann nicht verknüpft werden."
        }
    }
}
