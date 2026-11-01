import Foundation

// Workspace entities of the Mac host (spec E1–E3, F3, G, M3). Additive to the v1 domain model.

public typealias ProjectSetupCommandID = Identifier<ProjectSetupCommand>
public typealias IndexedFolderID = Identifier<IndexedFolder>
public typealias FileConflictID = Identifier<FileConflict>

// MARK: - Project setup commands (spec E2, A03)

/// `CreateProject` creates a new project; `LinkProject` attaches a folder to an existing (draft) project.
public enum ProjectSetupKind: String, Hashable, Sendable, Codable, CaseIterable {
    case createProject
    case linkProject
}

/// What the iPhone selected. Paths are host-local paths as reported by the Mac index; the Mac
/// canonicalizes and validates them again before doing anything (spec E2).
public enum ProjectSetupTarget: Hashable, Sendable, Codable {
    /// A folder from the Mac index (Git repository, plain folder or repository subfolder).
    case indexedFolder(path: String)
    /// A new folder `folderName` inside `parentPath` (an allowed root or an indexed folder inside one).
    case newSubfolder(parentPath: String, folderName: String)
    /// Project without folder/repository (draft); a later `linkProject` command attaches a folder.
    case draftWithoutRepository
}

/// Explicit choice for folders inside an existing repository (spec E2: "bewusste Rückfrage").
public enum RepositoryScopeChoice: String, Hashable, Sendable, Codable, CaseIterable {
    case wholeRepository
    case subfolderOnly
}

/// Explicit user consent for `git init` (spec E2: only after consent).
public struct GitInitConsent: Hashable, Sendable, Codable {
    public let grantedBy: DeviceID?
    public let grantedAt: Date

    public init(grantedBy: DeviceID?, grantedAt: Date) {
        self.grantedBy = grantedBy
        self.grantedAt = grantedAt
    }
}

public enum ProjectSetupState: String, Hashable, Sendable, Codable, CaseIterable {
    case pending
    case completed
    case failed
}

public enum ProjectSetupFailureCode: String, Hashable, Sendable, Codable, CaseIterable {
    case invalidCommand
    case pathOutsideAllowedRoots
    case pathTraversal
    case symlinkNotAllowed
    case folderNotIndexed
    case folderNotFound
    case folderAlreadyExists
    case invalidFolderName
    case scopeChoiceRequired
    case gitInitConsentMissing
    case gitInitFailed
    case alreadyLinked
    case projectNotFound
    case fileSystemError
}

/// Failure with a German explanation for the iPhone (spec P: German UI).
public struct ProjectSetupFailure: Error, Hashable, Sendable, Codable {
    public let code: ProjectSetupFailureCode
    public let message: String

    public init(_ code: ProjectSetupFailureCode, _ message: String) {
        self.code = code
        self.message = message
    }
}

/// Validated `CreateProject`/`LinkProject` request created on the iPhone or Mac and executed by the Mac
/// host (spec E2). The iPhone never touches the Mac file system.
public struct ProjectSetupCommand: Hashable, Sendable, Codable, Identifiable {
    public let id: ProjectSetupCommandID
    public let kind: ProjectSetupKind
    /// Project to create (`createProject`) or to link (`linkProject`).
    public let projectId: ProjectID
    public var projectName: String
    public let target: ProjectSetupTarget
    /// Required when the target is a subfolder of an existing repository.
    public var repositoryScope: RepositoryScopeChoice?
    /// `git init` is requested; only executed with `gitInitConsent` (spec E2).
    public var initializeGitRepository: Bool
    public var gitInitConsent: GitInitConsent?
    public let requestedBy: DeviceID?
    public var hostId: HostID?
    public private(set) var state: ProjectSetupState
    public private(set) var failure: ProjectSetupFailure?
    /// Canonical folder the project was linked to.
    public private(set) var resultPath: String?
    public private(set) var revision: Int
    public let createdAt: Date
    public private(set) var updatedAt: Date

    public init(
        id: ProjectSetupCommandID = ProjectSetupCommandID(),
        kind: ProjectSetupKind,
        projectId: ProjectID = ProjectID(),
        projectName: String,
        target: ProjectSetupTarget,
        repositoryScope: RepositoryScopeChoice? = nil,
        initializeGitRepository: Bool = false,
        gitInitConsent: GitInitConsent? = nil,
        requestedBy: DeviceID? = nil,
        hostId: HostID? = nil,
        state: ProjectSetupState = .pending,
        failure: ProjectSetupFailure? = nil,
        resultPath: String? = nil,
        revision: Int = 1,
        createdAt: Date,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.projectId = projectId
        self.projectName = projectName
        self.target = target
        self.repositoryScope = repositoryScope
        self.initializeGitRepository = initializeGitRepository
        self.gitInitConsent = gitInitConsent
        self.requestedBy = requestedBy
        self.hostId = hostId
        self.state = state
        self.failure = failure
        self.resultPath = resultPath
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    /// Device-independent structural checks (the iPhone runs them before saving; the Mac repeats them).
    public func validateStructure() throws(ProjectSetupFailure) {
        if projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ProjectSetupFailure(.invalidCommand, String(localized: "Der Projektname darf nicht leer sein.", bundle: .module))
        }
        if initializeGitRepository, gitInitConsent == nil {
            throw ProjectSetupFailure(.gitInitConsentMissing, String(localized: "„git init“ wurde ohne ausdrückliche Zustimmung angefordert.", bundle: .module))
        }
        switch target {
        case .draftWithoutRepository:
            if kind == .linkProject {
                throw ProjectSetupFailure(.invalidCommand, String(localized: "Zum Verknüpfen muss ein Ordner gewählt werden.", bundle: .module))
            }
            if initializeGitRepository {
                throw ProjectSetupFailure(.invalidCommand, String(localized: "Ein Entwurf ohne Ordner kann kein Git-Repository erhalten.", bundle: .module))
            }
        case let .indexedFolder(path):
            if path.isEmpty || !path.hasPrefix("/") {
                throw ProjectSetupFailure(.invalidCommand, String(localized: "Der Ordnerpfad ist ungültig.", bundle: .module))
            }
        case let .newSubfolder(parentPath, folderName):
            if parentPath.isEmpty || !parentPath.hasPrefix("/") {
                throw ProjectSetupFailure(.invalidCommand, String(localized: "Der übergeordnete Ordner ist ungültig.", bundle: .module))
            }
            // Structural minimum only; the stricter name rules (`validateFolderName`) run in the iPhone flow,
            // and the Mac repeats its own path checks before creating anything.
            if folderName.isEmpty || folderName == "." || folderName == ".." || folderName.contains("/") {
                throw ProjectSetupFailure(.invalidFolderName, String(localized: "Der Ordnername „\(folderName)“ ist nicht zulässig.", bundle: .module))
            }
            if kind == .linkProject {
                throw ProjectSetupFailure(.invalidCommand, String(localized: "Verknüpfen ist nur mit bestehenden Ordnern möglich.", bundle: .module))
            }
        }
    }

    public var isPending: Bool { state == .pending }

    /// Maximum length of a new folder name in UTF-8 bytes (APFS limit 255).
    public static let maximumFolderNameBytes = 255

    /// Name rules for a new subfolder (spec E2: validated before the command is created, repeated on the
    /// Mac): a single path component, no traversal, no hidden folder, no control or reserved characters.
    public static func validateFolderName(_ folderName: String) throws(ProjectSetupFailure) {
        let invalid = ProjectSetupFailure(.invalidFolderName, String(localized: "Der Ordnername „\(folderName)“ ist nicht zulässig.", bundle: .module))
        let trimmed = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == folderName else { throw invalid }
        guard folderName != ".", folderName != "..", !folderName.hasPrefix(".") else { throw invalid }
        guard folderName.utf8.count <= maximumFolderNameBytes else { throw invalid }
        let forbidden = CharacterSet(charactersIn: "/:\\").union(.controlCharacters).union(.illegalCharacters)
        guard folderName.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else { throw invalid }
    }

    /// Whether the command has to name the repository scope (spec E2: subfolder of a repository).
    public static func requiresRepositoryScope(for folder: IndexedFolder) -> Bool {
        folder.kind == .repositorySubfolder
    }

    public mutating func complete(resultPath: String?, at date: Date) {
        state = .completed
        failure = nil
        self.resultPath = resultPath
        touch(at: date)
    }

    public mutating func fail(_ failure: ProjectSetupFailure, at date: Date) {
        state = .failed
        self.failure = failure
        touch(at: date)
    }

    public mutating func touch(at date: Date) {
        revision += 1
        updatedAt = date
    }
}

// MARK: - Indexed folders (spec E1/E2)

/// Classification of a folder found below a configured root folder (spec E1).
public enum IndexedFolderKind: String, Hashable, Sendable, Codable, CaseIterable {
    case gitRepository
    case bareRepository
    /// Linked worktree; attached to its main repository, never a separate project.
    case linkedWorktree
    /// Submodule; attached to its superproject.
    case submodule
    case repositorySubfolder
    case plainFolder

    /// The iPhone distinction "Git-Repository / noch kein Repository / Unterordner eines Repositories" (E2).
    public var repositoryKind: RepositoryKind? {
        switch self {
        case .gitRepository: .gitRepository
        case .plainFolder: .notARepository
        case .repositorySubfolder: .subfolderOfRepository
        case .bareRepository, .linkedWorktree, .submodule: nil
        }
    }
}

/// Existing project documents detected in a folder (spec E3).
public struct DetectedProjectDocuments: Hashable, Sendable, Codable {
    public var hasAgentsFile: Bool
    public var hasClaudeFile: Bool
    /// Repository-relative README files.
    public var readmeFiles: [String]
    /// Repository-relative ADR folder, if one exists.
    public var adrFolder: String?
    public var adrFileCount: Int
    /// Repository-relative requests folder, if one exists.
    public var requestsFolder: String?
    public var requestFileCount: Int

    public init(
        hasAgentsFile: Bool = false, hasClaudeFile: Bool = false, readmeFiles: [String] = [],
        adrFolder: String? = nil, adrFileCount: Int = 0, requestsFolder: String? = nil, requestFileCount: Int = 0
    ) {
        self.hasAgentsFile = hasAgentsFile
        self.hasClaudeFile = hasClaudeFile
        self.readmeFiles = readmeFiles
        self.adrFolder = adrFolder
        self.adrFileCount = adrFileCount
        self.requestsFolder = requestsFolder
        self.requestFileCount = requestFileCount
    }
}

/// One folder of the Mac index. Selectable folders are offered on the iPhone for `CreateProject` (E2).
public struct IndexedFolder: Hashable, Sendable, Codable, Identifiable {
    public let id: IndexedFolderID
    public let hostId: HostID
    public var canonicalPath: String
    public var displayName: String
    public var kind: IndexedFolderKind
    /// Root of the enclosing/main repository (subfolders, worktrees, submodules).
    public var repositoryRootPath: String?
    public var scanRootPath: String
    public var depth: Int
    public var projectId: ProjectID?
    public var repositoryIdentity: RepositoryIdentity?
    public var defaultBranch: String?
    public var remote: String?
    /// Host-local file system fingerprint of the git dir (device/inode) to recognise moved folders.
    public var fileSystemFingerprint: String?
    public var documents: DetectedProjectDocuments?
    /// Offered on the iPhone as target for a new project.
    public var isSelectable: Bool
    public var isAvailable: Bool
    public var lastSeenAt: Date

    public init(
        id: IndexedFolderID = IndexedFolderID(), hostId: HostID, canonicalPath: String, displayName: String,
        kind: IndexedFolderKind, repositoryRootPath: String? = nil, scanRootPath: String, depth: Int,
        projectId: ProjectID? = nil, repositoryIdentity: RepositoryIdentity? = nil, defaultBranch: String? = nil,
        remote: String? = nil, fileSystemFingerprint: String? = nil, documents: DetectedProjectDocuments? = nil,
        isSelectable: Bool, isAvailable: Bool = true, lastSeenAt: Date
    ) {
        self.id = id
        self.hostId = hostId
        self.canonicalPath = canonicalPath
        self.displayName = displayName
        self.kind = kind
        self.repositoryRootPath = repositoryRootPath
        self.scanRootPath = scanRootPath
        self.depth = depth
        self.projectId = projectId
        self.repositoryIdentity = repositoryIdentity
        self.defaultBranch = defaultBranch
        self.remote = remote
        self.fileSystemFingerprint = fileSystemFingerprint
        self.documents = documents
        self.isSelectable = isSelectable
        self.isAvailable = isAvailable
        self.lastSeenAt = lastSeenAt
    }
}

// MARK: - File conflicts (spec E3, N2, A04, A24, ADR-0016)

public enum FileConflictKind: String, Hashable, Sendable, Codable, CaseIterable {
    /// Request file and database changed since the last reconciliation.
    case concurrentEdit
    /// Status edited in the file while an agent job is active, to a status the job cannot report (ADR-0012).
    case statusChangeDuringActiveJob
    /// A materialized request file disappeared; data is kept until the user decides.
    case fileDeleted
    /// The file can no longer be parsed (frontmatter broken, UUID changed, …).
    case invalidFile
    /// The linked GitHub issue changed since the last sync (ADR-0016: local file leads).
    case gitHubDivergence
}

public enum FileConflictResolution: String, Hashable, Sendable, Codable, CaseIterable {
    /// Database version is written back to the file (or pushed to GitHub).
    case keptDatabase
    /// File (or GitHub) version is taken over into the database.
    case acceptedExternal
    case dismissed
}

/// Conflict between the database and an external source (request file, GitHub issue). Both versions are
/// kept; nothing is overwritten silently (spec N2).
public struct FileConflict: Hashable, Sendable, Codable, Identifiable {
    public let id: FileConflictID
    public let projectId: ProjectID
    public let workItemId: WorkItemID?
    public let adrId: ADRID?
    /// Repository-relative path (or `owner/repo#123` for GitHub).
    public let location: String
    public let kind: FileConflictKind
    public let databaseRevision: Int
    /// Database version rendered as Markdown, if available.
    public let databaseText: String?
    /// File/GitHub version.
    public let externalText: String?
    public let detail: String?
    public let detectedAt: Date
    public private(set) var resolvedAt: Date?
    public private(set) var resolution: FileConflictResolution?
    /// Resolution chosen on a device without file access (iPhone); the Mac host applies it to the files
    /// and then records `resolution` (spec N2: user decides on either device). Absent in older payloads.
    public private(set) var requestedResolution: FileConflictResolution?
    public private(set) var requestedBy: DeviceID?
    public private(set) var requestedAt: Date?

    public init(
        id: FileConflictID = FileConflictID(), projectId: ProjectID, workItemId: WorkItemID? = nil, adrId: ADRID? = nil,
        location: String, kind: FileConflictKind, databaseRevision: Int, databaseText: String? = nil,
        externalText: String? = nil, detail: String? = nil, detectedAt: Date, resolvedAt: Date? = nil,
        resolution: FileConflictResolution? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.workItemId = workItemId
        self.adrId = adrId
        self.location = location
        self.kind = kind
        self.databaseRevision = databaseRevision
        self.databaseText = databaseText
        self.externalText = externalText
        self.detail = detail
        self.detectedAt = detectedAt
        self.resolvedAt = resolvedAt
        self.resolution = resolution
    }

    public var isResolved: Bool { resolvedAt != nil }
    /// Requested on another device and not yet applied by the Mac host.
    public var hasPendingRequest: Bool { requestedResolution != nil && !isResolved }

    public mutating func resolve(_ resolution: FileConflictResolution, at date: Date) {
        self.resolution = resolution
        resolvedAt = date
    }

    /// Records the user's choice from a device that cannot touch the files (iPhone). Ignored once resolved.
    public mutating func requestResolution(_ resolution: FileConflictResolution, by device: DeviceID, at date: Date) {
        guard !isResolved else { return }
        requestedResolution = resolution
        requestedBy = device
        requestedAt = date
    }
}
