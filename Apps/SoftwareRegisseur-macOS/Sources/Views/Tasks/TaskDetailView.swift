import SwiftUI
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC

/// Detail einer Aufgabe: Inhalt mit Markdown-Vorschau, Original/Transkript, KI-Entwürfe, Jobs, Verlauf und
/// Konflikte (F1, F3, H3/H4, M2, N2).
struct TaskDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case content, original, drafts, conversation, jobs, history, conflicts
        var id: Self { self }
        var title: LocalizedStringResource {
            switch self {
            case .content: "Inhalt"
            case .original: "Original"
            case .drafts: "KI-Entwürfe"
            case .conversation: "Mit KI besprechen"
            case .jobs: "Jobs"
            case .history: "Verlauf"
            case .conflicts: "Konflikte"
            }
        }
    }

    @Environment(LibraryStore.self) private var library
    @Environment(ServiceMonitor.self) private var monitor
    @Environment(CommandCenter.self) private var commands
    let item: WorkItem
    @State private var tab: Tab
    /// Gespräch „Mit KI besprechen“ bleibt beim Wechsel der Bereiche erhalten (H3).
    @State private var conversation: MacConversationModel?
    @State private var showSource = false
    @State private var showJobSheet = false
    @State private var showAISheet = false
    @State private var documentPath: String?

    init(item: WorkItem, initialTab: Tab = .content, conversation: MacConversationModel? = nil) {
        self.item = item
        _tab = State(initialValue: initialTab)
        _conversation = State(initialValue: conversation)
    }

    var body: some View {
        let snapshot = library.snapshot
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                header(snapshot)
                lockNotice(snapshot)
                actions(snapshot)
                AdaptivePicker("Bereich", selection: $tab) {
                    ForEach(Tab.allCases) { tab in
                        if tab == .conflicts {
                            Text("\(String(localized: tab.title)) (\(snapshot.fileConflicts(for: item.uuid).count))").tag(tab)
                        } else {
                            Text(tab.title).tag(tab)
                        }
                    }
                }
            }
            .padding(16)
            Divider()
            ScrollView {
                tabContent(snapshot)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: item.revision) {
            documentPath = await library.documentPath(entityId: item.uuid.rawValue)
        }
        .sheet(isPresented: $showJobSheet) {
            JobRequestSheet(item: item)
        }
        .sheet(isPresented: $showAISheet) {
            MacAIElaborationSheet(item: item)
        }
    }

    private func header(_ snapshot: LibrarySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.displayTitle)
                .font(.title2.bold())
                .textSelection(.enabled)
            FlowLayout(spacing: 6) {
                Badge(text: item.status.germanDisplayName, color: item.status.level.color)
                Badge(text: item.type.germanDisplayName)
                Badge(text: String(localized: "Priorität: \(item.priority.germanDisplayName)"),
                      color: item.priority >= .high ? .orange : .secondary)
                ForEach(item.labels, id: \.self) { Badge(text: $0, color: .purple) }
            }
            Text("\(snapshot.projectName(item.projectId)) · angelegt \(item.createdAt.shortDateTime) · geändert \(item.updatedAt.shortDateTime) · Revision \(item.revision)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func lockNotice(_ snapshot: LibrarySnapshot) -> some View {
        let options = StatusChangeOptions(item: item, activeJob: snapshot.activeJob(for: item.uuid),
                                          lock: snapshot.lock(for: item.uuid, projectId: item.projectId))
        if let reason = options.blockReason {
            Label(reason, systemImage: "lock.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func actions(_ snapshot: LibrarySnapshot) -> some View {
        let options = StatusChangeOptions(item: item, activeJob: snapshot.activeJob(for: item.uuid),
                                          lock: snapshot.lock(for: item.uuid, projectId: item.projectId))
        let filePath = absoluteDocumentPath(snapshot)
        // Wrapping rows; in a single HStack the labels were truncated to „Mit Agent umsetz…“, in a narrow window even in two rows.
        return FlowLayout(spacing: 6) {
            agentAndAIButtons(snapshot)
            fileMenu(filePath)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .safeAreaInset(edge: .bottom, alignment: .leading) {
            WorkItemCommandBar(item: item, hasDocument: documentPath != nil)
                .padding(.top, 4)
                .help(options.blockReason.map { Text($0) } ?? Text("Änderungen laufen über den Hintergrunddienst und werden synchronisiert."))
        }
    }

    @ViewBuilder
    private func agentAndAIButtons(_ snapshot: LibrarySnapshot) -> some View {
        Button {
            showJobSheet = true
        } label: {
            Label("Mit Agent umsetzen …", systemImage: "play.circle")
        }
        .disabled(item.projectId == nil || snapshot.activeJob(for: item.uuid) != nil)
        .help(item.projectId == nil ? Text("Notizen ohne Projekt können nicht von einem Agenten umgesetzt werden.")
              : snapshot.activeJob(for: item.uuid) != nil ? Text("Für diese Aufgabe läuft bereits ein Job.")
              : Text("Agent, Modell und Stufe wählen"))
        Button {
            showAISheet = true
        } label: {
            Label("Mit KI ausarbeiten …", systemImage: "sparkles")
        }
        .disabled(item.projectId == nil)
        .help(Text("KI-Ausarbeitung am Mac, mit Repo-Kontext"))
        Button {
            tab = .conversation
        } label: {
            Label("Mit KI besprechen", systemImage: "bubble.left.and.bubble.right")
        }
        .help(Text("Fragen stellen, Varianten diskutieren, Änderungen anfordern – ohne Agentenstart"))
    }

    private func fileMenu(_ filePath: String?) -> some View {
        Menu {
            if let filePath {
                Button("Im Standardeditor öffnen") { open(filePath) }
                Button("Im Finder zeigen") { LocalOpener.revealInFinder(filePath) }
            }
            if let projectId = item.projectId {
                Button("Mit Datei abgleichen") {
                    Task { await commands.perform(String(localized: "Markdown abgleichen"), .reconcileProject(projectId: projectId)) }
                }
            }
        } label: {
            Label("Datei", systemImage: "doc")
        }
        .fixedSize()
        .disabled(filePath == nil && item.projectId == nil)
    }

    private func absoluteDocumentPath(_ snapshot: LibrarySnapshot) -> String? {
        guard let documentPath, let entry = snapshot.project(item.projectId),
              let location = entry.location(hostId: monitor.currentSummary?.hostId) else { return nil }
        let path = URL(filePath: location.canonicalPath, directoryHint: .isDirectory).appending(path: documentPath).path(percentEncoded: false)
        return LocalOpener.exists(path) ? path : nil
    }

    private func open(_ path: String) {
        if !LocalOpener.openFile(path) {
            commands.record(title: String(localized: "Datei öffnen"),
                            feedback: .failure(String(localized: "Die Datei konnte nicht geöffnet werden. Ist ein Programm für Markdown-Dateien eingerichtet?")))
        }
    }

    @ViewBuilder
    private func tabContent(_ snapshot: LibrarySnapshot) -> some View {
        switch tab {
        case .content:
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Markdown-Quelltext anzeigen", isOn: $showSource)
                    .toggleStyle(.switch)
                if showSource {
                    Text(verbatim: item.structuredBody.isEmpty ? " " : item.structuredBody)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                } else {
                    MarkdownPreview(text: item.structuredBody)
                }
                if !item.dependencies.isEmpty {
                    Text("Abhängigkeiten").font(.headline)
                    ForEach(item.dependencies, id: \.self) { dependency in
                        Text(snapshot.workItem(dependency)?.displayTitle ?? dependency.shortString)
                    }
                }
            }
        case .original:
            VStack(alignment: .leading, spacing: 12) {
                Text("Originalnotiz").font(.headline)
                Text(item.originalNote.isEmpty ? String(localized: "Keine Originalnotiz.") : item.originalNote)
                    .textSelection(.enabled)
                if let transcript = item.transcript {
                    Text("Transkript").font(.headline)
                    Text(transcript).textSelection(.enabled)
                }
            }
        case .drafts:
            DraftVersionsView(item: item)
        case .conversation:
            ConversationPanel(item: item, model: $conversation)
        case .jobs:
            WorkItemJobsList(item: item)
        case .history:
            WorkItemHistoryView(workItemId: item.uuid)
        case .conflicts:
            let conflicts = snapshot.fileConflicts(for: item.uuid)
            if conflicts.isEmpty {
                Text("Keine offenen Konflikte.").foregroundStyle(.secondary)
            }
            ForEach(conflicts) { conflict in
                FileConflictView(conflict: conflict)
            }
        }
    }
}

/// Jobs einer Aufgabe mit Sprung in die Warteschlange.
private struct WorkItemJobsList: View {
    @Environment(LibraryStore.self) private var library
    @Environment(NavigationModel.self) private var navigation
    let item: WorkItem

    var body: some View {
        let jobs = library.snapshot.jobs(for: item.uuid)
        VStack(alignment: .leading, spacing: 8) {
            if jobs.isEmpty {
                Text("Noch keine Agentenjobs.").foregroundStyle(.secondary)
            }
            ForEach(jobs) { job in
                Button {
                    navigation.showJob(job.jobId, filter: QueueFilter.category(of: job.state))
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(ProviderNames.displayName(job.providerId)) · \(job.state.germanDisplayName)")
                                .font(.headline)
                            Text(JobConfigurationText(job: job).resolved)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(job.createdAt.shortDateTime).font(.caption).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// KI-Entwürfe (H3/H4): übernehmen (Titel, Inhalt, Priorität der Aufgabe) oder verwerfen. Beides startet
/// nie einen Agenten.
private struct DraftVersionsView: View {
    @Environment(LibraryStore.self) private var library
    let item: WorkItem
    @State private var drafts: [DraftVersion]?
    @State private var rejected: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let drafts {
                if drafts.isEmpty {
                    Text("Noch keine KI-Entwürfe.").foregroundStyle(.secondary)
                } else {
                    Text("Übernehmen ersetzt Titel, Inhalt und Priorität der Aufgabe; Originalnotiz und Transkript bleiben erhalten. Es wird kein Agent gestartet.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(drafts.filter { $0.source == .ai }.sorted { $0.version > $1.version }) { draft in
                    let state = DraftDecisionState.state(of: draft, rejected: rejected)
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            if let text = draft.text, !text.isEmpty {
                                MarkdownPreview(text: text)
                                if draft.contents.isEmpty, state == .open {
                                    acceptButton(draft, index: nil)
                                }
                            }
                            ForEach(Array(draft.contents.enumerated()), id: \.offset) { index, content in
                                DraftContentView(content: content, accepted: draft.acceptedContentIndexes.contains(index))
                                if state != .rejected, !draft.acceptedContentIndexes.contains(index) {
                                    acceptButton(draft, index: index)
                                }
                            }
                            if state == .open {
                                CommandButton(String(localized: "Entwurf verwerfen"), systemImage: "xmark") {
                                    .rejectDraftVersion(draftId: draft.id)
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Text("Version \(draft.version)").font(.headline)
                            if let model = draft.modelId { Text(verbatim: model.rawValue).foregroundStyle(.secondary) }
                            Text(draft.createdAt.shortDateTime).foregroundStyle(.secondary)
                            switch state {
                            case .accepted: Badge(text: String(localized: "übernommen"), color: .green)
                            case .rejected: Badge(text: String(localized: "verworfen"))
                            case .open: EmptyView()
                            }
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .task(id: library.snapshot.loadedAt) {
            drafts = await library.drafts(for: item.uuid)
            rejected = DraftDecisionState.rejectedIds(in: await library.events(for: item.uuid))
        }
    }

    private func acceptButton(_ draft: DraftVersion, index: Int?) -> some View {
        CommandButton(String(localized: "In die Aufgabe übernehmen"), systemImage: "checkmark",
                      confirmation: String(localized: "Titel, Inhalt und Priorität der Aufgabe werden durch diesen Entwurf ersetzt. Es wird kein Agent gestartet.")) {
            .acceptDraftVersion(draftId: draft.id, contentIndex: index, expectedRevision: item.revision)
        }
    }
}

struct DraftContentView: View {
    let content: DraftContent
    let accepted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(content.title).font(.headline)
                if accepted { Badge(text: String(localized: "übernommen"), color: .green) }
            }
            if !content.goal.isEmpty { labeled("Ziel", content.goal) }
            if !content.context.isEmpty { labeled("Kontext", content.context) }
            list("Akzeptanzkriterien", content.acceptanceCriteria)
            list("Technische Hinweise", content.technicalNotes)
            list("Testfälle", content.testCases)
            list("Offene Fragen", content.openQuestions)
        }
        .textSelection(.enabled)
    }

    private func labeled(_ title: LocalizedStringKey, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(text)
        }
    }

    @ViewBuilder
    private func list(_ title: LocalizedStringKey, _ entries: [String]) -> some View {
        if !entries.isEmpty {
            Text(title).font(.subheadline.weight(.semibold))
            ForEach(entries, id: \.self) { entry in
                Text(verbatim: "• \(entry)")
            }
        }
    }
}

/// Verlauf einer Aufgabe (M2).
struct WorkItemHistoryView: View {
    @Environment(LibraryStore.self) private var library
    let workItemId: WorkItemID
    @State private var events: [TaskEvent]?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let events {
                if events.isEmpty { Text("Noch keine Ereignisse.").foregroundStyle(.secondary) }
                ForEach(events.sorted { $0.timestamp > $1.timestamp }) { event in
                    EventRow(event: event, showTask: false)
                }
            } else {
                ProgressView()
            }
        }
        .task(id: library.snapshot.loadedAt) {
            events = await library.events(for: workItemId)
        }
    }
}

/// Konflikt zwischen Datenbank und Request-Datei/GitHub: beide Stände nebeneinander, Entscheidung durch Sie (N2).
struct FileConflictView: View {
    let conflict: FileConflict

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: conflict.location).font(.system(.callout, design: .monospaced))
                if let detail = conflict.detail { Text(detail) }
                Text("Erkannt: \(conflict.detectedAt.shortDateTime)").font(.caption).foregroundStyle(.secondary)
                if conflict.hasPendingRequest, let requested = conflict.requestedResolution {
                    Label("Entscheidung angefordert: \(requested.displayName)", systemImage: "hourglass")
                        .foregroundStyle(.blue)
                }
                SideBySideDiffView(
                    leftTitle: String(localized: "Stand in der App"),
                    rightTitle: conflict.kind == .gitHubDivergence ? String(localized: "Stand auf GitHub") : String(localized: "Stand in der Datei"),
                    left: conflict.databaseText ?? String(localized: "(nicht vorhanden)"),
                    right: conflict.externalText ?? String(localized: "(nicht vorhanden)")
                )
                .frame(minHeight: 160, maxHeight: 360)
                HStack {
                    CommandButton(String(localized: "App-Stand behalten"), systemImage: "arrow.left",
                                  confirmation: String(localized: "Die Datei wird mit dem Stand der App überschrieben.")) {
                        .resolveFileConflict(conflictId: conflict.id, resolution: .keptDatabase)
                    }
                    CommandButton(String(localized: "Externen Stand übernehmen"), systemImage: "arrow.right",
                                  confirmation: String(localized: "Der externe Stand wird in die App übernommen.")) {
                        .resolveFileConflict(conflictId: conflict.id, resolution: .acceptedExternal)
                    }
                    CommandButton(String(localized: "Verwerfen"), systemImage: "xmark") {
                        .resolveFileConflict(conflictId: conflict.id, resolution: .dismissed)
                    }
                }
            }
        } label: {
            Label(conflict.kind.displayName, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }
}
