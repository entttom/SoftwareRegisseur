import AppKit
import SwiftUI
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC

/// Einrichtungsassistent im Hauptfenster: links der Fortschritt, rechts der aktuelle Schritt, unten die Aktionen.
/// Ablauf und Regeln (Q4, App Review 5.1.1(iv)) stehen in `SetupAssistant`.
struct SetupAssistantView: View {
    @Environment(SetupAssistant.self) private var setup
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            SetupSidebar()
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    page
                        .frame(maxWidth: 640, alignment: .leading)
                        .padding(.horizontal, 40)
                        .padding(.vertical, 36)
                        .frame(maxWidth: .infinity)
                        .id(setup.step)
                        .transition(transition)
                }
                .scrollBounceBehavior(.basedOnSize)
                .clipped()
                Divider()
                SetupFooter()
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
        }
        .frame(minHeight: 520)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .smooth(duration: 0.35), value: setup.step)
    }

    @ViewBuilder
    private var page: some View {
        switch setup.step {
        case .welcome: WelcomeStepView()
        case .backgroundService: ServiceStepView()
        case .rootFolders: RootFoldersStepView()
        case .agents: AgentsStepView()
        case .connections: ConnectionsStepView()
        case .summary: SummaryStepView()
        }
    }

    private var transition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(insertion: .push(from: setup.movedForward ? .trailing : .leading), removal: .opacity)
    }
}

extension SetupAssistant.Step {
    var title: String {
        switch self {
        case .welcome: String(localized: "Willkommen")
        case .backgroundService: String(localized: "Hintergrunddienst")
        case .rootFolders: String(localized: "Git-Stammordner")
        case .agents: String(localized: "Coding-Agenten")
        case .connections: String(localized: "Verbindungen")
        case .summary: String(localized: "Fertig")
        }
    }

    var subtitle: String {
        switch self {
        case .welcome: String(localized: "Was Software Regisseur für Sie erledigt")
        case .backgroundService: String(localized: "Start bei der Anmeldung")
        case .rootFolders: String(localized: "Wo Ihre Repositories liegen")
        case .agents: String(localized: "Codex, Claude Code, Modell und Stufe")
        case .connections: String(localized: "iCloud, GitHub und KI-Schlüssel")
        case .summary: String(localized: "Überblick und los geht’s")
        }
    }

    var symbolName: String {
        switch self {
        case .welcome: "sparkles"
        case .backgroundService: "gearshape.2"
        case .rootFolders: "folder.badge.gearshape"
        case .agents: "cpu"
        case .connections: "icloud"
        case .summary: "checkmark.seal"
        }
    }
}

// MARK: - Rahmen

private struct SetupSidebar: View {
    @Environment(SetupAssistant.self) private var setup

    var body: some View {
        let steps = SetupAssistant.Step.allCases
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Software Regisseur").font(.headline)
                    Text("Einrichtung").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 28)
            ForEach(Array(steps.enumerated()), id: \.element) { index, step in
                SetupStepRow(step: step, number: index + 1, total: steps.count, state: setup.state(of: step),
                             isLast: index == steps.count - 1)
            }
            Spacer(minLength: 20)
            Label("Alles lässt sich später in den Einstellungen ändern.", systemImage: "gearshape")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 240, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.background.secondary)
    }
}

/// Ein Schritt in der Seitenleiste; reine Anzeige (nicht fokussierbar), VoiceOver liest „Schritt n von m“.
private struct SetupStepRow: View {
    let step: SetupAssistant.Step
    let number: Int
    let total: Int
    let state: SetupAssistant.StepState
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                indicator
                if !isLast {
                    Capsule()
                        .fill(state == .done ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: 2)
                        .frame(minHeight: 14, maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.callout.weight(state == .current ? .semibold : .regular))
                    .foregroundStyle(state == .upcoming ? .secondary : .primary)
                if state == .current {
                    Text(step.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 3)
            .padding(.bottom, isLast ? 0 : 14)
        }
        // Gleich hohe Spalten: die Verbindungslinie reicht bis zum nächsten Schritt.
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Schritt \(number) von \(total): \(step.title)"))
        .accessibilityValue(Text(stateText))
    }

    private var stateText: String {
        switch state {
        case .done: String(localized: "erledigt")
        case .current: String(localized: "aktueller Schritt")
        case .upcoming: String(localized: "ausstehend")
        }
    }

    private var indicator: some View {
        ZStack {
            switch state {
            case .done:
                Circle().fill(Color.accentColor)
                Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
            case .current:
                Circle().fill(Color.accentColor)
                Text(verbatim: "\(number)").font(.caption.bold()).foregroundStyle(.white)
            case .upcoming:
                Circle().strokeBorder(Color.secondary.opacity(0.45), lineWidth: 1.5)
                Text(verbatim: "\(number)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 24, height: 24)
    }
}

/// Aktionen unten rechts. Auf dem Dienstschritt nur die Aktionen des Dienstablaufs (kein Zurück, kein Überspringen).
private struct SetupFooter: View {
    @Environment(SetupAssistant.self) private var setup
    @Environment(ServiceMonitor.self) private var monitor
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        HStack(spacing: 10) {
            if setup.step == .backgroundService {
                BackgroundServiceActions(large: true)
            } else {
                if setup.canGoBack {
                    Button {
                        setup.goBack()
                    } label: {
                        Label("Zurück", systemImage: "chevron.left")
                    }
                }
                Spacer()
                if setup.canSkip, !isStepSatisfied {
                    Button("Später festlegen") { setup.skip() }
                }
                Button(primaryTitle) {
                    if setup.step == .summary { navigation.show(.dashboard) }
                    setup.advance()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var primaryTitle: String {
        setup.step == .summary ? String(localized: "Los geht’s") : String(localized: "Weiter")
    }

    /// Ohne Stammordner bzw. einsatzbereiten Agenten wird zusätzlich „Später festlegen“ angeboten.
    private var isStepSatisfied: Bool {
        let summary = monitor.currentSummary
        switch setup.step {
        case .rootFolders: return !(summary?.workspace.rootFolders.isEmpty ?? true)
        case .agents: return summary?.agents.contains(where: \.ready) ?? false
        default: return true
        }
    }
}

// MARK: - Bausteine

private struct SetupStepHeader: View {
    let symbolName: String
    var tint: Color = .accentColor
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: symbolName)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: tint.opacity(0.3), radius: 8, y: 4)
                .accessibilityHidden(true)
            Text(title)
                .font(.largeTitle.bold())
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SetupCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

private extension String {
    /// `/Users/name/Developer` → `~/Developer`.
    var abbreviatingHome: String { (self as NSString).abbreviatingWithTildeInPath }
}

// MARK: - 1 Willkommen

private struct WelcomeStepView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .center, spacing: 18) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 88, height: 88)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Willkommen bei Software Regisseur")
                        .font(.largeTitle.bold())
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("Ideen auf iPhone oder Mac erfassen, von Coding-Agenten umsetzen lassen und jedes Ergebnis prüfen, bevor es in Ihr Repository kommt.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(alignment: .top, spacing: 12) { features }
                // Gleich hohe Kacheln.
                .fixedSize(horizontal: false, vertical: true)
            SetupCard {
                Text("In wenigen Schritten eingerichtet").font(.headline)
                ForEach(SetupAssistant.Step.allCases.dropFirst()) { step in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(step.title)
                            Text(step.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: step.symbolName).foregroundStyle(.tint)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var features: some View {
        FeatureTile(symbolName: "square.and.pencil", tint: .orange, title: String(localized: "Erfassen"),
                    text: String(localized: "Aufgaben und Ideen per Text oder Diktat – auf jedem Ihrer Geräte."))
        FeatureTile(symbolName: "cpu", tint: .purple, title: String(localized: "Ausführen"),
                    text: String(localized: "Codex oder Claude Code arbeiten geplant in eigenen Worktrees."))
        FeatureTile(symbolName: "checkmark.shield", tint: .green, title: String(localized: "Prüfen"),
                    text: String(localized: "Änderungen ansehen und Freigaben erteilen – auch unterwegs am iPhone."))
    }
}

private struct FeatureTile: View {
    let symbolName: String
    let tint: Color
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbolName)
                .font(.title2)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 2 Hintergrunddienst

private struct ServiceStepView: View {
    @Environment(SetupAssistant.self) private var setup

    var body: some View {
        let step = setup.service.step
        VStack(alignment: .leading, spacing: 24) {
            SetupStepHeader(symbolName: step.symbolName, tint: step.tint, title: step.title, subtitle: subtitle(step))
            SetupCard { BackgroundServiceOnboardingText(step: step) }
        }
    }

    private func subtitle(_ step: BackgroundServiceOnboarding.Step) -> String {
        switch step {
        case .explanation, .registering, .finished:
            String(localized: "Damit Agenten auch bei geschlossenem Fenster planmäßig arbeiten.")
        case .requiresApproval:
            String(localized: "Ein Schritt fehlt noch: die Freigabe durch macOS.")
        case .failed:
            String(localized: "Die Registrierung hat nicht geklappt.")
        }
    }
}

// MARK: - 3 Stammordner

private struct RootFoldersStepView: View {
    @Environment(CommandCenter.self) private var commands
    @Environment(ServiceMonitor.self) private var monitor
    @State private var state: RootFolderState?
    @State private var loadError: String?
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SetupStepHeader(
                symbolName: "folder.badge.gearshape", tint: .blue,
                title: String(localized: "Wo liegen Ihre Git-Projekte?"),
                subtitle: String(localized: "Wählen Sie einen oder mehrere Stammordner. Der Hintergrunddienst durchsucht deren Unterordner nach Git-Repositories und zeigt sie als Projekte an – verschoben oder verändert wird dabei nichts."))
            if monitor.isReachable == false {
                UnavailableNotice(text: String(localized: "Der Hintergrunddienst ist nicht erreichbar. Stammordner können Sie später unter „Projekte“ festlegen."))
            }
            dropZone
            if let suggestion, monitor.isReachable != false {
                Button {
                    add([suggestion])
                } label: {
                    Label("Vorschlag übernehmen: \(suggestion.abbreviatingHome)", systemImage: "lightbulb")
                }
                .buttonStyle(.link)
            }
            if let folders = state?.folders, !folders.isEmpty {
                SetupCard {
                    Text("Stammordner").font(.headline)
                    ForEach(folders, id: \.path) { folder in
                        folderRow(folder)
                    }
                    scanStatus
                }
            }
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: monitor.isReachable) { await load() }
    }

    private var suggestion: String? {
        guard let state, let suggestion = state.suggestion, !state.folders.contains(where: { $0.path == suggestion }) else { return nil }
        return suggestion
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Ordner hierher ziehen").font(.headline)
            Text("oder").font(.callout).foregroundStyle(.secondary)
            Button("Ordner auswählen …") { chooseFolders() }
                .controlSize(.large)
                .disabled(monitor.isReachable == false)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(isDropTargeted ? Color.accentColor.opacity(0.1) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                          style: StrokeStyle(lineWidth: 2, dash: [7, 5])))
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter(\.hasDirectoryPath).map { $0.path(percentEncoded: false) }
            guard !folders.isEmpty, monitor.isReachable != false else { return false }
            add(folders)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    private func folderRow(_ folder: RootFolderState.Folder) -> some View {
        HStack(spacing: 10) {
            Image(systemName: folder.exists ? "folder.fill" : "folder.badge.questionmark")
                .foregroundStyle(folder.exists ? Color.blue : Color.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: folder.path.abbreviatingHome)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(folder.path)
                if !folder.exists {
                    Text("Ordner fehlt").font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            Button {
                remove(folder.path)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(Text("Nicht mehr durchsuchen; Projekte und Aufgaben bleiben erhalten"))
            .accessibilityLabel(Text("\(folder.path.abbreviatingHome) entfernen"))
        }
    }

    @ViewBuilder
    private var scanStatus: some View {
        if let workspace = monitor.currentSummary?.workspace {
            Divider()
            HStack(spacing: 8) {
                if workspace.isScanning {
                    ProgressView().controlSize(.small)
                    Text("Ordner werden durchsucht …")
                } else {
                    Image(systemName: workspace.projectsReady > 0 ? "checkmark.circle.fill" : "magnifyingglass")
                        .foregroundStyle(workspace.projectsReady > 0 ? Color.green : Color.secondary)
                        .accessibilityHidden(true)
                    Text("Gefundene Projekte: \(workspace.projectsReady)")
                }
                Spacer()
                CommandButton(String(localized: "Erneut durchsuchen"), systemImage: "arrow.clockwise") { .refreshScanner }
                    .buttonStyle(.borderless)
                    .disabled(workspace.isScanning)
            }
            .font(.callout)
            if let error = workspace.lastScanError {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func load() async {
        guard monitor.isReachable != false else { return }
        let outcome = await commands.perform(String(localized: "Stammordner laden"), .rootFolders, quiet: true)
        if !apply(outcome) { loadError = outcome.feedback.message }
    }

    @discardableResult
    private func apply(_ outcome: CommandOutcome) -> Bool {
        guard case let .rootFolders(loaded)? = outcome.result else { return false }
        state = loaded
        loadError = nil
        return true
    }

    private func add(_ paths: [String]) {
        Task {
            for path in paths {
                let outcome = await commands.perform(String(localized: "Stammordner hinzufügen"), .addRootFolder(path: path))
                if !apply(outcome) { loadError = outcome.feedback.message }
            }
        }
    }

    private func remove(_ path: String) {
        Task {
            let outcome = await commands.perform(String(localized: "Stammordner entfernen"), .removeRootFolder(path: path))
            if !apply(outcome) { loadError = outcome.feedback.message }
        }
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Als Stammordner verwenden")
        panel.message = String(localized: "Wählen Sie die Ordner, unter denen Ihre Git-Projekte liegen.")
        if let suggestion = state?.suggestion { panel.directoryURL = URL(filePath: suggestion) }
        guard panel.runModal() == .OK else { return }
        add(panel.urls.map { $0.path(percentEncoded: false) })
    }
}

// MARK: - 4 Coding-Agenten

private struct AgentsStepView: View {
    @Environment(ServiceMonitor.self) private var monitor
    @Environment(LibraryStore.self) private var library
    @Environment(CommandCenter.self) private var commands
    @State private var choices: [ProviderID: AgentModelChoice] = [:]
    /// Gewählter, noch nicht gespeicherter Standardagent (`.some(nil)` = „keiner“).
    @State private var pendingDefaultAgent: ProviderID??

    var body: some View {
        let agents = monitor.currentSummary?.agents ?? []
        VStack(alignment: .leading, spacing: 20) {
            SetupStepHeader(
                symbolName: "cpu", tint: .purple,
                title: String(localized: "Coding-Agenten"),
                subtitle: String(localized: "Software Regisseur startet Codex oder Claude Code auf diesem Mac. Installation und Anmeldung erkennt der Hintergrunddienst selbst."))
            if monitor.isReachable == false {
                UnavailableNotice(text: String(localized: "Der Hintergrunddienst ist nicht erreichbar; Agenten können erst danach erkannt werden."))
            } else if agents.isEmpty {
                SetupCard {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Agenten werden erkannt …").foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(agents, id: \.providerId) { agent in
                AgentStatusCard(agent: agent)
            }
            if monitor.isReachable != false {
                HStack {
                    Spacer()
                    CommandButton(String(localized: "Agenten neu erkennen"), systemImage: "arrow.clockwise") { .redetectAgents }
                }
            }
            if agents.contains(where: \.installed) {
                defaults(agents: agents)
            }
        }
    }

    private func defaults(agents: [AgentProviderSummary]) -> some View {
        let snapshot = library.snapshot
        let capabilities = snapshot.capabilities(hostId: monitor.currentSummary?.hostId)
        return SetupCard {
            Text("Standard für neue Aufträge").font(.headline)
            Picker("Standardagent", selection: defaultAgentBinding) {
                Text("Keiner – beim Start wählen").tag(ProviderID?.none)
                ForEach(agents.filter(\.installed), id: \.providerId) { agent in
                    Text(AgentPresentation.make(agent).name).tag(ProviderID?.some(agent.providerId))
                }
            }
            if capabilities.isEmpty {
                Text("Modell und Stufe lassen sich wählen, sobald der Dienst die Fähigkeiten eines Agenten geprüft hat.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(capabilities, id: \.providerId) { capability in
                ModelChoicePicker(title: ProviderNames.displayName(capability.providerId), capability: capability,
                                  choice: choiceBinding(capability, snapshot: snapshot))
            }
            Text("„Erben“ verwendet die Voreinstellung des Agenten. Projekte und einzelne Aufträge können eigene Werte festlegen; nicht unterstützte Kombinationen werden vor dem Start gemeldet, nie still ersetzt.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var defaultAgentBinding: Binding<ProviderID?> {
        Binding {
            pendingDefaultAgent ?? library.snapshot.globalSettings.defaultAgentId
        } set: { provider in
            pendingDefaultAgent = .some(provider)
            var form = GlobalDefaultsForm(library.snapshot.globalSettings)
            form.defaultAgentId = provider
            Task {
                await commands.perform(String(localized: "Standardagent speichern"), .updateGlobalSettings(form.command), quiet: true)
                pendingDefaultAgent = nil
            }
        }
    }

    /// Speichert jede gültige Änderung sofort als globale Voreinstellung (ADR-0006).
    private func choiceBinding(_ capability: AgentCapability, snapshot: LibrarySnapshot) -> Binding<AgentModelChoice> {
        let provider = capability.providerId
        let stored = snapshot.globalPreference(for: provider)
        return Binding {
            choices[provider] ?? AgentModelChoice(providerId: provider, model: stored?.model, effort: stored?.effort)
        } set: { choice in
            choices[provider] = choice
            guard ModelChoiceOptions(capability: capability).isValid(model: choice.model, effort: choice.effort) else { return }
            Task {
                let outcome = await commands.perform(String(localized: "Modell und Stufe speichern"),
                                                     .setGlobalModelPreference(choice), quiet: true)
                if outcome.succeeded, choices[provider] == choice { choices[provider] = nil }
            }
        }
    }
}

private struct AgentStatusCard: View {
    let agent: AgentProviderSummary

    var body: some View {
        let presentation = AgentPresentation.make(agent)
        SetupCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "terminal")
                    .font(.title3)
                    .foregroundStyle(presentation.level.color)
                    .frame(width: 36, height: 36)
                    .background(presentation.level.color.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(presentation.name).font(.headline)
                        if let version = agent.version { Badge(text: version) }
                    }
                    Text(presentation.stateText)
                        .foregroundStyle(presentation.level.color)
                        .fixedSize(horizontal: false, vertical: true)
                    if let hint {
                        Text(hint)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: agent.ready ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.title3)
                    .foregroundStyle(presentation.level.color)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var hint: String? {
        let name = AgentPresentation.make(agent).name
        if !agent.installed {
            return String(localized: "Installieren Sie \(name) nach der Anleitung des Anbieters und wählen Sie dann „Agenten neu erkennen“. Liegt das Programm an einem eigenen Ort, tragen Sie den Pfad in den Einstellungen unter „Agenten & GitHub“ ein.")
        }
        if !agent.authenticated {
            return String(localized: "Melden Sie sich einmal im Terminal bei \(name) an und wählen Sie dann „Agenten neu erkennen“.")
        }
        return nil
    }
}

// MARK: - 5 Verbindungen

private struct ConnectionsStepView: View {
    @Environment(ServiceMonitor.self) private var monitor
    @Environment(ProviderKeyStore.self) private var keys
    @State private var gitHub: GitHubAvailabilityInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SetupStepHeader(
                symbolName: "icloud", tint: .cyan,
                title: String(localized: "Verbindungen"),
                subtitle: String(localized: "iCloud gleicht mit iPhone und iPad ab; GitHub und KI-Schlüssel sind optional und lassen sich jederzeit nachholen."))
            SetupCard {
                Label("iCloud-Synchronisierung", systemImage: "icloud").font(.headline)
                if let sync = monitor.currentSummary?.sync {
                    let presentation = SyncPresentation.make(sync, now: .now)
                    StatusLabel(title: presentation.title, detail: presentation.detail, level: presentation.level,
                                symbolName: "circle.fill")
                } else {
                    Text("Status unbekannt – der Hintergrunddienst ist nicht erreichbar.").foregroundStyle(.secondary)
                }
                Text("Projekte, Aufgaben und Freigaben werden über iCloud mit Ihren anderen Geräten abgeglichen. Melden Sie sich auf iPhone und iPad mit demselben Apple Account an und öffnen Sie dort Software Regisseur.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SetupCard {
                Label("GitHub (optional)", systemImage: "chevron.left.forwardslash.chevron.right").font(.headline)
                Text("Issues importieren und mit Aufgaben verknüpfen – über die Anmeldung der GitHub-CLI „gh“. Software Regisseur speichert kein eigenes GitHub-Token.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    gitHubStatus
                    Spacer()
                    CommandButton(String(localized: "Verbindung prüfen"), systemImage: "checkmark.shield") { .gitHubAvailability } onResult: { outcome in
                        if case let .gitHubAvailability(info)? = outcome.result { gitHub = info }
                    }
                    .disabled(monitor.isReachable == false)
                }
            }
            SetupCard {
                Label("KI-Schlüssel (optional)", systemImage: "key").font(.headline)
                Text("Für KI-Ausarbeitung und „Mit KI besprechen“ am Mac verwenden Sie Ihren eigenen API-Schlüssel. Er bleibt im Schlüsselbund dieses Macs und wird nie synchronisiert oder protokolliert.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("Schlüssel eintragen") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(ProviderKeyStore.providers, id: \.rawValue) { provider in
                            ProviderKeyRow(provider: provider)
                        }
                    }
                    .padding(.top, 8)
                }
            }
        }
        .onAppear { keys.refresh() }
    }

    @ViewBuilder
    private var gitHubStatus: some View {
        if let gitHub {
            Label(gitHub.detail, systemImage: gitHub.isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(gitHub.isAvailable ? Color.green : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if let available = monitor.currentSummary?.workspace.gitHubAvailable {
            Label(available ? String(localized: "gh verfügbar und angemeldet") : String(localized: "gh nicht verfügbar"),
                  systemImage: available ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(available ? Color.green : Color.secondary)
        } else {
            Text("Noch nicht geprüft").foregroundStyle(.secondary)
        }
    }
}

// MARK: - 6 Zusammenfassung

private struct SummaryStepView: View {
    @Environment(ServiceMonitor.self) private var monitor
    @Environment(LibraryStore.self) private var library

    var body: some View {
        let rows = self.rows
        let essentialsReady = rows.prefix(3).allSatisfy { $0.level == .ok }
        VStack(alignment: .leading, spacing: 20) {
            SetupStepHeader(
                symbolName: essentialsReady ? "checkmark.seal.fill" : "checklist",
                tint: essentialsReady ? .green : .orange,
                title: essentialsReady ? String(localized: "Alles bereit") : String(localized: "Fast geschafft"),
                subtitle: essentialsReady
                    ? String(localized: "Software Regisseur ist eingerichtet. Erfassen Sie Ihre erste Aufgabe – am Mac oder auf dem iPhone.")
                    : String(localized: "Ein paar Punkte sind noch offen. Sie können sie jetzt erledigen oder später in den Einstellungen nachholen."))
            SetupCard {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider() }
                    SummaryRow(row: row)
                }
            }
        }
    }

    private var rows: [SummaryRow.Model] {
        let summary = monitor.currentSummary
        let workspace = summary?.workspace
        let agents = summary?.agents ?? []
        let readyAgents = agents.filter(\.ready).map { AgentPresentation.make($0).name }
        var result: [SummaryRow.Model] = []

        result.append(monitor.isReachable == true
            ? .init(symbol: "gearshape.2", title: String(localized: "Hintergrunddienst"), detail: String(localized: "läuft"), level: .ok)
            : .init(symbol: "gearshape.2", title: String(localized: "Hintergrunddienst"),
                    detail: String(localized: "nicht erreichbar – Einstellungen › Dienst"), level: .warning))

        let folders = workspace?.rootFolders ?? []
        result.append(folders.isEmpty
            ? .init(symbol: "folder", title: String(localized: "Git-Stammordner"), detail: String(localized: "keiner festgelegt"),
                    level: .warning, step: .rootFolders)
            : .init(symbol: "folder", title: String(localized: "Git-Stammordner"),
                    detail: String(localized: "\(folders.count) Ordner · \(workspace?.projectsReady ?? 0) Projekte"), level: .ok,
                    step: .rootFolders))

        result.append(readyAgents.isEmpty
            ? .init(symbol: "cpu", title: String(localized: "Coding-Agenten"), detail: String(localized: "kein Agent einsatzbereit"),
                    level: .warning, step: .agents)
            : .init(symbol: "cpu", title: String(localized: "Coding-Agenten"),
                    detail: readyAgents.formatted(.list(type: .and)), level: .ok, step: .agents))

        let defaultAgent = library.snapshot.globalSettings.defaultAgentId
        result.append(.init(symbol: "star", title: String(localized: "Standardagent"),
                            detail: defaultAgent.map(ProviderNames.displayName) ?? String(localized: "keiner – Auswahl beim Start"),
                            level: defaultAgent == nil ? .info : .ok, step: .agents))

        if let sync = summary?.sync {
            let presentation = SyncPresentation.make(sync, now: .now)
            result.append(.init(symbol: "icloud", title: String(localized: "iCloud"), detail: presentation.title,
                                level: presentation.level, step: .connections))
        } else {
            result.append(.init(symbol: "icloud", title: String(localized: "iCloud"), detail: String(localized: "Status unbekannt"),
                                level: .unknown, step: .connections))
        }

        let gitHub = workspace?.gitHubAvailable
        result.append(.init(symbol: "chevron.left.forwardslash.chevron.right", title: String(localized: "GitHub"),
                            detail: gitHub == true ? String(localized: "verbunden") : String(localized: "nicht verbunden (optional)"),
                            level: gitHub == true ? .ok : .info, step: .connections))
        return result
    }
}

private struct SummaryRow: View {
    struct Model {
        var symbol: String
        var title: String
        var detail: String
        var level: StatusLevel
        var step: SetupAssistant.Step?
    }

    @Environment(SetupAssistant.self) private var setup
    let row: Model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.symbol)
                .frame(width: 22)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                Text(row.detail)
                    .font(.callout)
                    .foregroundStyle(row.level == .warning ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Image(systemName: statusSymbol)
                .foregroundStyle(row.level.color)
                .accessibilityHidden(true)
            if let step = row.step {
                Button("Ändern") { setup.revisit(step) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("\(row.title) ändern"))
            } else {
                // Platzhalter, damit die Statussymbole bündig bleiben.
                Text("Ändern").hidden().accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusSymbol: String {
        switch row.level {
        case .ok: "checkmark.circle.fill"
        case .warning, .error: "exclamationmark.circle.fill"
        case .info: "info.circle"
        case .unknown: "questionmark.circle"
        }
    }
}

// MARK: - Menüleiste

/// Hinweis in der Menüleiste, solange der Assistent nach dem Dienstschritt nicht abgeschlossen ist.
struct SetupResumeBanner: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.title3)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Einrichtung nicht abgeschlossen").font(.headline)
                Text("Stammordner und Agenten im Fenster festlegen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Fortsetzen") {
                openWindow(id: WindowID.main)
                NSApplication.shared.activate()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding([.horizontal, .top], 12)
    }
}
