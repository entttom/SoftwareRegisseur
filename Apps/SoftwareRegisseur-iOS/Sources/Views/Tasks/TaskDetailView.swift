import SwiftUI
import SoftwareRegisseurAI
import SoftwareRegisseurAppCore
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

/// Task detail (spec P 4, H1, H3, J2a, M2): original note, transcript, AI drafts and versions,
/// dependencies, agent runs, history; edit, duplicate, status, undo, conflicts.
struct TaskDetailView: View {
    @Environment(AppModel.self) private var model
    let itemID: WorkItemID

    private enum Undo {
        case edit(WorkItemEdit)
        case status(WorkItemStatus)
    }

    private enum SheetKind: String, Identifiable {
        case agent, draft, conversation, edit, assign
        var id: String { rawValue }
    }

    @State private var item: WorkItem?
    @State private var catalog = Catalog()
    @State private var jobs: [AgentJob] = []
    @State private var approvals: [JobID: [ApprovalItem]] = [:]
    @State private var events: [TaskEvent] = []
    @State private var reviews: [Review] = []
    @State private var versions: [DraftVersion] = []
    @State private var aiRequests: [AIRequest] = []
    @State private var conflicts: [SyncConflict] = []
    @State private var hasActiveJob = false
    @State private var error: String?
    @State private var sheet: SheetKind?
    @State private var undo: Undo?
    @State private var confirmsDelete = false
    @State private var jobToCancel: AgentJob?
    @State private var isMissing = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let item {
                content(item)
            } else if isMissing {
                ContentUnavailableView("Aufgabe nicht gefunden", systemImage: "questionmark.folder")
            } else {
                ProgressView()
            }
        }
        .navigationTitle(item?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.sync(.pullToRefresh) }
        .reloadOnDataChange { await load() }
        .sheet(item: $sheet) { kind in
            if let item {
                switch kind {
                // Long forms and drafts get the larger page sheet on the iPad (ADR-0025).
                case .agent: AgentLaunchView(item: item).presentationSizing(.page)
                case .draft: DraftingView(item: item).presentationSizing(.page)
                case .conversation: ConversationView(item: item).presentationSizing(.page)
                case .edit: TaskEditView(item: item) { previous in undo = .edit(previous) }
                case .assign: AssignProjectView(item: item)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let undo {
                UndoBar(message: undoMessage(undo)) {
                    Task { await perform(undo) }
                } dismiss: {
                    self.undo = nil
                }
            }
        }
        .confirmationDialog("Aufgabe löschen?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) { Task { await delete() } }
        } message: {
            Text("Die Aufgabe wird auf allen Geräten entfernt. Eine Request-Datei im Repository ändert nur der Mac.")
        }
        .confirmationDialog("Auftrag abbrechen?", isPresented: Binding(get: { jobToCancel != nil }, set: { if !$0 { jobToCancel = nil } }),
                            titleVisibility: .visible) {
            Button("Auftrag abbrechen", role: .destructive) {
                if let job = jobToCancel { Task { await cancel(job) } }
            }
        } message: {
            Text("Hat der Mac den Auftrag bereits übernommen, entscheidet der Mac (er ist für Laufzustände maßgeblich).")
        }
    }

    @ViewBuilder
    private func content(_ item: WorkItem) -> some View {
        List {
            if let error { ErrorText(message: error) }
            if !conflicts.isEmpty {
                Section {
                    ForEach(conflicts) { conflict in
                        NavigationLink {
                            ConflictResolutionView(conflict: conflict)
                        } label: {
                            Label("Synchronisierungskonflikt – beide Versionen wurden behalten. Bitte entscheiden.",
                                  systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            headerSection(item)
            actionsSection(item)
            textSection(title: "Beschreibung", text: item.structuredBody, empty: "Noch keine ausgearbeitete Beschreibung.")
            textSection(title: "Originalnotiz", text: item.originalNote, empty: "Keine Originalnotiz.")
            if let transcript = item.transcript {
                textSection(title: "Transkript", text: transcript, empty: "")
            }
            draftsSection
            dependenciesSection(item)
            jobsSection
            if !reviews.isEmpty { reviewSection }
            historySection
        }
        .accessibilityIdentifier("task.detail")
        .readableContentWidth()
    }

    private func headerSection(_ item: WorkItem) -> some View {
        Section {
            Text(item.title).font(.title3.bold())
            LabeledContent { Text(humanIDText(item)).font(.body.monospaced()) } label: { Text("Nummer") }
            LabeledContent { Text(item.type.title) } label: { Text("Typ") }
            LabeledContent {
                StatusBadge(title: item.status.title, symbol: item.status.symbol, tint: item.status.tint)
            } label: {
                Text("Aufgabenstatus")
            }
            if let job = jobs.first(where: { !$0.state.isTerminal }) {
                LabeledContent { Text(job.state.title) } label: { Text("Agentenlauf") }
                if let status = ScheduleStatusText.status(for: job, hostLastSeen: catalog.host(job.hostId)?.lastSeen, now: .now) {
                    Text(verbatim: status).font(.caption).foregroundStyle(.secondary)
                }
            }
            if item.isArchived {
                Label("Archiviert", systemImage: "archivebox").foregroundStyle(.secondary)
            }
            LabeledContent { Text(item.priority.title) } label: { Text("Priorität") }
            if let complexity = item.complexity {
                LabeledContent { Text(complexity.title) } label: { Text("Komplexität") }
            }
            LabeledContent {
                Text(verbatim: catalog.projectName(item.projectId) ?? String(localized: "Kein Projekt (Inbox)"))
            } label: {
                Text("Projekt")
            }
            if !item.labels.isEmpty {
                LabeledContent { Text(verbatim: item.labels.joined(separator: ", ")) } label: { Text("Labels") }
            }
            LabeledContent { Text(item.updatedAt, format: .dateTime) } label: { Text("Geändert") }
        }
    }

    private func actionsSection(_ item: WorkItem) -> some View {
        Section {
            if item.projectId == nil {
                Button { sheet = .assign } label: { Label("Projekt zuweisen", systemImage: "folder.badge.plus") }
            }
            Button { sheet = .agent } label: { Label("Mit Agent umsetzen", systemImage: "cpu") }
                .accessibilityIdentifier("task.startAgent")
            Button { sheet = .draft } label: { Label("Mit KI ausarbeiten", systemImage: "sparkles") }
            Button { sheet = .conversation } label: { Label("Mit KI besprechen", systemImage: "bubble.left.and.text.bubble.right") }
            Button { sheet = .edit } label: { Label("Bearbeiten", systemImage: "pencil") }
            Button { Task { await duplicate(item) } } label: { Label("Duplizieren", systemImage: "plus.square.on.square") }
            if TaskEditor.canReclassify(item, hasActiveJob: hasActiveJob) {
                Menu {
                    ForEach(WorkItemType.allCases.filter { $0 != item.type }, id: \.self) { type in
                        Button { Task { await reclassify(item, to: type) } } label: { Text(type.title) }
                    }
                } label: {
                    Label("Typ ändern", systemImage: "tag")
                }
            }
            Button { Task { await setArchived(item, !item.isArchived) } } label: {
                if item.isArchived {
                    Label("Aus dem Archiv holen", systemImage: "tray.and.arrow.up")
                } else {
                    Label("Archivieren", systemImage: "archivebox")
                }
            }
            let targets = TaskEditor.manualTargets(from: item.status, hasActiveJob: hasActiveJob)
            if hasActiveJob {
                Text("Der Status wird während des Agentenlaufs vom Mac abgeleitet.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !targets.isEmpty {
                Menu {
                    ForEach(targets, id: \.self) { status in
                        Button { Task { await changeStatus(item, to: status) } } label: { Text(status.title) }
                    }
                } label: {
                    Label("Status ändern", systemImage: "arrow.left.arrow.right")
                }
            }
            if !hasActiveJob {
                Button(role: .destructive) { confirmsDelete = true } label: { Label("Löschen", systemImage: "trash") }
            }
        } header: {
            Text("Aktionen")
        }
    }

    private func textSection(title: LocalizedStringResource, text: String, empty: LocalizedStringResource) -> some View {
        Section {
            if text.isEmpty {
                Text(empty).foregroundStyle(.secondary)
            } else if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                Text(attributed).textSelection(.enabled)
            } else {
                Text(verbatim: text).textSelection(.enabled)
            }
        } header: {
            Text(title)
        }
    }

    private var draftsSection: some View {
        Section {
            if versions.isEmpty && aiRequests.isEmpty {
                Text("Noch keine KI-Entwürfe.").foregroundStyle(.secondary)
            }
            ForEach(versions.reversed()) { version in
                NavigationLink {
                    DraftVersionView(version: version)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Version \(version.version) – \(version.source.title)")
                        if let provider = version.providerId {
                            Text(verbatim: "\(provider.rawValue) · \(version.modelId?.rawValue ?? "–")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(version.createdAt, format: .dateTime)
                            .font(.caption).foregroundStyle(.secondary)
                        if !version.adoptedDraftIndexes.isEmpty {
                            Text("Übernommen").font(.caption).foregroundStyle(.green)
                        }
                    }
                }
            }
            let queued = aiRequests.filter { $0.mode == .withRepositoryContext && $0.state == .pending }
            if !queued.isEmpty {
                Label("Vertiefte Ausarbeitung mit Repo-Kontext wartet auf den Mac.", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("KI-Entwürfe")
        } footer: {
            Text("Originalnotiz, Transkript und KI-Entwürfe werden getrennt versioniert und mit allen Geräten synchronisiert. Ein Entwurf wird erst nach Ihrer Freigabe übernommen.")
        }
    }

    private func dependenciesSection(_ item: WorkItem) -> some View {
        Section {
            if item.dependencies.isEmpty {
                Text("Keine Abhängigkeiten.").foregroundStyle(.secondary)
            }
            ForEach(item.dependencies, id: \.self) { dependency in
                if let other = catalog.item(dependency) {
                    NavigationLink(value: AppRoute.task(other.uuid)) {
                        WorkItemRow(item: other)
                    }
                } else {
                    Text(verbatim: dependency.uuidString).font(.caption.monospaced())
                }
            }
        } header: {
            Text("Abhängigkeiten")
        }
    }

    private var jobsSection: some View {
        Section {
            if jobs.isEmpty {
                Text("Noch kein Agentenlauf.").foregroundStyle(.secondary)
            }
            ForEach(jobs.sorted { $0.createdAt > $1.createdAt }) { job in
                JobDetailRows(job: job, hostLastSeen: catalog.host(job.hostId)?.lastSeen)
                ApprovalRows(items: approvals[job.jobId] ?? []) { model.noteLocalChange() }
                if job.state == .requested || job.state == .pendingMac || job.state == .scheduled,
                   case .manualPause = job.schedule.kind {
                    Button { Task { await release(job) } } label: {
                        Label("Jetzt zum Start freigeben", systemImage: "play.circle")
                    }
                }
                if [.requested, .pendingMac, .scheduled, .needsConfiguration, .waitingQuota, .paused].contains(job.state) {
                    Button(role: .destructive) { jobToCancel = job } label: {
                        Label("Auftrag abbrechen", systemImage: "xmark.circle")
                    }
                }
            }
        } header: {
            Text("Agentenläufe")
        }
    }

    private var reviewSection: some View {
        Section {
            ForEach(reviews) { review in
                NavigationLink(value: AppRoute.review(item: itemID, review: review.id, fromTask: true)) {
                    VStack(alignment: .leading) {
                        Text(review.decision.title)
                        Text("\(review.diffSummary.filesChanged) Dateien, +\(review.diffSummary.insertions) / −\(review.diffSummary.deletions)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Review")
        }
    }

    private var historySection: some View {
        Section {
            if events.isEmpty {
                Text("Noch keine Einträge.").foregroundStyle(.secondary)
            }
            ForEach(events.reversed()) { event in
                VStack(alignment: .leading, spacing: 2) {
                    Text(eventTitle(event))
                    Text(event.timestamp, format: .dateTime).font(.caption).foregroundStyle(.secondary)
                    if let detail = eventDetail(event) {
                        Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Verlauf")
        }
    }

    // MARK: Data

    private func load() async {
        guard let database = model.database else { return }
        do {
            guard let fetched = try await database.workItems.fetch(itemID) else {
                item = nil
                isMissing = true
                return
            }
            item = fetched
            catalog = try await model.loadCatalog(includeAgents: false)
            jobs = try await database.jobs.jobs(forWorkItem: itemID)
            hasActiveJob = jobs.contains { !$0.state.isTerminal }
            events = try await database.events.events(forWorkItem: itemID)
            var loadedReviews: [Review] = []
            for job in jobs { loadedReviews += try await database.reviews.reviews(jobId: job.jobId) }
            reviews = loadedReviews
            aiRequests = try await database.aiRecords.requests(itemId: itemID)
            versions = (try? await model.draftVersions?.versions(for: itemID)) ?? []
            let center = ApprovalCenter(approvals: database.approvals)
            var loadedApprovals: [JobID: [ApprovalItem]] = [:]
            for job in jobs { loadedApprovals[job.jobId] = try await center.items(jobId: job.jobId) }
            approvals = loadedApprovals
            conflicts = try await database.sync.openConflicts().filter { $0.entityType == .workItem && $0.entityId == itemID.rawValue }
            error = nil
        } catch {
            self.error = errorMessage(error)
        }
    }

    private func duplicate(_ item: WorkItem) async {
        guard let database = model.database else { return }
        do {
            let copy = try await TaskEditor(workItems: database.workItems)
                .duplicate(item, titleSuffix: String(localized: " (Kopie)"), actor: model.actor, at: .now)
            model.noteLocalChange()
            model.openTask(copy.uuid)
        } catch {
            self.error = errorMessage(error)
        }
    }

    private func reclassify(_ item: WorkItem, to type: WorkItemType) async {
        guard let database = model.database else { return }
        do {
            _ = try await TaskEditor(workItems: database.workItems).reclassify(item, to: type, actor: model.actor, at: .now)
            model.noteLocalChange()
        } catch {
            self.error = errorMessage(error)
        }
    }

    private func setArchived(_ item: WorkItem, _ archived: Bool) async {
        guard let database = model.database else { return }
        let editor = TaskEditor(workItems: database.workItems)
        do {
            _ = archived
                ? try await editor.archive(item, actor: model.actor, at: .now)
                : try await editor.unarchive(item, actor: model.actor, at: .now)
            model.noteLocalChange()
        } catch {
            self.error = errorMessage(error)
        }
    }

    private func changeStatus(_ item: WorkItem, to status: WorkItemStatus) async {
        guard let database = model.database else { return }
        do {
            let (_, previous) = try await TaskEditor(workItems: database.workItems).changeStatus(item, to: status, actor: model.actor, at: .now)
            // Undo only where the state machine allows the way back (ADR-0012).
            undo = status.canTransition(to: previous) ? .status(previous) : nil
            model.noteLocalChange()
        } catch {
            self.error = errorMessage(error)
        }
    }

    private func perform(_ undo: Undo) async {
        guard let database = model.database, let item else { return }
        let editor = TaskEditor(workItems: database.workItems)
        do {
            switch undo {
            case let .edit(previous):
                _ = try await editor.save(previous, to: item, actor: model.actor, at: .now)
            case let .status(previous):
                _ = try await editor.changeStatus(item, to: previous, actor: model.actor, at: .now)
            }
            self.undo = nil
            model.noteLocalChange()
        } catch {
            self.error = errorMessage(error)
            self.undo = nil
        }
    }

    private func undoMessage(_ undo: Undo) -> LocalizedStringResource {
        switch undo {
        case .edit: "Änderung gespeichert."
        case .status: "Status geändert."
        }
    }

    private func delete() async {
        guard let database = model.database, let item else { return }
        do {
            try await database.workItems.delete(item.uuid, expectedRevision: item.revision, at: .now)
            model.noteLocalChange()
            // Also clears the iPad detail column, where the task is the selection, not a pushed view.
            if !model.closeRoutes(to: item.uuid) { dismiss() }
        } catch {
            self.error = errorMessage(error)
        }
    }

    private func release(_ job: AgentJob) async {
        guard let database = model.database else { return }
        do {
            _ = try await database.jobs.update(job.jobId, expectedRevision: job.revision, actor: model.actor, at: .now) {
                $0.schedule = JobSchedule(kind: .immediate)
            }
            model.noteLocalChange()
        } catch {
            self.error = errorMessage(error)
        }
    }

    private func cancel(_ job: AgentJob) async {
        guard let database = model.database else { return }
        do {
            _ = try await database.jobs.transition(job.jobId, to: .cancelled, actor: model.actor, at: .now)
            model.noteLocalChange()
        } catch {
            self.error = errorMessage(error)
        }
        jobToCancel = nil
    }

    private func eventTitle(_ event: TaskEvent) -> LocalizedStringResource {
        switch event.kind {
        case .created: "Angelegt"
        case .edited: "Bearbeitet"
        case .statusChanged: "Status geändert"
        case .humanIDAssigned: "Nummer vergeben"
        case .jobRequested: "Agentenlauf angefordert"
        case .jobStateChanged: "Agentenlauf geändert"
        case .configurationReplaced: "Konfiguration ersetzt"
        case .lockAcquired: "Sperre gesetzt"
        case .lockReleased: "Sperre freigegeben"
        case .reviewDecided: "Review entschieden"
        case .integrated: "Integriert"
        case .externalChangeDetected: "Externe Änderung erkannt"
        case .conflictDetected: "Konflikt erkannt"
        case .comment: "Kommentar"
        case .approvalRequested: "Freigabe angefragt"
        case .approvalAnswered: "Freigabe beantwortet"
        case .approvalExpired: "Freigabe abgelaufen"
        case .quotaWait: "Wartet auf Kontingent"
        case .missedRun: "Geplanter Start verpasst"
        case .jobRetried: "Agentenlauf wiederholt"
        case .typeChanged: "Typ geändert"
        case .archived: "Archiviert"
        case .unarchived: "Aus dem Archiv geholt"
        }
    }

    private func eventDetail(_ event: TaskEvent) -> String? {
        if event.kind == .typeChanged,
           let from = event.payload["from"].flatMap(WorkItemType.init(rawValue:)),
           let to = event.payload["to"].flatMap(WorkItemType.init(rawValue:)) {
            return "\(String(localized: from.title)) → \(String(localized: to.title))"
        }
        if let text = event.payload["text"], [.quotaWait, .missedRun].contains(event.kind) { return text }
        if event.kind == .approvalRequested, let summary = event.payload["summary"] { return summary }
        if let from = event.payload["from"].flatMap(WorkItemStatus.init(rawValue:)),
           let to = event.payload["to"].flatMap(WorkItemStatus.init(rawValue:)) {
            return "\(String(localized: from.title)) → \(String(localized: to.title))"
        }
        if let from = event.payload["from"].flatMap(AgentJobState.init(rawValue:)),
           let to = event.payload["to"].flatMap(AgentJobState.init(rawValue:)) {
            return "\(String(localized: from.title)) → \(String(localized: to.title))"
        }
        return nil
    }
}

/// Configuration and state of one agent run (spec J2a: requested/resolved/effective, profile source,
/// capability revision, agent version; effective values only when confirmed).
struct JobDetailRows: View {
    let job: AgentJob
    var hostLastSeen: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: job.providerId.rawValue).font(.headline)
                Spacer()
                Text(job.state.title).font(.callout)
            }
            grid
            if let status = ScheduleStatusText.status(for: job, hostLastSeen: hostLastSeen, now: .now) {
                Text(verbatim: status).font(.caption).foregroundStyle(.secondary)
            }
            if job.isRetry {
                Label("Wiederholung eines früheren Laufs", systemImage: "arrow.clockwise").font(.caption).foregroundStyle(.secondary)
            }
            if let error = job.lastError {
                ErrorText(message: error)
            }
        }
        .padding(.vertical, 4)
    }

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text("Angefordert").foregroundStyle(.secondary)
                Text(verbatim: "\(String(localized: job.configSnapshot.requestedModel?.title ?? "Standard")) · \(String(localized: job.requestedEffort?.title ?? "Standard"))")
            }
            GridRow {
                Text("Aufgelöst").foregroundStyle(.secondary)
                Text(verbatim: "\(String(localized: job.resolvedModel.title)) · \(String(localized: job.resolvedEffort.title))")
            }
            GridRow {
                Text("Quelle").foregroundStyle(.secondary)
                Text(verbatim: "\(String(localized: job.profileSource.model.title)) / \(String(localized: job.profileSource.effort.title))")
            }
            GridRow {
                Text("Effektiv").foregroundStyle(.secondary)
                if job.effectiveModelId == nil && job.effectiveEffort == nil {
                    Text("nicht bestätigt")
                } else {
                    Text(verbatim: "\(job.effectiveModelId?.rawValue ?? String(localized: "nicht bestätigt")) · \(job.effectiveEffort.map { String(localized: $0.title) } ?? String(localized: "nicht bestätigt"))")
                }
            }
            GridRow {
                Text("Agentenversion").foregroundStyle(.secondary)
                Text(verbatim: "\(job.agentVersion) (Rev. \(job.capabilityRevision))")
            }
            GridRow {
                Text("Start").foregroundStyle(.secondary)
                scheduleText
            }
            if let branch = job.branch {
                GridRow {
                    Text("Branch").foregroundStyle(.secondary)
                    Text(verbatim: branch).font(.caption.monospaced())
                }
            }
            if let session = job.sessionId {
                GridRow {
                    Text("Sitzung").foregroundStyle(.secondary)
                    Text(verbatim: session).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private var scheduleText: some View {
        switch job.schedule.kind {
        case .immediate: Text("Sofort")
        case .manualPause: Text("Nach Freigabe")
        case let .at(local):
            if let date = try? local.resolve().date {
                Text(verbatim: "\(date.formatted(.dateTime.timeZone(.identifier(.long)).day().month().year().hour().minute())) (\(local.timeZoneIdentifier))")
            }
        case let .notBefore(date): Text("Frühestens \(date.formatted(.dateTime.day().month().hour().minute()))")
        case let .retryAfterQuota(state):
            if state.isUserRequested {
                Text("Bei verfügbarem Kontingent, frühestens \(state.nextAttemptAt.formatted(.dateTime.day().month().hour().minute()))")
            } else {
                Text("Nächster Versuch \(state.nextAttemptAt.formatted(.dateTime.day().month().hour().minute()))")
            }
        }
    }
}

struct DraftVersionView: View {
    let version: DraftVersion

    var body: some View {
        List {
            Section {
                LabeledContent { Text(version.source.title) } label: { Text("Quelle") }
                if let provider = version.providerId {
                    LabeledContent { Text(verbatim: provider.rawValue) } label: { Text("Anbieter") }
                }
                if let modelId = version.modelId {
                    LabeledContent { Text(verbatim: modelId.rawValue) } label: { Text("Modell") }
                }
                if let mode = version.draftMode {
                    LabeledContent { Text(mode.title) } label: { Text("Modus") }
                }
                if version.source == .ai {
                    LabeledContent { Text("\(version.usage.inputTokens) / \(version.usage.outputTokens)") } label: { Text("Tokens (Eingabe/Ausgabe)") }
                }
                LabeledContent { Text(version.createdAt, format: .dateTime) } label: { Text("Erstellt") }
                if let accepted = version.acceptedAt {
                    LabeledContent { Text(accepted, format: .dateTime) } label: { Text("Übernommen") }
                }
            }
            if let text = version.text {
                Section {
                    Text(verbatim: text).textSelection(.enabled)
                } header: {
                    Text("Text")
                }
            }
            ForEach(Array(version.drafts.enumerated()), id: \.offset) { index, draft in
                Section {
                    DraftContentView(draft: draft)
                } header: {
                    Text(version.adoptedDraftIndexes.contains(index) ? "Entwurf – übernommen" : "Entwurf")
                }
            }
        }
        .navigationTitle(Text("Version \(version.version)"))
    }
}

extension DraftVersionSource {
    var title: LocalizedStringResource {
        switch self {
        case .original: "Originalnotiz"
        case .transcript: "Transkript"
        case .ai: "KI-Entwurf"
        }
    }
}
