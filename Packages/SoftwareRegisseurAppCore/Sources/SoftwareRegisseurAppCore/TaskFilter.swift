import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

/// Filter of the „Aufgaben“ list (spec H1: Projekt, Status, Typ, Label, Priorität, Agent; Suche).
/// Project/status/type/label/priority/text run in SQLite (`WorkItemFilter`, FTS); the agent filter needs the
/// job table and runs on the result.
public struct TaskFilter: Hashable, Sendable {
    public enum ProjectScope: Hashable, Sendable {
        case any
        case withoutProject
        case project(ProjectID)
    }

    /// Status groups offered as quick filters.
    public enum StatusGroup: String, Hashable, Sendable, CaseIterable {
        case all
        case open
        case active
        case review
        case finished

        public var statuses: Set<WorkItemStatus> {
            switch self {
            case .all: []
            case .open: [.inbox, .open, .blocked, .failed, .paused]
            case .active: [.queued, .scheduled, .inProgress, .waitingApproval]
            case .review: [.implementationFinished, .review, .integrated]
            case .finished: [.done, .cancelled]
            }
        }
    }

    public var project: ProjectScope
    public var statuses: Set<WorkItemStatus>
    public var types: Set<WorkItemType>
    public var priorities: Set<Priority>
    public var label: String?
    public var searchText: String
    public var agent: ProviderID?
    /// Archived items are hidden by default (spec H1; archiving is not a status, ADR-0012).
    public var archive: WorkItemFilter.ArchiveScope

    public init(
        project: ProjectScope = .any,
        statuses: Set<WorkItemStatus> = [],
        types: Set<WorkItemType> = [],
        priorities: Set<Priority> = [],
        label: String? = nil,
        searchText: String = "",
        agent: ProviderID? = nil,
        archive: WorkItemFilter.ArchiveScope = .activeOnly
    ) {
        self.archive = archive
        self.project = project
        self.statuses = statuses
        self.types = types
        self.priorities = priorities
        self.label = label
        self.searchText = searchText
        self.agent = agent
    }

    public var trimmedSearch: String? {
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    public var isActive: Bool {
        project != .any || !statuses.isEmpty || !types.isEmpty || !priorities.isEmpty || label != nil
            || trimmedSearch != nil || agent != nil || archive != .activeOnly
    }

    /// The part evaluated by the database.
    public var repositoryFilter: WorkItemFilter {
        let scope: WorkItemFilter.ProjectScope = switch project {
        case .any: .any
        case .withoutProject: .withoutProject
        case let .project(id): .project(id)
        }
        return WorkItemFilter(
            project: scope, statuses: statuses, types: types, label: label, priorities: priorities, text: trimmedSearch,
            archive: archive
        )
    }

    /// Same semantics in memory (used for the agent criterion and to re-check items after local edits).
    /// `jobProviders` are the agents of the item's jobs.
    public func matches(_ item: WorkItem, jobProviders: Set<ProviderID> = []) -> Bool {
        switch project {
        case .any: break
        case .withoutProject: if item.projectId != nil { return false }
        case let .project(id): if item.projectId != id { return false }
        }
        switch archive {
        case .any: break
        case .activeOnly: if item.isArchived { return false }
        case .archivedOnly: if !item.isArchived { return false }
        }
        if !statuses.isEmpty, !statuses.contains(item.status) { return false }
        if !types.isEmpty, !types.contains(item.type) { return false }
        if !priorities.isEmpty, !priorities.contains(item.priority) { return false }
        if let label, !item.labels.contains(label) { return false }
        if let agent, !jobProviders.contains(agent) { return false }
        if let text = trimmedSearch {
            let haystack = [item.title, item.originalNote, item.transcript ?? "", item.structuredBody]
            let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
            let allFound = tokens.allSatisfy { token in
                haystack.contains { $0.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
            if !allFound { return false }
        }
        return true
    }

    /// Distinct labels of the given items, sorted, for the label picker.
    public static func labels(in items: [WorkItem]) -> [String] {
        Array(Set(items.flatMap(\.labels))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// Runs a `TaskFilter` against the repositories.
public struct TaskQuery: Sendable {
    public let workItems: any WorkItemRepository
    public let jobs: any AgentJobRepository

    public init(workItems: any WorkItemRepository, jobs: any AgentJobRepository) {
        self.workItems = workItems
        self.jobs = jobs
    }

    public func run(_ filter: TaskFilter) async throws -> [WorkItem] {
        let items = try await workItems.list(filter.repositoryFilter)
        guard let agent = filter.agent else { return items }
        // One query for all jobs instead of one per item.
        let allJobs = try await jobs.jobs(inStates: Set(AgentJobState.allCases), hostId: nil, limit: nil)
        let itemsWithAgent = Set(allJobs.filter { $0.providerId == agent }.map(\.workItemId))
        return items.filter { itemsWithAgent.contains($0.uuid) }
    }
}
