import Foundation

/// How the Mac classified the project folder (spec E1/E2).
public enum RepositoryKind: String, Hashable, Sendable, Codable, CaseIterable {
    case gitRepository
    case notARepository
    case subfolderOfRepository
}

public struct Project: Hashable, Sendable, Codable, Identifiable {
    public let id: ProjectID
    public var name: String
    /// Stable identity from Git/local metadata; nil until the Mac has set the project up (spec E1).
    public var repositoryIdentity: RepositoryIdentity?
    public var repositoryKind: RepositoryKind
    /// Remote URL string as reported by Git; never the sole project identity (spec O).
    public var remote: String?
    /// Designated execution host (spec N4).
    public var hostId: HostID?
    public private(set) var status: ProjectStatus
    /// Optional German explanation for `needsAttention`/`unavailable`/`pendingMacSetup` (spec E2), e.g. why
    /// a `CreateProject` command failed. Additive field; absent in older payloads (decodes as nil).
    public var statusReason: String?
    public var settingsId: ProjectSettingsID
    public private(set) var revision: Int
    public let createdAt: Date
    public private(set) var updatedAt: Date

    public init(
        id: ProjectID = ProjectID(),
        name: String,
        repositoryIdentity: RepositoryIdentity? = nil,
        repositoryKind: RepositoryKind,
        remote: String? = nil,
        hostId: HostID? = nil,
        status: ProjectStatus = .pendingMacSetup,
        settingsId: ProjectSettingsID,
        revision: Int = 1,
        createdAt: Date,
        updatedAt: Date? = nil,
        statusReason: String? = nil
    ) {
        self.id = id
        self.name = name
        self.statusReason = statusReason
        self.repositoryIdentity = repositoryIdentity
        self.repositoryKind = repositoryKind
        self.remote = remote
        self.hostId = hostId
        self.status = status
        self.settingsId = settingsId
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    public mutating func transition(to next: ProjectStatus, at date: Date) throws(InvalidStateTransition<ProjectStatus>) {
        try status.transition(to: next)
        touch(at: date)
    }

    /// Transition with a reason (or clearing it with nil). Same status only updates the reason.
    public mutating func transition(to next: ProjectStatus, reason: String?, at date: Date) throws(InvalidStateTransition<ProjectStatus>) {
        let statusChanges = next != status
        guard statusChanges || reason != statusReason else { return }
        if statusChanges { try status.transition(to: next) }
        statusReason = reason
        touch(at: date)
    }

    /// Bumps revision and modification time after a field change.
    public mutating func touch(at date: Date) {
        revision += 1
        updatedAt = date
    }
}

public enum RepositoryScanState: String, Hashable, Sendable, Codable, CaseIterable {
    case notScanned
    case scanning
    case scanned
    case unreachable
    case failed
}

/// Host-local location of a project. Paths and bookmarks are only meaningful on `hostId` (spec O).
public struct RepositoryLocation: Hashable, Sendable, Codable {
    public let projectId: ProjectID
    public let hostId: HostID
    public var canonicalPath: String
    /// Opaque reference to a host-local security-scoped bookmark; not the bookmark data itself.
    public var bookmarkReference: String?
    public var scanState: RepositoryScanState
    public var lastScanAt: Date?

    public init(
        projectId: ProjectID,
        hostId: HostID,
        canonicalPath: String,
        bookmarkReference: String? = nil,
        scanState: RepositoryScanState = .notScanned,
        lastScanAt: Date? = nil
    ) {
        self.projectId = projectId
        self.hostId = hostId
        self.canonicalPath = canonicalPath
        self.bookmarkReference = bookmarkReference
        self.scanState = scanState
        self.lastScanAt = lastScanAt
    }
}

/// How an approved agent branch is integrated into the default branch (ADR-0015). Never pushes.
public enum IntegrationStrategy: String, Hashable, Sendable, Codable, CaseIterable {
    case squash
    case mergeCommit
    case cherryPick

    public static let `default`: IntegrationStrategy = .squash
}

public enum ReviewPolicy: String, Hashable, Sendable, Codable, CaseIterable {
    /// User reviews diff before integration.
    case manualReview
    /// Tests must pass and the user reviews before integration.
    case testsAndManualReview
}

public enum AgentInstructionsPolicy: String, Hashable, Sendable, Codable, CaseIterable {
    /// Maintain a managed block in AGENTS.md (and CLAUDE.md if present), never overwrite user text (spec G).
    case managedBlock
    /// Show proposed changes only; user applies them.
    case proposeOnly
    case disabled
}

/// Per-project configuration (spec F2, J2a, L1, ADR-0015). All paths are repository-relative.
public struct ProjectSettings: Hashable, Sendable, Codable, Identifiable {
    public let id: ProjectSettingsID
    public var adrPath: String
    public var requestsRoot: String
    public var openPath: String
    public var activePath: String
    public var reviewPath: String
    public var donePath: String
    public var defaultAgentId: ProviderID?
    /// Project-scoped model/effort preference per agent (ADR-0006).
    public var agentModelPreferencesByProvider: [ProviderID: AgentModelPreference]
    public var allowParallel: Bool
    /// Optional project-wide lock: only one agent per repository (spec L1).
    public var projectWideLock: Bool
    public var maxParallelJobs: Int?
    public var reviewPolicy: ReviewPolicy
    public var integrationStrategy: IntegrationStrategy
    public var agentInstructionsPolicy: AgentInstructionsPolicy
    public private(set) var revision: Int
    public private(set) var updatedAt: Date

    public init(
        id: ProjectSettingsID = ProjectSettingsID(),
        adrPath: String = "docs/adr",
        requestsRoot: String = "docs/requests",
        openPath: String = "open",
        activePath: String = "in-progress",
        reviewPath: String = "review",
        donePath: String = "done",
        defaultAgentId: ProviderID? = nil,
        agentModelPreferencesByProvider: [ProviderID: AgentModelPreference] = [:],
        allowParallel: Bool = true,
        projectWideLock: Bool = false,
        maxParallelJobs: Int? = nil,
        reviewPolicy: ReviewPolicy = .manualReview,
        integrationStrategy: IntegrationStrategy = .default,
        agentInstructionsPolicy: AgentInstructionsPolicy = .managedBlock,
        revision: Int = 1,
        updatedAt: Date
    ) {
        self.id = id
        self.adrPath = adrPath
        self.requestsRoot = requestsRoot
        self.openPath = openPath
        self.activePath = activePath
        self.reviewPath = reviewPath
        self.donePath = donePath
        self.defaultAgentId = defaultAgentId
        self.agentModelPreferencesByProvider = agentModelPreferencesByProvider
        self.allowParallel = allowParallel
        self.projectWideLock = projectWideLock
        self.maxParallelJobs = maxParallelJobs
        self.reviewPolicy = reviewPolicy
        self.integrationStrategy = integrationStrategy
        self.agentInstructionsPolicy = agentInstructionsPolicy
        self.revision = revision
        self.updatedAt = updatedAt
    }

    public func modelPreference(for provider: ProviderID) -> AgentModelPreference? {
        agentModelPreferencesByProvider[provider]
    }

    /// Stores a project-scoped preference. Changes apply to new jobs only (spec J2a, A38).
    public mutating func setModelPreference(_ preference: AgentModelPreference, at date: Date) {
        agentModelPreferencesByProvider[preference.providerId] = preference
        touch(at: date)
    }

    public mutating func touch(at date: Date) {
        revision += 1
        updatedAt = date
    }
}
