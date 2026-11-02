import AppKit
import SwiftUI
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC

/// Menüleisten-Symbol: Logo, solange nichts Aufmerksamkeit braucht; sonst ein Zustandssymbol (D1). Offene Freigaben
/// und fehlgeschlagene Jobs stehen zusätzlich als Zahl neben dem Symbol.
struct MenuBarLabel: View {
    @Environment(ServiceMonitor.self) private var monitor

    var body: some View {
        HStack(spacing: 3) {
            icon
            if attentionCount > 0 {
                Text(attentionCount, format: .number)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var icon: Image {
        if let summary = monitor.currentSummary {
            if summary.queue.openApprovals > 0 || summary.queue.failed > 0 {
                return Image(systemName: "exclamationmark.circle")
            }
            if summary.macState == .degraded {
                return Image(systemName: "exclamationmark.triangle")
            }
        }
        return monitor.state.menuBarImage
    }

    private var attentionCount: Int {
        guard let queue = monitor.currentSummary?.queue else { return 0 }
        return queue.openApprovals + queue.failed
    }

    private var accessibilityText: Text {
        let state = MacStatePresentation.make(reachable: monitor.isReachable, summary: monitor.currentSummary).title
        if attentionCount > 0 {
            return Text("Software Regisseur – \(state), \(attentionCount) brauchen Aufmerksamkeit")
        }
        return Text("Software Regisseur – \(state)")
    }
}

/// Inhalt des Menüleisten-Fensters (Pflichtenheft D1). Zeigt nur geprüfte Werte des Dienstes.
struct MenuBarContentView: View {
    @Environment(ServiceMonitor.self) private var monitor
    @Environment(LibraryStore.self) private var library
    @Environment(NavigationModel.self) private var navigation
    @Environment(WindowState.self) private var windowState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let summary = monitor.currentSummary {
                agentSection(summary)
                queueSection(summary)
                if !summary.problems.isEmpty {
                    problemsSection(summary.problems)
                }
            } else {
                MenuCard {
                    ServiceStatusRow()
                    ServiceControls()
                }
            }
            QuickActionsGrid(open: open)
            FeedbackBanner()
                .padding(.horizontal, -12)
            footer
        }
        .padding(12)
        .frame(width: 380)
        .buttonStyle(.borderless)
    }

    // MARK: Kopf mit Mac- und iCloud-Status

    private var header: some View {
        let state = MacStatePresentation.make(reachable: monitor.isReachable, summary: monitor.currentSummary)
        return MenuCard {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 34, height: 34)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Software Regisseur")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    if let summary = monitor.currentSummary {
                        Text("Dienst \(summary.serviceVersion.shortVersion) auf \(summary.hostName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                StatusPill(title: state.title, level: state.level, symbolName: state.symbolName)
            }
            if let detail = state.detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let summary = monitor.currentSummary {
                Divider()
                syncRow(summary)
            }
        }
    }

    private func syncRow(_ summary: ServiceStatusSummary) -> some View {
        let sync = SyncPresentation.make(summary.sync, now: .now)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "icloud")
                .foregroundStyle(sync.level.color)
                .symbolEffect(.breathe, isActive: summary.sync.state == .syncing)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(sync.title)
                if let detail = sync.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Agenten und laufende Jobs

    private func agentSection(_ summary: ServiceStatusSummary) -> some View {
        MenuCard("Agenten") {
            if summary.agents.isEmpty {
                Text("Noch keine Agenten erkannt.")
                    .foregroundStyle(.secondary)
            }
            ForEach(summary.agents.map(AgentPresentation.make)) { agent in
                Button {
                    navigation.showQueue(filter: .active, provider: agent.providerId)
                    open(nil)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "cpu")
                            .foregroundStyle(agent.level.color)
                            .symbolEffect(.pulse, isActive: agent.activeJobs > 0)
                            .frame(width: 18)
                            .accessibilityHidden(true)
                        Text(agent.name)
                        Spacer(minLength: 8)
                        Text(agent.stateText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        RowChevron()
                    }
                }
                .buttonStyle(MenuRowButtonStyle())
                .accessibilityHint(Text("Zeigt die aktiven Jobs dieses Agenten"))
            }
            ForEach(activeJobs.prefix(5)) { job in
                let title = library.snapshot.workItem(job.workItemId)?.displayTitle ?? job.jobId.shortString
                Button {
                    navigation.showJob(job.jobId, filter: .active)
                    open(nil)
                } label: {
                    HStack(spacing: 8) {
                        JobStateIcon(state: job.state)
                            .frame(width: 18)
                        Text(title)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Badge(text: job.state.germanDisplayName, color: job.state.level.color)
                    }
                }
                .buttonStyle(MenuRowButtonStyle())
                .padding(.leading, 14)
                .help(Text(verbatim: title))
            }
        }
    }

    private var activeJobs: [AgentJob] {
        QueueFilter.active.apply(to: library.snapshot.jobs)
    }

    // MARK: Warteschlange als Kennzahlen

    private func queueSection(_ summary: ServiceStatusSummary) -> some View {
        let queue = summary.queue
        let next = QueuePresentation.make(queue, now: .now).nextStartText
        return MenuCard("Warteschlange") {
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    QueueTile(count: queue.waiting, title: "Wartend", symbolName: "tray") {
                        navigation.showQueue(filter: .waiting)
                        open(nil)
                    }
                    QueueTile(count: queue.scheduled, title: "Geplant", symbolName: "calendar") {
                        navigation.showQueue(filter: .waiting)
                        open(nil)
                    }
                    QueueTile(count: queue.openApprovals, title: "Freigaben", symbolName: "hand.raised", tint: .orange) {
                        navigation.showQueue(filter: .active)
                        open(nil)
                    }
                }
                GridRow {
                    QueueTile(count: queue.blocked, title: "Blockiert", symbolName: "nosign", tint: .orange) {
                        navigation.showQueue(filter: .problems)
                        open(nil)
                    }
                    QueueTile(count: queue.failed, title: "Fehlgeschlagen", symbolName: "exclamationmark.triangle", tint: .red) {
                        navigation.showQueue(filter: .problems)
                        open(nil)
                    }
                    QueueTile(count: queue.reviewsPending, title: "Zur Review", symbolName: "eye", tint: .blue) {
                        navigation.show(.review)
                        open(nil)
                    }
                }
            }
            if let next {
                Label(next, systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func problemsSection(_ problems: [String]) -> some View {
        MenuCard("Hinweise", tint: .orange) {
            ForEach(problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Fußzeile

    /// „Fenster schließen“, „App beenden“ und „Dienst stoppen“ sind bewusst getrennt (Pflichtenheft C5, D). Die
    /// Erklärung der Wirkung steht im Tooltip und im VoiceOver-Hinweis, damit das Fenster kompakt bleibt.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    open(nil)
                } label: {
                    Label("Hauptfenster öffnen", systemImage: "macwindow")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassPillButtonStyle())
                .keyboardShortcut("0", modifiers: .command)
                // Sparkle-Updates (ADR-0017), siehe SoftwareUpdater.swift.
                MenuBarUpdateButton()
            }
            HStack(spacing: 14) {
                if windowState.isMainWindowOpen {
                    Button("Fenster schließen") { dismissWindow(id: WindowID.main) }
                        .help(Text("Schließt das Hauptfenster. Menüleiste und Hintergrunddienst bleiben aktiv."))
                }
                Button("App beenden") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
                    .help(Text("Beendet Menüleiste und Fenster. Der Hintergrunddienst läuft weiter."))
                    .accessibilityHint(Text("Beendet Menüleiste und Fenster. Der Hintergrunddienst läuft weiter."))
                Spacer()
                if monitor.state.isReachable {
                    Button("Dienst stoppen", role: .destructive) { Task { await monitor.stop() } }
                        .foregroundStyle(.red)
                        .disabled(monitor.isBusy)
                        .help(Text("Beendet den Hintergrunddienst. Die App bleibt in der Menüleiste."))
                        .accessibilityHint(Text("Beendet den Hintergrunddienst. Die App bleibt in der Menüleiste."))
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
    }

    private func open(_ section: MacSection?) {
        if let section { navigation.show(section) }
        openWindow(id: WindowID.main)
        NSApplication.shared.activate()
    }
}

/// Schnellaktionen (D1) als Kacheln. Jede Kachel löst eine echte Aktion aus; „Notiz“ öffnet ein kurzes Formular
/// und legt die Notiz über den Dienst in der Inbox an (IPC-Protokoll 3).
struct QuickActionsGrid: View {
    @Environment(ServiceMonitor.self) private var monitor
    @Environment(CommandCenter.self) private var commands
    let open: (MacSection?) -> Void
    @State private var showNote = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MenuSectionTitle("Schnellaktionen")
            GlassEffectContainer(spacing: 6) {
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow {
                        QuickActionTile("Notiz", fullTitle: "Neue Notiz", systemImage: "square.and.pencil",
                                        isSelected: showNote) {
                            withAnimation(.snappy) { showNote.toggle() }
                        }
                        .disabled(monitor.isReachable != true)
                        .help(monitor.isReachable == true ? Text("Notiz in der Inbox erfassen") : Text("Der Hintergrunddienst ist nicht erreichbar."))
                        QuickActionTile("Projekte", fullTitle: "Projektübersicht", systemImage: "folder") { open(.projects) }
                        QuickActionTile("Warteschlange", fullTitle: "Aufgabenqueue", systemImage: "clock") { open(.queue) }
                        QuickActionTile("Agenten", fullTitle: "Agentenübersicht", systemImage: "cpu") { open(.agents) }
                    }
                    GridRow {
                        QuickActionTile("Sync", fullTitle: "Jetzt synchronisieren", systemImage: "arrow.triangle.2.circlepath") {
                            _ = await commands.perform(String(localized: "Jetzt synchronisieren"), .syncNow)
                        }
                        QuickActionTile("Scanner", fullTitle: "Scanner aktualisieren", systemImage: "magnifyingglass") {
                            _ = await commands.perform(String(localized: "Scanner aktualisieren"), .refreshScanner)
                        }
                        QuickActionTile("Einstellungen", fullTitle: "Einstellungen", systemImage: "gearshape") { open(.settings) }
                            .keyboardShortcut(",", modifiers: .command)
                        pauseResume
                    }
                }
            }
            if showNote {
                MenuCard {
                    QuickNoteForm { withAnimation(.snappy) { showNote = false } }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private var pauseResume: some View {
        switch monitor.state.runState {
        case .paused?:
            QuickActionTile("Fortsetzen", fullTitle: "Dienst fortsetzen", systemImage: "play.circle", isSelected: true) {
                await monitor.resume()
            }
            .disabled(monitor.isBusy)
        case .running?:
            QuickActionTile("Pausieren", fullTitle: "Dienst pausieren", systemImage: "pause.circle") { await monitor.pause() }
                .disabled(monitor.isBusy)
        case nil:
            QuickActionTile("Prüfen", fullTitle: "Dienst prüfen", systemImage: "arrow.clockwise") { await monitor.start() }
                .disabled(monitor.isBusy)
        }
    }
}

// MARK: - Bausteine des Menüleisten-Fensters

/// Abgerundeter Abschnitt statt Trennlinien; `tint` färbt Hinweis-Abschnitte ein.
private struct MenuCard<Content: View>: View {
    var title: LocalizedStringKey?
    var tint: Color?
    @ViewBuilder var content: Content

    init(_ title: LocalizedStringKey? = nil, tint: Color? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                MenuSectionTitle(title)
            }
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.map { $0.opacity(0.12) } ?? Color.primary.opacity(0.05), in: .rect(cornerRadius: 12))
    }
}

private struct MenuSectionTitle: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Mac-Zustand als farbige Plakette im Kopf.
private struct StatusPill: View {
    let title: String
    let level: StatusLevel
    let symbolName: String

    var body: some View {
        Label(title, systemImage: symbolName)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .foregroundStyle(level.color)
            .background(level.color.opacity(0.15), in: Capsule())
            .contentTransition(.symbolEffect(.replace))
            .accessibilityElement(children: .combine)
    }
}

/// Hervorhebung beim Überfahren wie in nativen Menüs; zeigt, dass die Zeile anklickbar ist.
private struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuRow(configuration: configuration)
    }

    private struct MenuRow: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect(cornerRadius: 7))
                .background(highlight, in: .rect(cornerRadius: 7))
                .padding(.horizontal, -6)
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovered)
        }

        private var highlight: Color {
            guard isEnabled else { return .clear }
            if configuration.isPressed { return .primary.opacity(0.14) }
            return isHovered ? .primary.opacity(0.08) : .clear
        }
    }
}

private struct RowChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

/// Zustandssymbol eines Jobs; laufende Jobs animieren.
private struct JobStateIcon: View {
    let state: AgentJobState

    var body: some View {
        Image(systemName: symbolName)
            .foregroundStyle(state.level.color)
            .symbolEffect(.variableColor.iterative, isActive: state == .running)
            .accessibilityHidden(true)
    }

    private var symbolName: String {
        switch state {
        case .running: "waveform"
        case .waitingApproval: "hand.raised.fill"
        case .waitingQuota: "hourglass"
        case .paused: "pause.circle.fill"
        case .needsConfiguration: "wrench.and.screwdriver"
        case .failed: "exclamationmark.triangle.fill"
        case .finished: "checkmark.circle.fill"
        case .cancelled: "xmark.circle"
        case .requested, .pendingMac, .scheduled, .admitted, .starting: "clock"
        }
    }
}

/// Kennzahl der Warteschlange. Farbig nur, wenn der Wert größer als 0 ist; Farbe ergänzt den Text (P).
private struct QueueTile: View {
    let count: Int
    let title: LocalizedStringKey
    let symbolName: String
    var tint: Color?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Image(systemName: symbolName)
                    .font(.caption)
                    .foregroundStyle(highlighted ? tint ?? .secondary : .secondary)
                    .symbolEffect(.bounce, value: count)
                    .accessibilityHidden(true)
                Text(count, format: .number)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(count > 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .contentTransition(.numericText(value: Double(count)))
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: .rect(cornerRadius: 9))
            .contentShape(.rect(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.snappy, value: count)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityElement(children: .combine)
    }

    private var highlighted: Bool { tint != nil && count > 0 }

    private var background: Color {
        let base = highlighted ? (tint ?? .primary).opacity(0.14) : Color.primary.opacity(0.05)
        return isHovered ? base.opacity(2) : base
    }
}

/// Kachel der Schnellaktionen mit Liquid Glass. Asynchrone Aktionen zeigen bis zum Ende einen Fortschritt.
private struct QuickActionTile: View {
    let title: LocalizedStringKey
    let fullTitle: LocalizedStringKey
    let systemImage: String
    var isSelected = false
    let action: @MainActor () async -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isRunning = false
    @State private var taps = 0

    init(_ title: LocalizedStringKey, fullTitle: LocalizedStringKey, systemImage: String, isSelected: Bool = false,
         action: @escaping @MainActor () async -> Void) {
        self.title = title
        self.fullTitle = fullTitle
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button {
            taps += 1
            isRunning = true
            Task {
                await action()
                isRunning = false
            }
        } label: {
            VStack(spacing: 4) {
                Group {
                    if isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: systemImage)
                            .font(.title3)
                            .symbolEffect(.bounce, value: taps)
                    }
                }
                .frame(height: 22)
                .accessibilityHidden(true)
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        .opacity(isEnabled ? 1 : 0.45)
        .glassEffect(isSelected ? .regular.tint(.accentColor.opacity(0.25)).interactive() : .regular.interactive(),
                     in: .rect(cornerRadius: 12))
        .disabled(isRunning)
        .help(Text(fullTitle))
        .accessibilityLabel(Text(fullTitle))
    }
}

/// Kapsel mit Liquid Glass für die Fußzeile, passend zu den Kacheln der Schnellaktionen.
private struct GlassPillButtonStyle: ButtonStyle {
    var isProminent = false

    func makeBody(configuration: Configuration) -> some View {
        GlassPill(configuration: configuration, isProminent: isProminent)
    }

    private struct GlassPill: View {
        let configuration: ButtonStyleConfiguration
        let isProminent: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .padding(.horizontal, 12)
                .frame(minHeight: 30)
                .foregroundStyle(isProminent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .contentShape(.capsule)
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
                .glassEffect(isProminent ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .capsule)
        }
    }
}

/// Kompakte Update-Schaltfläche der Menüleiste. Der Grund, warum Updates abgeschaltet sind, steht im Tooltip;
/// die ausführliche Variante mit sichtbarem Grund ist `CheckForUpdatesButton` in den Einstellungen.
private struct MenuBarUpdateButton: View {
    @Environment(SoftwareUpdater.self) private var updater

    var body: some View {
        if let version = updater.pendingUpdateVersion {
            Button {
                updater.checkForUpdates()
            } label: {
                Label("Update \(version)", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(GlassPillButtonStyle(isProminent: true))
            .help(Text("Update auf Version \(version) ansehen …"))
        } else {
            Button {
                updater.checkForUpdates()
            } label: {
                Image(systemName: "arrow.down.circle")
                    .accessibilityLabel(Text("Nach Updates suchen …"))
            }
            .buttonStyle(GlassPillButtonStyle())
            .disabled(!updater.isEnabled || !updater.canCheckForUpdates)
            .help(helpText)
        }
    }

    private var helpText: Text {
        if case .disabled(let reason) = updater.availability {
            return Text(verbatim: reason)
        }
        return Text("Nach Updates suchen …")
    }
}
