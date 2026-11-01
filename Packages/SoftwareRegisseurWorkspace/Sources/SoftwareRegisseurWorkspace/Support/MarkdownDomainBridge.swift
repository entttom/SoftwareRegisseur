import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurGit
import SoftwareRegisseurMarkdown

// The Markdown package has its own vocabulary types (it must not depend on Domain). These aliases keep
// both worlds apart inside this package.
public typealias DomainWorkItemStatus = SoftwareRegisseurDomain.WorkItemStatus
public typealias MarkdownWorkItemStatus = SoftwareRegisseurMarkdown.WorkItemStatus
public typealias DomainHumanID = SoftwareRegisseurDomain.HumanID
public typealias MarkdownHumanID = SoftwareRegisseurMarkdown.HumanID
public typealias DomainADRStatus = SoftwareRegisseurDomain.ADRStatus
public typealias MarkdownADRStatus = SoftwareRegisseurMarkdown.ADRStatus
public typealias DomainRepositoryIdentity = SoftwareRegisseurDomain.RepositoryIdentity
public typealias GitRepositoryIdentity = SoftwareRegisseurGit.RepositoryIdentity

public enum BridgeError: Error, Hashable, Sendable {
    /// Markdown accepts `FR-0000` from imports; the domain range starts at 1 (ADR-0018).
    case humanIDOutOfDomainRange(String)
    case invalidLayoutPath(field: String, value: String)
}

/// Lossless conversions between the Markdown vocabulary and the Domain model (status, priority, type,
/// human IDs, ADR status, folder layout).
public enum MarkdownDomainBridge {
    // MARK: Status (identical raw values on both sides, ADR-0012)

    public static func domain(_ status: MarkdownWorkItemStatus) -> DomainWorkItemStatus {
        switch status {
        case .inbox: .inbox
        case .open: .open
        case .queued: .queued
        case .scheduled: .scheduled
        case .inProgress: .inProgress
        case .waitingApproval: .waitingApproval
        case .implementationFinished: .implementationFinished
        case .review: .review
        case .integrated: .integrated
        case .done: .done
        case .blocked: .blocked
        case .failed: .failed
        case .cancelled: .cancelled
        case .paused: .paused
        }
    }

    public static func markdown(_ status: DomainWorkItemStatus) -> MarkdownWorkItemStatus {
        switch status {
        case .inbox: .inbox
        case .open: .open
        case .queued: .queued
        case .scheduled: .scheduled
        case .inProgress: .inProgress
        case .waitingApproval: .waitingApproval
        case .implementationFinished: .implementationFinished
        case .review: .review
        case .integrated: .integrated
        case .done: .done
        case .blocked: .blocked
        case .failed: .failed
        case .cancelled: .cancelled
        case .paused: .paused
        }
    }

    // MARK: Priority

    public static func domain(_ priority: RequestPriority) -> Priority {
        switch priority {
        case .low: .low
        case .medium: .medium
        case .high: .high
        case .urgent: .urgent
        }
    }

    public static func markdown(_ priority: Priority) -> RequestPriority {
        switch priority {
        case .low: .low
        case .medium: .medium
        case .high: .high
        case .urgent: .urgent
        }
    }

    // MARK: Type

    public static func domain(_ type: RequestType) -> WorkItemType {
        switch type {
        case .feature: .feature
        case .bug: .bug
        case .todo: .todo
        case .improvement: .improvement
        case .note: .note
        }
    }

    public static func markdown(_ type: WorkItemType) -> RequestType {
        switch type {
        case .feature: .feature
        case .bug: .bug
        case .todo: .todo
        case .improvement: .improvement
        case .note: .note
        }
    }

    // MARK: Human IDs (ADR-0018)

    public static func domain(_ id: MarkdownHumanID) throws(BridgeError) -> DomainHumanID {
        do {
            return try DomainHumanID(type: domain(id.prefix.requestType), number: id.number)
        } catch {
            throw .humanIDOutOfDomainRange(id.description)
        }
    }

    public static func markdown(_ id: DomainHumanID) -> MarkdownHumanID {
        MarkdownHumanID(prefix: markdown(id.type).idPrefix, number: id.number)
    }

    // MARK: ADR status

    /// `rejected` (MADR) has no domain counterpart; it maps to `deprecated` and is reported by the importer.
    public static func domain(_ status: MarkdownADRStatus) -> DomainADRStatus {
        switch status {
        case .proposed: .proposed
        case .accepted: .accepted
        case .deprecated, .rejected: .deprecated
        case .superseded: .superseded
        }
    }

    public static func markdown(_ status: DomainADRStatus) -> MarkdownADRStatus {
        switch status {
        case .proposed: .proposed
        case .accepted: .accepted
        case .deprecated: .deprecated
        case .superseded: .superseded
        }
    }

    // MARK: Folder layout (spec F2/F5, ADR-0004)

    /// Folder layout of a project. Status groups follow spec F5: queued/scheduled live in the open folder,
    /// review statuses in review, integrated/done in done; blocked/failed/cancelled/paused stay in place.
    public static func folderLayout(_ settings: ProjectSettings) throws(BridgeError) -> FolderLayout {
        func path(_ value: String, _ field: String) throws(BridgeError) -> RelativePath {
            do { return try RelativePath(value) } catch { throw .invalidLayoutPath(field: field, value: value) }
        }
        let open = try path(settings.openPath, "openPath")
        let active = try path(settings.activePath, "activePath")
        let review = try path(settings.reviewPath, "reviewPath")
        let done = try path(settings.donePath, "donePath")
        return FolderLayout(
            adrPath: try path(settings.adrPath, "adrPath"),
            requestsRoot: try path(settings.requestsRoot, "requestsRoot"),
            statusFolders: [
                .inbox: open, .open: open, .queued: open, .scheduled: open,
                .inProgress: active, .waitingApproval: active,
                .implementationFinished: review, .review: review,
                .integrated: done, .done: done,
            ]
        )
    }

    // MARK: Repository identity

    public static func domain(_ identity: GitRepositoryIdentity) -> DomainRepositoryIdentity? {
        DomainRepositoryIdentity(rawValue: identity.value)
    }
}
