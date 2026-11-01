import Foundation

// Synced user-wide defaults (spec F2 Defaultstruktur, J2 globaler Standardagent, N1
// „Benutzerkonfiguration/Ordnerregeln“, P 8). One record per iCloud account.

public typealias GlobalSettingsID = Identifier<GlobalSettings>

/// Default folder layout for new projects (spec F2). Repository-relative paths.
public struct FolderLayoutDefaults: Hashable, Sendable, Codable {
    public var adrPath: String
    public var requestsRoot: String
    public var openPath: String
    public var activePath: String
    public var reviewPath: String
    public var donePath: String

    public static let standard = FolderLayoutDefaults()

    public init(
        adrPath: String = "docs/adr", requestsRoot: String = "docs/requests", openPath: String = "open",
        activePath: String = "in-progress", reviewPath: String = "review", donePath: String = "done"
    ) {
        self.adrPath = adrPath
        self.requestsRoot = requestsRoot
        self.openPath = openPath
        self.activePath = activePath
        self.reviewPath = reviewPath
        self.donePath = donePath
    }

    /// Relative, without traversal, non-empty (checked before saving on any device).
    public var isValid: Bool {
        [adrPath, requestsRoot, openPath, activePath, reviewPath, donePath].allSatisfy { path in
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && !trimmed.hasPrefix("/") && !trimmed.hasPrefix("~")
                && !trimmed.split(separator: "/").contains("..")
        }
    }
}

/// Defaults for execution settings of new projects (spec K1, L1, ADR-0015, G).
public struct WorkspaceDefaults: Hashable, Sendable, Codable {
    public var allowParallel: Bool
    public var projectWideLock: Bool
    public var maxParallelJobs: Int?
    public var reviewPolicy: ReviewPolicy
    public var integrationStrategy: IntegrationStrategy
    public var agentInstructionsPolicy: AgentInstructionsPolicy
    /// Pre-selection of the „git init“ consent toggle in the new-project flow. The user still has to
    /// confirm it per project (spec E2: `git init` only after consent).
    public var proposeGitInitForNewFolders: Bool

    public static let standard = WorkspaceDefaults()

    public init(
        allowParallel: Bool = true, projectWideLock: Bool = false, maxParallelJobs: Int? = nil,
        reviewPolicy: ReviewPolicy = .manualReview, integrationStrategy: IntegrationStrategy = .default,
        agentInstructionsPolicy: AgentInstructionsPolicy = .managedBlock, proposeGitInitForNewFolders: Bool = false
    ) {
        self.allowParallel = allowParallel
        self.projectWideLock = projectWideLock
        self.maxParallelJobs = maxParallelJobs
        self.reviewPolicy = reviewPolicy
        self.integrationStrategy = integrationStrategy
        self.agentInstructionsPolicy = agentInstructionsPolicy
        self.proposeGitInitForNewFolders = proposeGitInitForNewFolders
    }
}

public struct GlobalSettings: Hashable, Sendable, Codable, Identifiable {
    /// Fixed identity: one settings record per account, edited on any device (no per-device copies).
    public static let singletonID = GlobalSettingsID(UUID(uuidString: "5E77A1B5-0000-4000-8000-000000000001")!)

    public let id: GlobalSettingsID
    /// Agent preselected in „Mit Agent umsetzen“ when the project has no default (spec J2).
    public var defaultAgentId: ProviderID?
    public var folderLayout: FolderLayoutDefaults
    public var workspace: WorkspaceDefaults
    public private(set) var revision: Int
    public private(set) var updatedAt: Date

    public init(
        defaultAgentId: ProviderID? = nil, folderLayout: FolderLayoutDefaults = .standard,
        workspace: WorkspaceDefaults = .standard, revision: Int = 1, updatedAt: Date
    ) {
        id = Self.singletonID
        self.defaultAgentId = defaultAgentId
        self.folderLayout = folderLayout
        self.workspace = workspace
        self.revision = revision
        self.updatedAt = updatedAt
    }

    /// Defaults used before the user saved anything (revision 0 = never stored).
    public static var defaults: GlobalSettings {
        GlobalSettings(revision: 0, updatedAt: Date(timeIntervalSinceReferenceDate: 0))
    }

    public var isStored: Bool { revision > 0 }

    /// Project settings for a new project, pre-filled from these defaults (spec F2).
    public func makeProjectSettings(id: ProjectSettingsID = ProjectSettingsID(), updatedAt: Date) -> ProjectSettings {
        ProjectSettings(
            id: id, adrPath: folderLayout.adrPath, requestsRoot: folderLayout.requestsRoot,
            openPath: folderLayout.openPath, activePath: folderLayout.activePath, reviewPath: folderLayout.reviewPath,
            donePath: folderLayout.donePath, defaultAgentId: nil, allowParallel: workspace.allowParallel,
            projectWideLock: workspace.projectWideLock, maxParallelJobs: workspace.maxParallelJobs,
            reviewPolicy: workspace.reviewPolicy, integrationStrategy: workspace.integrationStrategy,
            agentInstructionsPolicy: workspace.agentInstructionsPolicy, updatedAt: updatedAt
        )
    }

    /// Effective default agent: project default first, then this global default (spec J2).
    public func preferredAgent(project: ProjectSettings?) -> ProviderID? {
        project?.defaultAgentId ?? defaultAgentId
    }

    public mutating func touch(at date: Date) {
        revision += 1
        updatedAt = date
    }
}
