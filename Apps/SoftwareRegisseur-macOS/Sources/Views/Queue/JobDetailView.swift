import SwiftUI
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC

/// Details eines Jobs: Konfiguration (J2a), Zeitplan (K1–K3), hostlokale Laufzeitdaten und Steueraktionen.
struct JobDetailView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(CommandCenter.self) private var commands
    @Environment(NavigationModel.self) private var navigation
    @Environment(ServiceMonitor.self) private var monitor
    let job: AgentJob
    @State private var status: JobStatusInfo?
    @State private var statusError: String?
    @State private var showReplace = false
    @State private var showQuotaReset = false

    var body: some View {
        let snapshot = library.snapshot
        let item = snapshot.workItem(job.workItemId)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(ProviderNames.displayName(job.providerId)) · \(job.state.germanDisplayName)")
                            .font(.title2.bold())
                        Spacer()
                    }
                    if let item {
                        Button {
                            navigation.showWorkItem(item)
                        } label: {
                            Label(item.displayTitle, systemImage: "doc.text")
                        }
                        .buttonStyle(.link)
                    }
                    Text(snapshot.projectName(job.projectId)).foregroundStyle(.secondary)
                }
                if let error = job.lastError {
                    Label(error, systemImage: "xmark.octagon").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                actionBar
                let approvals = snapshot.approvals(for: job.jobId)
                if !approvals.isEmpty {
                    ForEach(approvals) { ApprovalCard(approval: $0) }
                }
                GroupBox {
                    scheduleSection(snapshot)
                } label: { Text("Zeitplan") }
                GroupBox {
                    configurationSection
                } label: { Text("Modell und Denkstufe") }
                GroupBox {
                    runtimeSection
                } label: { Text("Ausführung auf diesem Mac") }
            }
            .padding(16)
        }
        .task(id: job.revision) { await loadStatus() }
        .sheet(isPresented: $showReplace) {
            ReplaceConfigurationSheet(job: job)
        }
        .sheet(isPresented: $showQuotaReset) {
            QuotaResetSheet(job: job)
        }
    }

    private var actionBar: some View {
        let actions = JobAction.available(for: job, status: status)
        return VStack(alignment: .leading, spacing: 6) {
            // Umbrechend: in der schmalen Detailspalte wurden die Aktionen sonst bis auf ein Zeichen gekürzt.
            FlowLayout(spacing: 6) {
                ForEach(actions) { action in
                    actionButton(action)
                }
                if !job.state.isTerminal {
                    Picker("Priorität", selection: Binding(get: { job.priority }, set: { reprioritize($0) })) {
                        ForEach(Priority.allCases, id: \.self) { Text($0.germanDisplayName).tag($0) }
                    }
                    .fixedSize()
                }
            }
            if actions.isEmpty && job.state.isTerminal == false {
                Text("Für diesen Zustand sind keine Steueraktionen möglich.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ action: JobAction) -> some View {
        switch action {
        case .replaceConfiguration:
            Button { showReplace = true } label: { Label(action.title, systemImage: action.symbolName) }
        case .setExpectedQuotaReset:
            Button { showQuotaReset = true } label: { Label(action.title, systemImage: action.symbolName) }
        default:
            if let request = action.request(for: job.jobId) {
                CommandButton(action.title, systemImage: action.symbolName, role: action.isDestructive ? .destructive : nil,
                              confirmation: confirmation(for: action)) { request } onResult: { _ in
                    Task { await loadStatus() }
                }
            }
        }
    }

    private func confirmation(for action: JobAction) -> String? {
        switch action {
        case .cancel: String(localized: "Der Job wird abgebrochen; die Aufgabe kehrt in ihren vorherigen Status zurück.")
        case .terminateOrphanedProcess: String(localized: "Der nach einem Dienstneustart verwaiste Agentenprozess wird beendet.")
        case .removeWorktree: String(localized: "Der Worktree wird entfernt. Der Branch bleibt erhalten.")
        default: nil
        }
    }

    private func reprioritize(_ priority: Priority) {
        guard priority != job.priority else { return }
        Task {
            await commands.perform(String(localized: "Priorität ändern"), .reprioritizeJob(jobId: job.jobId, priority: priority))
        }
    }

    private func scheduleSection(_ snapshot: LibrarySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            InfoRow("Plan", status?.scheduleText
                    ?? JobScheduleText.text(for: job, hostLastSeen: snapshot.hosts.map(\.lastSeen).max(), now: .now))
            if let planned = status?.plannedStart ?? job.scheduledAt {
                InfoRow("Geplanter Start", planned.shortDateTime)
            }
            InfoRow("Nachholregel", job.schedule.missedRunPolicy.displayName)
            if let zone = ScheduleStatusText.timeZone(of: job.schedule) {
                InfoRow("Zeitzone", zone.identifier)
            }
            if let block = status?.admissionBlock ?? monitor.currentSummary?.queue.admissionBlocks[job.jobId] {
                Label(block, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
            }
            if status?.awaitingMissedRunDecision == true {
                Label("Der geplante Termin wurde verpasst. Bitte entscheiden Sie: jetzt nachholen oder überspringen.",
                      systemImage: "clock.badge.exclamationmark")
                    .foregroundStyle(.orange)
            }
            if let next = status?.nextQuotaAttempt {
                InfoRow("Nächster Kontingentversuch", next.shortDateTime)
            }
        }
    }

    private var configurationSection: some View {
        let text = JobConfigurationText(job: job)
        return VStack(alignment: .leading, spacing: 6) {
            InfoRow("Angefragt", text.requested)
            InfoRow("Aufgelöst", text.resolved)
            InfoRow("Effektiv (bestätigt)", text.effective)
            InfoRow("Herkunft", text.sources)
            InfoRow("Agentenversion", job.agentVersion)
            InfoRow("Fähigkeitsstand", "\(job.capabilityRevision)")
            if job.state == .needsConfiguration {
                Label("Die gespeicherte Kombination ist nicht mehr zulässig. Wählen Sie über „Modell/Stufe ersetzen“ ausdrücklich eine neue.",
                      systemImage: "slider.horizontal.3")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var runtimeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let status {
                InfoRow("Prozess", status.isLive ? String(localized: "läuft (PID \(status.processIdentifier.map(String.init) ?? "–"))")
                        : String(localized: "kein laufender Prozess"))
                if status.orphanedProcess {
                    Label("Verwaister Agentenprozess nach Dienstneustart.", systemImage: "bolt.slash").foregroundStyle(.orange)
                }
                if let branch = status.branch ?? job.branch { InfoRow("Branch", branch) }
                if let repo = status.repositoryPath { InfoRow("Repository", repo) }
                if let worktree = status.worktreePath ?? job.worktreePath {
                    InfoRow("Worktree", worktree)
                    if LocalOpener.exists(worktree) {
                        HStack {
                            Button { LocalOpener.revealInFinder(worktree) } label: { Label("Im Finder zeigen", systemImage: "folder") }
                            Button { LocalOpener.openInTerminal(worktree) } label: { Label("Im Terminal öffnen", systemImage: "terminal") }
                        }
                    }
                }
            } else if let statusError {
                Text(statusError).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
            if let session = job.sessionId { InfoRow("Sitzung", session) }
            if let started = job.startedAt { InfoRow("Gestartet", started.shortDateTime) }
            if let finished = job.finishedAt { InfoRow("Beendet", finished.shortDateTime) }
            InfoRow("Angelegt", job.createdAt.shortDateTime)
            if job.retryCount > 0 { InfoRow("Wiederholungen", "\(job.retryCount)") }
            InfoRow("Job-ID", job.jobId.uuidString)
        }
    }

    private func loadStatus() async {
        let outcome = await commands.perform(String(localized: "Jobdetails laden"), .jobStatus(jobId: job.jobId), quiet: true)
        if case let .jobStatus(info)? = outcome.result {
            status = info
            statusError = nil
        } else {
            statusError = outcome.feedback.message
        }
    }
}

/// Modell/Stufe eines noch nicht gestarteten Jobs ausdrücklich ersetzen (J2a, A40).
struct ReplaceConfigurationSheet: View {
    @Environment(LibraryStore.self) private var library
    @Environment(ServiceMonitor.self) private var monitor
    @Environment(CommandCenter.self) private var commands
    @Environment(\.dismiss) private var dismiss
    let job: AgentJob
    @State private var model: ModelSelection?
    @State private var effort: EffortLevel?
    @State private var error: String?

    var body: some View {
        let capability = library.snapshot.capabilities(hostId: monitor.currentSummary?.hostId).first { $0.providerId == job.providerId }
        VStack(alignment: .leading, spacing: 12) {
            Text("Modell und Stufe ersetzen").font(.title2.bold())
            Text("Bisher: \(JobConfigurationText(job: job).resolved)").foregroundStyle(.secondary)
            if let capability {
                Form {
                    Picker("Modell", selection: $model) {
                        Text("Projekt-/Globalstandard").tag(ModelSelection?.none)
                        ForEach(ModelEffortChoices.models(for: capability)) { choice in
                            Text(choice.selection == .providerDefault ? ModelSelection.providerDefault.germanDisplayName : choice.displayName)
                                .tag(ModelSelection?.some(choice.selection))
                                .selectionDisabled(!choice.isSelectable)
                        }
                    }
                    Picker("Denkstufe", selection: $effort) {
                        Text("Projekt-/Globalstandard").tag(EffortLevel?.none)
                        ForEach(ModelEffortChoices.efforts(for: capability, model: model ?? job.resolvedModel), id: \.self) { effort in
                            Text(effort.germanDisplayName).tag(EffortLevel?.some(effort))
                        }
                    }
                    if let hint = capability.effortSelectionHint { Text(hint).font(.caption) }
                    let issues = ModelEffortResolver.validate(model: model ?? job.resolvedModel, effort: effort ?? .auto, against: capability)
                    ForEach(issues, id: \.self) { issue in
                        Label(issue.germanDescription, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
                .formStyle(.grouped)
            } else {
                UnavailableNotice(text: String(localized: "\(ProviderNames.displayName(job.providerId)) wurde auf diesem Mac nicht erkannt; ohne aktuelle Fähigkeiten ist keine Auswahl möglich."))
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Ersetzen") {
                    Task {
                        let outcome = await commands.perform(String(localized: "Modell/Stufe ersetzen"),
                                                             .replaceJobConfiguration(jobId: job.jobId, model: model, effort: effort))
                        if outcome.succeeded { dismiss() } else { error = outcome.feedback.message }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(capability == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onChange(of: model) { effort = nil }
    }
}

/// Erwarteter Kontingent-Reset (K2: Eingabe des Benutzers, nicht vom Anbieter ausgelesen).
struct QuotaResetSheet: View {
    @Environment(CommandCenter.self) private var commands
    @Environment(\.dismiss) private var dismiss
    let job: AgentJob
    @State private var date = Calendar.current.date(byAdding: .hour, value: 1, to: .now) ?? .now
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Erwarteten Kontingent-Reset setzen").font(.title2.bold())
            Text("Der Job startet frühestens zu diesem Zeitpunkt erneut. Software Regisseur liest Reset-Zeiten nicht vom Anbieter aus.")
                .fixedSize(horizontal: false, vertical: true)
            DatePicker("Reset erwartet um", selection: $date, in: Date.now...)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Setzen") {
                    Task {
                        let outcome = await commands.perform(String(localized: "Kontingent-Reset setzen"),
                                                             .setExpectedQuotaReset(jobId: job.jobId, at: date))
                        if outcome.succeeded { dismiss() } else { error = outcome.feedback.message }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// Job für eine beliebige startbare Aufgabe anlegen (Warteschlange → „Job starten oder planen“).
struct NewJobSheet: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var selected: WorkItemID?
    @State private var search = ""

    var body: some View {
        if let selected, let item = library.snapshot.workItem(selected) {
            JobRequestSheet(item: item)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Aufgabe wählen").font(.title2.bold())
                TextField("Suchen", text: $search).textFieldStyle(.roundedBorder)
                List(candidates, selection: $selected) { item in
                    TaskRow(item: item).tag(item.uuid)
                }
                .frame(minHeight: 320)
                HStack {
                    Spacer()
                    Button("Abbrechen", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
            .padding(20)
            .frame(width: 560, height: 520)
        }
    }

    private var candidates: [WorkItem] {
        var query = TaskQuery()
        query.searchText = search
        return query.apply(to: library.snapshot.workItems).filter {
            $0.projectId != nil && $0.status.canStartAgentJob && library.snapshot.activeJob(for: $0.uuid) == nil
        }
    }
}
