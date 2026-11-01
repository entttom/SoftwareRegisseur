import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

/// Contents of „Übersicht“ (spec P iPhone 1, H1).
public struct OverviewSnapshot: Hashable, Sendable {
    public var projects: [Project]
    public var activeJobs: [AgentJob]
    public var waitingJobs: [AgentJob]
    public var openReviews: [WorkItem]
    public var recentlyFinished: [WorkItem]
    public var inboxCount: Int
    public var openTaskCount: Int

    public static let activeJobStates: Set<AgentJobState> = [.admitted, .starting, .running, .waitingApproval]
    public static let waitingJobStates: Set<AgentJobState> = [
        .requested, .pendingMac, .scheduled, .waitingQuota, .needsConfiguration, .paused,
    ]

    public init(projects: [Project] = [], activeJobs: [AgentJob] = [], waitingJobs: [AgentJob] = [],
                openReviews: [WorkItem] = [], recentlyFinished: [WorkItem] = [], inboxCount: Int = 0, openTaskCount: Int = 0) {
        self.projects = projects
        self.activeJobs = activeJobs
        self.waitingJobs = waitingJobs
        self.openReviews = openReviews
        self.recentlyFinished = recentlyFinished
        self.inboxCount = inboxCount
        self.openTaskCount = openTaskCount
    }

    public var isEmpty: Bool {
        projects.isEmpty && activeJobs.isEmpty && waitingJobs.isEmpty && openReviews.isEmpty
            && recentlyFinished.isEmpty && inboxCount == 0 && openTaskCount == 0
    }

    public static func build(projects: [Project], items: [WorkItem], jobs: [AgentJob], recentLimit: Int = 10) -> OverviewSnapshot {
        let visibleProjects = projects.filter { $0.status != .archived }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let active = jobs.filter { activeJobStates.contains($0.state) }.sorted { $0.updatedAt > $1.updatedAt }
        let waiting = jobs.filter { waitingJobStates.contains($0.state) }
            .sorted { ($0.scheduledAt ?? $0.createdAt) < ($1.scheduledAt ?? $1.createdAt) }
        let reviews = items.filter { $0.status == .review || $0.status == .implementationFinished }
            .sorted { $0.updatedAt > $1.updatedAt }
        let finished = items.filter { $0.status == .done || $0.status == .integrated }
            .sorted { $0.updatedAt > $1.updatedAt }
        return OverviewSnapshot(
            projects: visibleProjects,
            activeJobs: active,
            waitingJobs: waiting,
            openReviews: reviews,
            recentlyFinished: Array(finished.prefix(recentLimit)),
            inboxCount: items.filter { $0.projectId == nil && $0.status == .inbox }.count,
            openTaskCount: items.filter { TaskFilter.StatusGroup.open.statuses.contains($0.status) }.count
        )
    }
}

/// Mac availability as seen from the iPhone (spec J1: „zuletzt erkannt – Mac derzeit offline“).
public enum HostAvailability {
    /// Heartbeat age after which the Mac counts as offline. The Mac polls CloudKit periodically (ADR-0011),
    /// so a few missed polls are tolerated.
    public static let offlineThreshold: TimeInterval = 15 * 60

    public static func isOffline(_ host: AgentHost?, now: Date) -> Bool {
        guard let host else { return true }
        return !host.ready || host.isOffline(at: now, threshold: offlineThreshold)
    }
}

/// Review decisions sent from the iPhone (spec M1). The Mac executes integration and the move to `done`.
public enum ReviewAction: Hashable, Sendable {
    case approveIntegration
    case requestChanges
    case reject
    /// Only after the change reached the default branch (`integrated` with recorded commit).
    case markDone

    public static func available(for item: WorkItem, review: Review?) -> [ReviewAction] {
        switch item.status {
        case .review, .implementationFinished:
            guard let review, review.integrationCommit == nil else { return [] }
            return review.decision == .approved ? [.requestChanges] : [.approveIntegration, .requestChanges, .reject]
        case .integrated:
            return review?.integrationCommit != nil ? [.markDone] : []
        default:
            return []
        }
    }
}

public struct ReviewActionPerformer: Sendable {
    public let reviews: any ReviewRepository
    public let workItems: any WorkItemRepository

    public init(reviews: any ReviewRepository, workItems: any WorkItemRepository) {
        self.reviews = reviews
        self.workItems = workItems
    }

    public func perform(_ action: ReviewAction, item: WorkItem, review: Review?, actor: EventActor, at date: Date) async throws -> WorkItem {
        guard ReviewAction.available(for: item, review: review).contains(action) else { return item }
        switch action {
        case .approveIntegration, .requestChanges, .reject:
            guard var review else { return item }
            let decision: ReviewDecision = switch action {
            case .approveIntegration: .approved
            case .requestChanges: .changesRequested
            default: .rejected
            }
            review.decide(decision, at: date)
            try await reviews.save(review, at: date)
            let state: ReviewState = switch decision {
            case .approved: .approved
            case .changesRequested: .changesRequested
            case .rejected: .rejected
            case .pending: .pending
            }
            return try await workItems.update(item.uuid, expectedRevision: item.revision, actor: actor, at: date) {
                $0.reviewState = state
            }
        case .markDone:
            return try await workItems.changeStatus(item.uuid, to: .done, expectedRevision: item.revision, actor: actor, at: date)
        }
    }
}
