import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

/// Ein Projekt mit allen projektbezogenen Daten aus der Nur-Lese-Datenbank (ADR-0019).
struct ProjectEntry: Hashable, Sendable, Identifiable {
    var project: Project
    var settings: ProjectSettings?
    var locations: [RepositoryLocation]
    var adrs: [ADR]
    var activeLocks: [TaskLock]
    var setupCommands: [ProjectSetupCommand]

    var id: ProjectID { project.id }

    /// Ort auf diesem Mac; ohne bekannte Host-ID der zuletzt gescannte Ort.
    func location(hostId: HostID?) -> RepositoryLocation? {
        if let hostId, let match = locations.first(where: { $0.hostId == hostId }) { return match }
        return locations.max { ($0.lastScanAt ?? .distantPast) < ($1.lastScanAt ?? .distantPast) }
    }
}

/// Vollständiger Lesestand der Benutzeroberfläche. Wird bei jeder Datenbankänderung neu geladen.
struct LibrarySnapshot: Sendable {
    var loadedAt: Date
    var projects: [ProjectEntry]
    var workItems: [WorkItem]
    var jobs: [AgentJob]
    var reviews: [Review]
    var openApprovals: [PendingApproval]
    var hosts: [AgentHost]
    var capabilities: [AgentCapability]
    var globalSettings: GlobalSettings
    var globalPreferences: [AgentModelPreference]
    var fileConflicts: [FileConflict]
    var syncConflicts: [SyncConflict]
    var recentEvents: [TaskEvent]

    static let empty = LibrarySnapshot(
        loadedAt: .distantPast, projects: [], workItems: [], jobs: [], reviews: [], openApprovals: [], hosts: [],
        capabilities: [], globalSettings: .defaults, globalPreferences: [], fileConflicts: [], syncConflicts: [], recentEvents: []
    )

    func project(_ id: ProjectID?) -> ProjectEntry? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    func projectName(_ id: ProjectID?) -> String {
        guard let id else { return String(localized: "Inbox (ohne Projekt)") }
        return project(id)?.project.name ?? String(localized: "Unbekanntes Projekt")
    }

    func workItem(_ id: WorkItemID?) -> WorkItem? {
        guard let id else { return nil }
        return workItems.first { $0.uuid == id }
    }

    func job(_ id: JobID?) -> AgentJob? {
        guard let id else { return nil }
        return jobs.first { $0.jobId == id }
    }

    func jobs(for workItem: WorkItemID) -> [AgentJob] {
        jobs.filter { $0.workItemId == workItem }.sorted { $0.createdAt > $1.createdAt }
    }

    func activeJob(for workItem: WorkItemID) -> AgentJob? {
        jobs.first { $0.workItemId == workItem && $0.state.isActive }
    }

    func reviews(for job: JobID) -> [Review] {
        reviews.filter { $0.jobId == job }
    }

    /// Neuestes Review einer Aufgabe (über alle Jobs).
    func latestReview(for workItem: WorkItemID) -> Review? {
        for job in jobs(for: workItem) {
            if let review = reviews(for: job.jobId).last { return review }
        }
        return nil
    }

    func approvals(for job: JobID) -> [PendingApproval] {
        openApprovals.filter { $0.jobId == job }
    }

    func lock(for workItem: WorkItemID, projectId: ProjectID?) -> TaskLock? {
        guard let entry = project(projectId) else { return nil }
        return entry.activeLocks.first { $0.taskId == workItem }
            ?? entry.activeLocks.first { $0.scope == .project }
    }

    func fileConflicts(for workItem: WorkItemID) -> [FileConflict] {
        fileConflicts.filter { $0.workItemId == workItem }
    }

    /// Fähigkeiten des angegebenen Macs; ohne Host-ID die jeweils neueste Meldung je Agent.
    func capabilities(hostId: HostID?) -> [AgentCapability] {
        if let hostId {
            let onHost = capabilities.filter { $0.hostId == hostId }
            if !onHost.isEmpty { return onHost.sorted { $0.providerId < $1.providerId } }
        }
        var latest: [ProviderID: AgentCapability] = [:]
        for capability in capabilities where (latest[capability.providerId]?.lastChecked ?? .distantPast) < capability.lastChecked {
            latest[capability.providerId] = capability
        }
        return latest.values.sorted { $0.providerId < $1.providerId }
    }

    func globalPreference(for provider: ProviderID) -> AgentModelPreference? {
        globalPreferences.first { $0.providerId == provider }
    }

    var inboxItems: [WorkItem] {
        workItems.filter { $0.projectId == nil && !$0.isArchived }
    }

    var pendingReviews: [Review] {
        reviews.filter { $0.decision == .pending || ($0.decision == .approved && $0.integrationCommit == nil) }
    }
}

/// Lädt einen ``LibrarySnapshot`` ausschließlich lesend aus der Datenbank des Dienstes.
enum LibraryLoader {
    static let historyWindow: TimeInterval = 30 * 24 * 3600
    static let historyLimit = 1_000

    static func load(from database: AppDatabase, now: Date = .now) async throws -> LibrarySnapshot {
        let projects = try await database.projects.list()
        let setupCommands = try await database.projectSetupCommands.list()
        var entries: [ProjectEntry] = []
        entries.reserveCapacity(projects.count)
        for project in projects {
            entries.append(ProjectEntry(
                project: project,
                settings: try await database.projects.settings(forProject: project.id),
                locations: try await database.projects.locations(projectId: project.id),
                adrs: try await database.adrs.list(projectId: project.id),
                activeLocks: try await database.locks.activeLocks(projectId: project.id),
                setupCommands: setupCommands.filter { $0.projectId == project.id }
            ))
        }
        let jobs = try await database.jobs.jobs(inStates: Set(AgentJobState.allCases))
        var reviews: [Review] = []
        for job in jobs where job.state == .finished || job.state == .failed || job.state == .cancelled {
            reviews += try await database.reviews.reviews(jobId: job.jobId)
        }
        let hosts = try await database.capabilities.hosts()
        var capabilities: [AgentCapability] = []
        for host in hosts {
            capabilities += try await database.capabilities.capabilities(hostId: host.hostId)
        }
        return LibrarySnapshot(
            loadedAt: now,
            projects: entries.sorted { $0.project.name.localizedStandardCompare($1.project.name) == .orderedAscending },
            workItems: try await database.workItems.list(WorkItemFilter()),
            jobs: jobs,
            reviews: reviews,
            openApprovals: try await database.approvals.openApprovals(),
            hosts: hosts,
            capabilities: capabilities,
            globalSettings: try await database.globalSettings.fetch(),
            globalPreferences: try await database.preferences.preferences(scope: .global),
            fileConflicts: try await database.fileConflicts.open(),
            syncConflicts: try await database.sync.openConflicts(),
            recentEvents: try await database.events.events(since: now.addingTimeInterval(-historyWindow), limit: historyLimit)
        )
    }
}
