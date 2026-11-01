import AppKit
import SwiftUI
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC

/// Details eines Projekts. Alle Änderungen laufen als Dienstbefehle mit Vorschau (E3, F2, G).
struct ProjectDetailView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(ServiceMonitor.self) private var monitor
    let entry: ProjectEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                overview
                if needsRelink {
                    GroupBox { RelinkSection(entry: entry) } label: { Text("Neu verknüpfen") }
                }
                GroupBox { ProjectSettingsSummary(entry: entry) } label: { Text("Projekteinstellungen") }
                GroupBox { FolderMigrationSection(entry: entry) } label: { Text("Ordnerstruktur") }
                GroupBox { InstructionProposalsSection(projectId: entry.id) } label: { Text("AGENTS.md / CLAUDE.md") }
                GroupBox { GitHubSection(projectId: entry.id) } label: { Text("GitHub Issues") }
                if !entry.setupCommands.isEmpty {
                    GroupBox { SetupCommandsSection(commands: entry.setupCommands) } label: { Text("Einrichtungsaufträge") }
                }
            }
            .padding(16)
        }
    }

    private var location: RepositoryLocation? {
        entry.location(hostId: monitor.currentSummary?.hostId)
    }

    private var needsRelink: Bool {
        entry.project.status == .unavailable || entry.project.status == .needsAttention || location == nil
            || location.map { !LocalOpener.exists($0.canonicalPath) } == true
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(entry.project.name).font(.title2.bold())
            Badge(text: entry.project.status.germanDisplayName, color: entry.project.status.level.color)
            Spacer()
        }
    }

    private var overview: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                if let reason = entry.project.statusReason {
                    Label(reason, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                }
                InfoRow("Art", entry.project.repositoryKind.displayName)
                InfoRow("Remote", entry.project.remote ?? String(localized: "kein Remote"))
                if let location {
                    InfoRow("Pfad", location.canonicalPath)
                    InfoRow("Scan", location.scanState.displayName + (location.lastScanAt.map { " · " + $0.shortDateTime } ?? ""))
                } else {
                    InfoRow("Pfad", String(localized: "auf diesem Mac nicht verknüpft"))
                }
                InfoRow("Aufgaben", "\(library.snapshot.workItems.filter { $0.projectId == entry.id }.count)")
                InfoRow("ADRs", "\(entry.adrs.count)")
                if !entry.activeLocks.isEmpty {
                    InfoRow("Aktive Sperren", entry.activeLocks.map { $0.scope.displayName }.joined(separator: ", "))
                }
                HStack {
                    if let path = location?.canonicalPath, LocalOpener.exists(path) {
                        Button { LocalOpener.revealInFinder(path) } label: { Label("Im Finder zeigen", systemImage: "folder") }
                        Button { LocalOpener.openInTerminal(path) } label: { Label("Im Terminal öffnen", systemImage: "terminal") }
                    }
                    CommandButton(String(localized: "Markdown jetzt abgleichen"), systemImage: "arrow.triangle.2.circlepath") {
                        .reconcileProject(projectId: entry.id)
                    }
                }
                .padding(.top, 4)
            }
        } label: {
            Text("Übersicht")
        }
    }
}

/// Re-Link-Workflow (E1): nie kommentarlos löschen, Kandidaten anbieten oder Ordner wählen.
private struct RelinkSection: View {
    @Environment(CommandCenter.self) private var commands
    let entry: ProjectEntry
    @State private var candidates: [String]?
    @State private var allowDifferentRepository = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Der Projektordner ist auf diesem Mac nicht erreichbar oder wurde verschoben. Daten bleiben erhalten; verknüpfen Sie das Projekt mit dem neuen Ort.")
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Anderes Repository zulassen (nur wenn Sie sicher sind)", isOn: $allowDifferentRepository)
            FlowLayout(spacing: 6) {
                CommandButton(String(localized: "Kandidaten suchen"), systemImage: "magnifyingglass") {
                    .relinkCandidates(projectId: entry.id)
                } onResult: { outcome in
                    if case let .paths(paths)? = outcome.result { candidates = paths }
                }
                Button {
                    choose()
                } label: {
                    Label("Ordner wählen …", systemImage: "folder")
                }
            }
            if let candidates {
                if candidates.isEmpty {
                    Text("Keine Kandidaten gefunden.").foregroundStyle(.secondary)
                }
                ForEach(candidates, id: \.self) { path in
                    HStack {
                        Text(verbatim: path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        relinkButton(path)
                    }
                }
            }
        }
    }

    private func relinkButton(_ path: String) -> some View {
        CommandButton(String(localized: "Verknüpfen"), systemImage: "link",
                      confirmation: String(localized: "Projekt „\(entry.project.name)“ mit \(path) verknüpfen?")) {
            .relinkProject(projectId: entry.id, path: path, allowDifferentRepository: allowDifferentRepository)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Verknüpfen")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path(percentEncoded: false)
        Task {
            await commands.perform(String(localized: "Projekt neu verknüpfen"),
                                   .relinkProject(projectId: entry.id, path: path, allowDifferentRepository: allowDifferentRepository))
        }
    }
}

/// Projekteinstellungen (J2a, L1, ADR-0015): Anzeige und Bearbeitung über den Dienst. Modell/Stufe nur mit
/// Werten aus der Fähigkeitsmatrix; der Dienst prüft erneut und lehnt unzulässige Kombinationen ab.
private struct ProjectSettingsSummary: View {
    @Environment(LibraryStore.self) private var library
    @Environment(ServiceMonitor.self) private var monitor
    let entry: ProjectEntry
    @State private var editing = false

    var body: some View {
        if editing, let settings = entry.settings {
            ProjectSettingsEditor(
                form: ProjectSettingsForm(projectId: entry.id, settings: settings),
                capabilities: library.snapshot.capabilities(hostId: entry.project.hostId ?? monitor.currentSummary?.hostId)
            ) { editing = false }
        } else {
            summary
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let settings = entry.settings {
                InfoRow("Standardagent", settings.defaultAgentId.map(ProviderNames.displayName)
                        ?? String(localized: "Globaler Standard (\(library.snapshot.globalSettings.defaultAgentId.map(ProviderNames.displayName) ?? String(localized: "keiner")))"))
                ForEach(settings.agentModelPreferencesByProvider.keys.sorted(), id: \.self) { provider in
                    if let preference = settings.agentModelPreferencesByProvider[provider] {
                        InfoRow("Modell/Stufe", "\(ProviderNames.displayName(provider)): " + PreferenceText.describe(preference))
                    }
                }
                if settings.agentModelPreferencesByProvider.isEmpty {
                    InfoRow("Modell/Stufe", String(localized: "Globale Standards je Agent"))
                }
                InfoRow("Integrationsstrategie", settings.integrationStrategy.displayName)
                InfoRow("Review", settings.reviewPolicy.displayName)
                InfoRow("Parallelität", settings.allowParallel
                        ? (settings.maxParallelJobs.map { String(localized: "erlaubt, höchstens \($0) Jobs") } ?? String(localized: "erlaubt"))
                        : String(localized: "nicht erlaubt"))
                InfoRow("Projektweite Sperre", settings.projectWideLock ? String(localized: "ein Agent pro Repository") : String(localized: "aus"))
                InfoRow("Agentenanweisungen", settings.agentInstructionsPolicy.displayName)
            } else {
                Text("Für dieses Projekt sind noch keine Einstellungen gespeichert.").foregroundStyle(.secondary)
            }
            if entry.settings != nil {
                Button {
                    editing = true
                } label: {
                    Label("Einstellungen bearbeiten …", systemImage: "slider.horizontal.3")
                }
                Text("Die Ordnerstruktur ändern Sie unten mit Vorschau.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Bearbeitung der Projekteinstellungen (ohne Ordnerstruktur).
private struct ProjectSettingsEditor: View {
    @State var form: ProjectSettingsForm
    let capabilities: [AgentCapability]
    let onFinish: () -> Void

    var body: some View {
        let problems = form.problems(capabilities: capabilities)
        VStack(alignment: .leading, spacing: 8) {
            Picker("Standardagent", selection: $form.defaultAgentId) {
                Text("Globaler Standard").tag(ProviderID?.none)
                ForEach(capabilities, id: \.providerId) { capability in
                    Text(ProviderNames.displayName(capability.providerId)).tag(ProviderID?.some(capability.providerId))
                }
            }
            ForEach(capabilities, id: \.providerId) { capability in
                ModelChoicePicker(title: ProviderNames.displayName(capability.providerId), capability: capability,
                                  choice: Binding(get: { form.choice(for: capability.providerId) },
                                                  set: { form.choices[capability.providerId] = $0 }))
            }
            Picker("Integrationsstrategie", selection: $form.integrationStrategy) {
                ForEach(IntegrationStrategy.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("Review", selection: $form.reviewPolicy) {
                ForEach(ReviewPolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("Agentenanweisungen", selection: $form.agentInstructionsPolicy) {
                ForEach(AgentInstructionsPolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Toggle("Parallele Jobs erlauben", isOn: $form.allowParallel)
            HStack {
                Toggle("Höchstens", isOn: $form.limitParallelJobs)
                Stepper(value: $form.maxParallelJobs, in: ProjectSettingsCommand.parallelJobsRange) {
                    Text("\(form.maxParallelJobs) Jobs gleichzeitig").monospacedDigit()
                }
                .disabled(!form.limitParallelJobs)
            }
            .disabled(!form.allowParallel)
            Toggle("Projektweite Sperre: nur ein Agent pro Repository", isOn: $form.projectWideLock)
            ForEach(problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            HStack {
                Button("Abbrechen") { onFinish() }
                CommandButton(String(localized: "Projekteinstellungen speichern"), systemImage: "checkmark") {
                    .updateProjectSettings(form.command)
                } onResult: { outcome in
                    if outcome.succeeded { onFinish() }
                }
                .disabled(!problems.isEmpty)
            }
            Text("Änderungen gelten für neue Jobs; bereits angelegte Jobs behalten ihre Konfiguration (A38).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Modell und Stufe eines Agenten; „Erben“ übernimmt die nächsthöhere Ebene (ADR-0006).
struct ModelChoicePicker: View {
    let title: String
    let capability: AgentCapability
    @Binding var choice: AgentModelChoice

    var body: some View {
        let options = ModelChoiceOptions(capability: capability)
        HStack {
            Text(title).frame(minWidth: 110, alignment: .leading)
            Picker("Modell", selection: Binding(get: { choice.model }, set: { model in
                choice.model = model
                if !options.isValid(model: model, effort: choice.effort) { choice.effort = nil }
            })) {
                Text("Erben").tag(ModelSelection?.none)
                ForEach(options.models, id: \.self) { model in
                    Text(model.germanDisplayName).tag(ModelSelection?.some(model))
                }
            }
            Picker("Stufe", selection: $choice.effort) {
                Text("Erben").tag(EffortLevel?.none)
                ForEach(options.efforts(for: choice.model), id: \.self) { level in
                    Text(level.germanDisplayName).tag(EffortLevel?.some(level))
                }
            }
        }
    }
}

enum PreferenceText {
    static func describe(_ preference: AgentModelPreference) -> String {
        if preference.inheritsDefault { return String(localized: "erbt den Standard") }
        let model = preference.model?.germanDisplayName ?? String(localized: "Modell geerbt")
        let effort = preference.effort?.germanDisplayName ?? String(localized: "Stufe geerbt")
        return "\(model) · \(effort)"
    }
}

/// Ordnerstruktur mit Vorschau, Kollisionsprüfung und AGENTS.md-Diff (F2).
private struct FolderMigrationSection: View {
    @Environment(CommandCenter.self) private var commands
    let entry: ProjectEntry
    @State private var form: FolderLayoutForm?
    @State private var plan: FolderMigrationPlanInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let binding = Binding($form) {
                Grid(alignment: .leading, verticalSpacing: 4) {
                    row("ADR-Ordner", binding.adrPath)
                    row("Requests-Ordner", binding.requestsRoot)
                    row("Offen", binding.openPath)
                    row("In Arbeit", binding.activePath)
                    row("Review", binding.reviewPath)
                    row("Erledigt", binding.donePath)
                }
                ForEach(binding.wrappedValue.problems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                HStack {
                    CommandButton(String(localized: "Vorschau berechnen"), systemImage: "eye") {
                        .previewFolderMigration(projectId: entry.id, layout: layout(binding.wrappedValue))
                    } onResult: { outcome in
                        if case let .folderMigrationPlan(plan)? = outcome.result { self.plan = plan }
                    }
                    .disabled(!binding.wrappedValue.isValid || binding.wrappedValue == initialForm)
                    Button("Zurücksetzen") { form = initialForm; plan = nil }
                        .disabled(binding.wrappedValue == initialForm)
                }
            } else {
                Text("Ohne Projekteinstellungen ist keine Migration möglich.").foregroundStyle(.secondary)
            }
            if let plan {
                FolderMigrationPlanView(plan: plan) { self.plan = nil }
            }
        }
        .onAppear { form = initialForm }
    }

    private var initialForm: FolderLayoutForm? {
        guard let settings = entry.settings else { return nil }
        return FolderLayoutForm(adrPath: settings.adrPath, requestsRoot: settings.requestsRoot, openPath: settings.openPath,
                                activePath: settings.activePath, reviewPath: settings.reviewPath, donePath: settings.donePath)
    }

    private func row(_ label: LocalizedStringKey, _ value: Binding<String>) -> some View {
        GridRow {
            Text(label)
            TextField(text: value) { Text(label) }
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
        }
    }

    private func layout(_ form: FolderLayoutForm) -> FolderLayoutPaths {
        FolderLayoutPaths(adrPath: form.adrPath, requestsRoot: form.requestsRoot, openPath: form.openPath,
                          activePath: form.activePath, reviewPath: form.reviewPath, donePath: form.donePath)
    }
}

private struct FolderMigrationPlanView: View {
    let plan: FolderMigrationPlanInfo
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Vorschau: \(plan.moves.count) Verschiebungen, \(plan.collisions.count) Kollisionen").font(.headline)
            ForEach(Array(plan.moves.enumerated()), id: \.offset) { _, move in
                Text(verbatim: "\(move.source) → \(move.destination)")
                    .font(.system(.callout, design: .monospaced))
            }
            ForEach(Array(plan.collisions.enumerated()), id: \.offset) { _, collision in
                Label("\(collision.destination): \(collision.reason)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            if let diff = plan.instructionsDiff, !diff.isEmpty {
                Text("Änderung an AGENTS.md").font(.headline)
                UnifiedDiffView(diff: diff).frame(minHeight: 120, maxHeight: 260)
            }
            if !plan.isApplicable {
                Text("Diese Vorschau kann nicht angewendet werden. Bitte Kollisionen beheben und neu berechnen.")
                    .foregroundStyle(.red)
            }
            HStack {
                CommandButton(String(localized: "Migration anwenden"), systemImage: "checkmark",
                              confirmation: String(localized: "Dateien werden verschoben und die Einstellungen gespeichert. Prüfen Sie vorher den Git-Status.")) {
                    .applyFolderMigration(planId: plan.planId)
                } onResult: { outcome in
                    if outcome.succeeded { onFinish() }
                }
                .disabled(!plan.isApplicable)
                CommandButton(String(localized: "Vorschau verwerfen"), systemImage: "xmark") {
                    .discardFolderMigration(planId: plan.planId)
                } onResult: { _ in onFinish() }
            }
        }
    }
}

/// Vorschläge für AGENTS.md/CLAUDE.md mit Diff; geschrieben wird nur nach Zustimmung (G).
struct InstructionProposalsSection: View {
    @Environment(CommandCenter.self) private var commands
    let projectId: ProjectID
    @State private var proposals: [InstructionProposalInfo]?
    @State private var createClaudeFile = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("CLAUDE.md anlegen, falls sie fehlt", isOn: $createClaudeFile)
                Spacer()
                CommandButton(String(localized: "Vorschlag neu berechnen"), systemImage: "arrow.clockwise") {
                    .proposeInstructions(projectId: projectId, createClaudeFileIfMissing: createClaudeFile)
                } onResult: { apply($0) }
            }
            if let proposals {
                if proposals.isEmpty {
                    Text("Keine offenen Vorschläge. Die Anweisungsdateien entsprechen der Konfiguration.")
                        .foregroundStyle(.secondary)
                }
                ForEach(proposals) { proposal in
                    ProposalView(proposal: proposal) { Task { await load() } }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task { await load() }
    }

    private func load() async {
        apply(await commands.perform(String(localized: "Vorschläge laden"), .instructionProposals(projectId: projectId), quiet: true))
    }

    private func apply(_ outcome: CommandOutcome) {
        if case let .instructionProposals(list)? = outcome.result {
            proposals = list.filter { $0.projectId == projectId }
        } else if proposals == nil {
            proposals = []
        }
    }
}

private struct ProposalView: View {
    let proposal: InstructionProposalInfo
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Vorschlag vom \(proposal.createdAt.shortDateTime)").font(.headline)
            ForEach(proposal.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            ForEach(proposal.changes, id: \.path) { change in
                DisclosureGroup {
                    UnifiedDiffView(diff: change.unifiedDiff).frame(minHeight: 120, maxHeight: 320)
                } label: {
                    HStack {
                        Text(verbatim: change.path).font(.system(.body, design: .monospaced))
                        Badge(text: change.isNewFile ? String(localized: "neu") : String(localized: "geändert"))
                    }
                }
            }
            HStack {
                CommandButton(String(localized: "Übernehmen"), systemImage: "checkmark",
                              confirmation: String(localized: "Die Dateien werden atomar geschrieben; benutzerdefinierte Abschnitte bleiben erhalten.")) {
                    .applyInstructionProposal(proposalId: proposal.id)
                } onResult: { _ in onChange() }
                CommandButton(String(localized: "Ablehnen"), systemImage: "xmark") {
                    .rejectInstructionProposal(proposalId: proposal.id)
                } onResult: { _ in onChange() }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// GitHub-Anbindung über `gh` (M3, ADR-0016).
private struct GitHubSection: View {
    @Environment(LibraryStore.self) private var library
    let projectId: ProjectID
    @State private var availability: GitHubAvailabilityInfo?
    @State private var issues: [GitHubIssueInfo]?
    @State private var issueState: GitHubIssueStateFilter = .open
    @State private var projectState: GitHubProjectStateInfo?
    @Environment(CommandCenter.self) private var commands

    private func loadState() async {
        let outcome = await commands.perform(String(localized: "GitHub-Zustand laden"), .gitHubProjectState(projectId: projectId), quiet: true)
        if case let .gitHubProjectState(state)? = outcome.result { projectState = state }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CommandButton(String(localized: "Verfügbarkeit prüfen"), systemImage: "checkmark.shield") { .gitHubAvailability } onResult: { outcome in
                    if case let .gitHubAvailability(info)? = outcome.result { availability = info }
                }
                if let availability {
                    Label(availability.detail, systemImage: availability.isAvailable ? "checkmark.circle" : "xmark.circle")
                        .foregroundStyle(availability.isAvailable ? Color.green : Color.orange)
                        .lineLimit(2)
                }
            }
            if let projectState {
                InfoRow("GitHub für dieses Projekt", projectState.enabled ? String(localized: "aktiv") : String(localized: "nicht aktiv"))
                if let repository = projectState.repository { InfoRow("Repository", repository) }
                if let detail = projectState.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            HStack {
                if projectState?.enabled == true {
                    CommandButton(String(localized: "GitHub deaktivieren"), systemImage: "link.badge.plus") {
                        .setGitHubEnabled(projectId: projectId, enabled: false)
                    } onResult: { _ in Task { await loadState() } }
                    CommandButton(String(localized: "Jetzt abgleichen"), systemImage: "arrow.triangle.2.circlepath") { .syncGitHub(projectId: projectId) }
                } else if projectState != nil {
                    CommandButton(String(localized: "GitHub aktivieren"), systemImage: "link") {
                        .setGitHubEnabled(projectId: projectId, enabled: true)
                    } onResult: { _ in Task { await loadState() } }
                }
            }
            HStack {
                Picker("Issues", selection: $issueState) {
                    Text("Offen").tag(GitHubIssueStateFilter.open)
                    Text("Geschlossen").tag(GitHubIssueStateFilter.closed)
                    Text("Alle").tag(GitHubIssueStateFilter.all)
                }
                .fixedSize()
                CommandButton(String(localized: "Issues laden"), systemImage: "tray.and.arrow.down") {
                    .gitHubIssues(projectId: projectId, state: issueState)
                } onResult: { outcome in
                    if case let .gitHubIssues(list)? = outcome.result { issues = list }
                }
            }
            if let issues {
                if issues.isEmpty { Text("Keine Issues.").foregroundStyle(.secondary) }
                ForEach(issues, id: \.number) { issue in
                    HStack {
                        Text(verbatim: "#\(issue.number)").monospacedDigit()
                        Text(issue.title).lineLimit(1)
                        Spacer()
                        if let linked = issue.linkedWorkItemId {
                            Text("verknüpft mit \(library.snapshot.workItem(linked)?.displayID ?? linked.shortString)")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            CommandButton(String(localized: "Importieren"), systemImage: "square.and.arrow.down") {
                                .importGitHubIssue(projectId: projectId, issueNumber: issue.number)
                            }
                        }
                    }
                }
            }
        }
        .task(id: projectId) { await loadState() }
    }
}

/// Vom iPhone (oder Mac) beauftragte Projekteinrichtungen mit Zustand (E2).
private struct SetupCommandsSection: View {
    let commands: [ProjectSetupCommand]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(commands.sorted { $0.createdAt > $1.createdAt }) { command in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(command.kind.displayName).font(.headline)
                        Badge(text: command.state.displayName,
                              color: command.state == .failed ? .red : command.state == .completed ? .green : .blue)
                        Spacer()
                        Text(command.createdAt.shortDateTime).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(command.projectName)
                    if let failure = command.failure {
                        Text(failure.message).foregroundStyle(.red)
                    }
                    if let path = command.resultPath {
                        Text(verbatim: path).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
