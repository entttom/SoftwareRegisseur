import AppKit
import SwiftUI
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC

/// Menüleisten-Symbol: Logo, solange nichts Aufmerksamkeit braucht; sonst ein Zustandssymbol (D1).
struct MenuBarLabel: View {
    @Environment(ServiceMonitor.self) private var monitor

    var body: some View {
        icon
            .accessibilityLabel(Text("Software Regisseur – \(accessibilityState)"))
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

    private var accessibilityState: String {
        MacStatePresentation.make(reachable: monitor.isReachable, summary: monitor.currentSummary).title
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
            Divider()
            if let summary = monitor.currentSummary {
                syncSection(summary)
                Divider()
                agentSection(summary)
                Divider()
                queueSection(summary)
                if !summary.problems.isEmpty {
                    Divider()
                    problemsSection(summary.problems)
                }
            } else {
                ServiceStatusRow()
                ServiceControls()
            }
            Divider()
            QuickActionsGrid(open: open)
            FeedbackBanner()
                .padding(.horizontal, -12)
            Divider()
            Button {
                open(nil)
            } label: {
                Label("Hauptfenster öffnen", systemImage: "macwindow")
            }
            .keyboardShortcut("0", modifiers: .command)
            // Sparkle-Updates (ADR-0017), siehe SoftwareUpdater.swift.
            CheckForUpdatesButton()
            Divider()
            quitSection
        }
        .padding(14)
        .frame(width: 370)
        .buttonStyle(.borderless)
    }

    private var header: some View {
        let state = MacStatePresentation.make(reachable: monitor.isReachable, summary: monitor.currentSummary)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Software Regisseur")
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
            StatusLabel(title: state.title, detail: state.detail, level: state.level, symbolName: state.symbolName)
                .font(.headline)
            if let summary = monitor.currentSummary {
                Text("Dienst \(summary.serviceVersion.shortVersion) auf \(summary.hostName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func syncSection(_ summary: ServiceStatusSummary) -> some View {
        let sync = SyncPresentation.make(summary.sync, now: .now)
        return StatusLabel(title: sync.title, detail: sync.detail, level: sync.level, symbolName: "icloud")
    }

    @ViewBuilder
    private func agentSection(_ summary: ServiceStatusSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Agenten").font(.headline)
            if summary.agents.isEmpty {
                Text("Noch keine Agenten erkannt.")
                    .foregroundStyle(.secondary)
            }
            ForEach(summary.agents.map(AgentPresentation.make)) { agent in
                Button {
                    navigation.showQueue(filter: .active, provider: agent.providerId)
                    open(nil)
                } label: {
                    HStack {
                        Image(systemName: "cpu").foregroundStyle(agent.level.color).accessibilityHidden(true)
                        Text(agent.name)
                        Spacer()
                        Text(agent.stateText).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .accessibilityHint(Text("Zeigt die aktiven Jobs dieses Agenten"))
            }
            ForEach(activeJobs.prefix(5)) { job in
                Button {
                    navigation.showJob(job.jobId, filter: .active)
                    open(nil)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary).accessibilityHidden(true)
                        Text(library.snapshot.workItem(job.workItemId)?.displayTitle ?? job.jobId.shortString)
                            .lineLimit(1)
                        Spacer()
                        Text(job.state.germanDisplayName).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 18)
            }
        }
    }

    private var activeJobs: [AgentJob] {
        QueueFilter.active.apply(to: library.snapshot.jobs)
    }

    @ViewBuilder
    private func queueSection(_ summary: ServiceStatusSummary) -> some View {
        let queue = QueuePresentation.make(summary.queue, now: .now)
        VStack(alignment: .leading, spacing: 4) {
            Text("Warteschlange").font(.headline)
            Button {
                navigation.showQueue(filter: .waiting)
                open(nil)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(queue.waitingText)
                    if let next = queue.nextStartText {
                        Text(next).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let approvals = queue.approvalsText {
                Button {
                    navigation.showQueue(filter: .active)
                    open(nil)
                } label: {
                    Label(approvals, systemImage: "hand.raised").foregroundStyle(.orange)
                }
            }
            if let problems = queue.problemsText {
                Button {
                    navigation.showQueue(filter: .problems)
                    open(nil)
                } label: {
                    Label(problems, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
            if let reviews = queue.reviewsText {
                Button {
                    navigation.show(.review)
                    open(nil)
                } label: {
                    Label(reviews, systemImage: "eye")
                }
            }
        }
    }

    private func problemsSection(_ problems: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Hinweise").font(.headline)
            ForEach(problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func open(_ section: MacSection?) {
        if let section { navigation.show(section) }
        openWindow(id: WindowID.main)
        NSApplication.shared.activate()
    }

    /// „Fenster schließen“, „App beenden“ und „Dienst stoppen“ sind bewusst getrennt (Pflichtenheft C5, D).
    @ViewBuilder
    private var quitSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if windowState.isMainWindowOpen {
                Button("Fenster schließen") { dismissWindow(id: WindowID.main) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Button("App beenden") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
                Text("Beendet Menüleiste und Fenster. Der Hintergrunddienst läuft weiter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if monitor.state.isReachable {
                VStack(alignment: .leading, spacing: 2) {
                    Button("Dienst stoppen", role: .destructive) { Task { await monitor.stop() } }
                        .disabled(monitor.isBusy)
                    Text("Beendet den Hintergrunddienst. Die App bleibt in der Menüleiste.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Schnellaktionen (D1). Jede Schaltfläche löst eine echte Aktion aus; „Neue Notiz“ öffnet ein kurzes
/// Formular und legt die Notiz über den Dienst in der Inbox an (IPC-Protokoll 3).
struct QuickActionsGrid: View {
    @Environment(ServiceMonitor.self) private var monitor
    let open: (MacSection?) -> Void
    @State private var showNote = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Schnellaktionen").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Button {
                        showNote.toggle()
                    } label: {
                        Label("Neue Notiz", systemImage: "square.and.pencil")
                    }
                    .disabled(monitor.isReachable != true)
                    .help(monitor.isReachable == true ? Text("Notiz in der Inbox erfassen") : Text("Der Hintergrunddienst ist nicht erreichbar."))
                    Button { open(.projects) } label: { Label("Projektübersicht", systemImage: "folder") }
                }
                GridRow {
                    Button { open(.queue) } label: { Label("Aufgabenqueue", systemImage: "clock") }
                    Button { open(.agents) } label: { Label("Agentenübersicht", systemImage: "cpu") }
                }
                GridRow {
                    CommandButton(String(localized: "Jetzt synchronisieren"), systemImage: "arrow.triangle.2.circlepath") { .syncNow }
                    CommandButton(String(localized: "Scanner aktualisieren"), systemImage: "magnifyingglass") { .refreshScanner }
                }
                GridRow {
                    Button { open(.settings) } label: { Label("Einstellungen", systemImage: "gearshape") }
                        .keyboardShortcut(",", modifiers: .command)
                    pauseResume
                }
            }
            if showNote {
                QuickNoteForm { showNote = false }
            }
        }
    }

    @ViewBuilder
    private var pauseResume: some View {
        switch monitor.state.runState {
        case .paused?:
            Button { Task { await monitor.resume() } } label: { Label("Dienst fortsetzen", systemImage: "play.circle") }
                .disabled(monitor.isBusy)
        case .running?:
            Button { Task { await monitor.pause() } } label: { Label("Dienst pausieren", systemImage: "pause.circle") }
                .disabled(monitor.isBusy)
        case nil:
            Button { Task { await monitor.start() } } label: { Label("Dienst prüfen", systemImage: "arrow.clockwise") }
                .disabled(monitor.isBusy)
        }
    }
}
