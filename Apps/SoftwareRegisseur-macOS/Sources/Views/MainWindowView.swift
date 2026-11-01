import SwiftUI
import SoftwareRegisseurDomain

/// Hauptfenster (Pflichtenheft D2): Seitenleiste mit allen Bereichen, Hinweisband für Befehlsrückmeldungen.
struct MainWindowView: View {
    @Environment(WindowState.self) private var windowState
    @Environment(NavigationModel.self) private var navigation
    @Environment(LibraryStore.self) private var library
    @Environment(ServiceMonitor.self) private var monitor

    var body: some View {
        @Bindable var navigation = navigation
        NavigationSplitView {
            List(selection: $navigation.section) {
                ForEach(MacSection.allCases) { section in
                    Label {
                        Text(section.title)
                    } icon: {
                        Image(systemName: section.symbolName)
                    }
                    .badge(badge(for: section))
                    .tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
            .safeAreaInset(edge: .bottom) {
                SidebarStatus()
            }
        } detail: {
            let section = navigation.section ?? .dashboard
            VStack(spacing: 0) {
                detail(for: section)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                FeedbackBanner()
            }
            .navigationTitle(Text(section.title))
        }
        .groupBoxStyle(CardGroupBoxStyle())
        .onAppear { windowState.isMainWindowOpen = true }
        .onDisappear { windowState.isMainWindowOpen = false }
    }

    @ViewBuilder
    private func detail(for section: MacSection) -> some View {
        switch section {
        case .dashboard: DashboardView()
        case .projects: ProjectsView()
        case .inbox: InboxView()
        case .requests: TasksView()
        case .adrs: ADRsView()
        case .agents: AgentsView()
        case .queue: QueueView()
        case .review: ReviewListView()
        case .history: HistoryView()
        case .settings: SettingsView()
        }
    }

    private func badge(for section: MacSection) -> Int {
        let snapshot = library.snapshot
        switch section {
        case .inbox: return snapshot.inboxItems.count
        case .review: return snapshot.pendingReviews.count
        case .queue: return snapshot.openApprovals.count
        default: return 0
        }
    }
}

/// Kurzstatus unten in der Seitenleiste.
private struct SidebarStatus: View {
    @Environment(ServiceMonitor.self) private var monitor

    var body: some View {
        let state = MacStatePresentation.make(reachable: monitor.isReachable, summary: monitor.currentSummary)
        StatusLabel(title: state.title, level: state.level, symbolName: state.symbolName)
            .font(.callout)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
