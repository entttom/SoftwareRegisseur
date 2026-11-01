import Observation
import SwiftUI
import SoftwareRegisseurDomain

enum WindowID {
    static let main = "main"
}

/// Zustand der Fenster, den das Menüleisten-Menü für „Fenster schließen“ braucht.
@MainActor
@Observable
final class WindowState {
    var isMainWindowOpen = false
}

/// Navigation des Hauptfensters (Pflichtenheft D2, P macOS-Ansichten).
enum MacSection: String, CaseIterable, Identifiable, Hashable {
    case dashboard, projects, inbox, requests, adrs, agents, queue, review, history, settings

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .dashboard: "Dashboard"
        case .projects: "Projekte"
        case .inbox: "Inbox"
        case .requests: "Aufgaben/Requests"
        case .adrs: "ADRs"
        case .agents: "Agenten"
        case .queue: "Warteschlange"
        case .review: "Review"
        case .history: "Historie"
        case .settings: "Einstellungen"
        }
    }

    var symbolName: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .projects: "folder"
        case .inbox: "tray"
        case .requests: "checklist"
        case .adrs: "doc.text"
        case .agents: "cpu"
        case .queue: "clock"
        case .review: "eye"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }

    /// Tastenkürzel ⌘1 … ⌘0 (Tastaturbedienung am Mac, P).
    var shortcut: KeyEquivalent? {
        switch self {
        case .dashboard: "1"
        case .projects: "2"
        case .inbox: "3"
        case .requests: "4"
        case .adrs: "5"
        case .agents: "6"
        case .queue: "7"
        case .review: "8"
        case .history: "9"
        case .settings: nil
        }
    }
}

/// Gemeinsame Auswahl von Menüleiste und Hauptfenster (Sprung aus der Menüleiste zu Job/Aufgabe).
@MainActor
@Observable
final class NavigationModel {
    var section: MacSection? = .dashboard
    var selectedProject: ProjectID?
    var selectedWorkItem: WorkItemID?
    var selectedInboxItem: WorkItemID?
    var selectedJob: JobID?
    var selectedReview: ReviewID?
    var selectedADR: ADRID?
    var queueFilter: QueueFilter = .active
    var queueProvider: ProviderID?

    func show(_ section: MacSection) {
        self.section = section
    }

    func showJob(_ job: JobID, filter: QueueFilter? = nil) {
        if let filter { queueFilter = filter }
        queueProvider = nil
        selectedJob = job
        section = .queue
    }

    func showQueue(filter: QueueFilter, provider: ProviderID? = nil) {
        queueFilter = filter
        queueProvider = provider
        section = .queue
    }

    func showWorkItem(_ item: WorkItem) {
        if item.projectId == nil {
            selectedInboxItem = item.uuid
            section = .inbox
        } else {
            selectedWorkItem = item.uuid
            section = .requests
        }
    }

    func showReview(_ review: ReviewID) {
        selectedReview = review
        section = .review
    }

    func showProject(_ project: ProjectID) {
        selectedProject = project
        section = .projects
    }
}
