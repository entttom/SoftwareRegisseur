import SwiftUI
import SoftwareRegisseurAppCore
import SoftwareRegisseurDomain

/// Value-based destinations shared by every navigation stack of the app. Each tab owns exactly one
/// `NavigationStack(path:)`; pushed views never create their own stack (sheets still do), and every
/// stack root registers these destinations once via `appRouteDestinations()`.
enum AppRoute: Hashable {
    /// A spec P section pushed onto the compact „Mehr“ stack (or from another section, e.g. settings → agents).
    case section(AppTab)
    case task(WorkItemID)
    /// `fromTask`: opened from the task's own detail view; the task is one step back, so the review
    /// does not offer „Aufgabe öffnen“ again (no task → review → task → … ping-pong).
    case review(item: WorkItemID, review: ReviewID?, fromTask: Bool)
    case project(ProjectID)
    case projectTasks(ProjectID, title: String)
}

extension AppTab {
    var title: LocalizedStringResource {
        switch self {
        case .overview: "Übersicht"
        case .tasks: "Aufgaben"
        case .inbox: "Inbox"
        case .dictation: "Diktat"
        case .projects: "Projekte"
        case .agents: "Agenten"
        case .review: "Review"
        case .settings: "Einstellungen"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .tasks: "checklist"
        case .inbox: "tray"
        case .dictation: "mic"
        case .projects: "folder"
        case .agents: "cpu"
        case .review: "checkmark.seal"
        case .settings: "gearshape"
        }
    }

    /// Sections with their own tab in the compact tab bar. The others are reached through the app's own
    /// „Mehr“ tab: the system „More“ overflow (more than five tabs) wraps tabs in a UIKit navigation
    /// controller, which stacked a second navigation bar and back button on top of each tab's stack.
    static let compactPrimary: [AppTab] = [.overview, .tasks, .inbox, .dictation]
    static var compactMore: [AppTab] { allCases.filter { !compactPrimary.contains($0) } }

    var isCompactPrimary: Bool { Self.compactPrimary.contains(self) }

    /// Root view of the section, without a navigation stack (the caller owns the stack).
    @ViewBuilder @MainActor
    var rootView: some View {
        switch self {
        case .overview: OverviewView()
        case .tasks: TaskListView(initialFilter: TaskFilter(), title: "Aufgaben", isSectionRoot: true)
        case .inbox: InboxView()
        case .dictation: DictationView()
        case .projects: ProjectsView()
        case .agents: AgentsView()
        case .review: ReviewListView()
        case .settings: SettingsView()
        }
    }
}

/// Request to show a section, e.g. a count tile on the overview or „Aufgabe öffnen“ after dictation.
/// A fresh id per request so a repeated request for the same section is still applied.
struct TabRequest: Equatable {
    let tab: AppTab
    let id = UUID()
}

struct AppRouteDestination: View {
    let route: AppRoute

    var body: some View {
        switch route {
        case let .section(tab):
            tab.rootView
        case let .task(id):
            TaskDetailView(itemID: id)
        case let .review(item, review, fromTask):
            ReviewDetailView(itemID: item, reviewID: review, offersTaskLink: !fromTask)
        case let .project(id):
            ProjectDetailView(projectID: id)
        case let .projectTasks(id, title):
            TaskListView(initialFilter: TaskFilter(project: .project(id)), title: "\(title)")
        }
    }
}

extension View {
    /// Registers the shared destinations; call once on the root view inside each `NavigationStack`.
    func appRouteDestinations() -> some View {
        navigationDestination(for: AppRoute.self) { AppRouteDestination(route: $0) }
    }
}

/// Root of the compact „Mehr“ tab: the spec P sections without their own tab.
struct MoreView: View {
    var body: some View {
        List(AppTab.compactMore, id: \.self) { tab in
            NavigationLink(value: AppRoute.section(tab)) {
                Label { Text(tab.title) } icon: { Image(systemName: tab.symbol) }
            }
            .accessibilityIdentifier("more.\(tab.rawValue)")
        }
        .navigationTitle("Mehr")
    }
}
