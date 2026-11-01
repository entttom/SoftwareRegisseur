import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

/// „Neues Projekt“ on the iPhone (spec E2). The iPhone never touches the Mac file system: it picks from the
/// synced folder index of the Mac and creates a validated `CreateProject`/`LinkProject` command that the
/// Mac executes when reachable.
public enum NewProjectOption: Hashable, Sendable {
    /// An existing folder from the Mac index (plain folder or repository subfolder). For a subfolder of a
    /// repository the user must choose whole repository vs. subfolder only.
    case existingFolder(IndexedFolder, scope: RepositoryScopeChoice?)
    /// A new folder `name` inside an allowed root (or an indexed plain folder inside one).
    case newSubfolder(parentPath: String, name: String)
    /// An existing Git repository of the Mac index.
    case linkRepository(IndexedFolder)
    /// Project without folder; a folder can be linked later.
    case draft
}

public struct NewProjectInput: Hashable, Sendable {
    public var name: String
    public var option: NewProjectOption
    /// The explicit consent toggle for `git init` (spec E2: only after consent). Ignored where no
    /// repository can be created (existing repositories, repository subfolders, drafts).
    public var gitInitConsent: Bool
    /// Links an existing (draft) project instead of creating a new one.
    public var linkToProject: ProjectID?

    public init(name: String, option: NewProjectOption, gitInitConsent: Bool = false, linkToProject: ProjectID? = nil) {
        self.name = name
        self.option = option
        self.gitInitConsent = gitInitConsent
        self.linkToProject = linkToProject
    }
}

public enum NewProjectBlocker: Hashable, Sendable {
    case emptyName
    case invalidFolderName
    case noAllowedRoots
    case parentNotAllowed
    case folderNotSelectable
    case folderAlreadyLinked
    case notARepository
    /// Repository subfolder without the explicit whole-repository/subfolder decision.
    case scopeChoiceRequired
    /// `git init` requested where it is not possible (inside a repository, draft).
    case gitInitNotPossible
    case draftCannotBeLinked
}

/// Folders and roots the user can choose from, derived from the synced Mac index.
public struct FolderChoices: Hashable, Sendable {
    public let folders: [IndexedFolder]

    public init(folders: [IndexedFolder]) {
        self.folders = folders.filter { $0.isSelectable && $0.isAvailable }
            .sorted { $0.canonicalPath.localizedStandardCompare($1.canonicalPath) == .orderedAscending }
    }

    /// Allowed roots (Stammordner) reported by the Mac.
    public var roots: [String] { Array(Set(folders.map(\.scanRootPath))).sorted() }

    /// „Bestehendes Git-Repository / noch kein Repository / Unterordner eines Repositories“ (E2).
    public func folders(of kind: RepositoryKind) -> [IndexedFolder] {
        folders.filter { $0.kind.repositoryKind == kind }
    }

    /// Parents for a new subfolder: the roots and plain (non-repository) folders inside them.
    public var subfolderParents: [String] {
        Array(Set(roots + folders.filter { $0.kind == .plainFolder }.map(\.canonicalPath))).sorted()
    }

    public func isAllowedParent(_ path: String) -> Bool {
        subfolderParents.contains(path)
    }
}

/// Validated plan: what will be stored locally and synced to the Mac.
public struct NewProjectPlan: Hashable, Sendable {
    /// New project in `pendingMacSetup`; nil when an existing project is linked.
    public let project: Project?
    public let settings: ProjectSettings?
    public let command: ProjectSetupCommand
}

public enum NewProjectError: Error, Hashable, Sendable {
    case blocked([NewProjectBlocker])
}

public enum NewProjectPlanner {
    public static func blockers(_ input: NewProjectInput, choices: FolderChoices) -> [NewProjectBlocker] {
        var blockers: [NewProjectBlocker] = []
        if input.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blockers.append(.emptyName) }
        switch input.option {
        case .draft:
            if input.gitInitConsent { blockers.append(.gitInitNotPossible) }
            if input.linkToProject != nil { blockers.append(.draftCannotBeLinked) }
        case let .newSubfolder(parentPath, name):
            if (try? ProjectSetupCommand.validateFolderName(name)) == nil { blockers.append(.invalidFolderName) }
            if choices.roots.isEmpty {
                blockers.append(.noAllowedRoots)
            } else if !choices.isAllowedParent(parentPath) {
                blockers.append(.parentNotAllowed)
            }
            if input.linkToProject != nil { blockers.append(.draftCannotBeLinked) }
        case let .existingFolder(folder, scope):
            blockers += folderBlockers(folder, choices: choices)
            if folder.kind == .repositorySubfolder {
                if scope == nil { blockers.append(.scopeChoiceRequired) }
                if input.gitInitConsent { blockers.append(.gitInitNotPossible) }
            } else if folder.kind == .gitRepository, input.gitInitConsent {
                blockers.append(.gitInitNotPossible)
            }
        case let .linkRepository(folder):
            blockers += folderBlockers(folder, choices: choices)
            if folder.kind != .gitRepository { blockers.append(.notARepository) }
            if input.gitInitConsent { blockers.append(.gitInitNotPossible) }
        }
        return blockers
    }

    private static func folderBlockers(_ folder: IndexedFolder, choices: FolderChoices) -> [NewProjectBlocker] {
        var blockers: [NewProjectBlocker] = []
        if !choices.folders.contains(where: { $0.id == folder.id }) { blockers.append(.folderNotSelectable) }
        if folder.projectId != nil { blockers.append(.folderAlreadyLinked) }
        return blockers
    }

    /// Builds project (pre-filled from the synced `GlobalSettings`) and command. Throws instead of
    /// producing an invalid command; the Mac validates again before touching the file system.
    public static func plan(
        _ input: NewProjectInput, choices: FolderChoices, globalSettings: GlobalSettings, device: DeviceID, now: Date
    ) throws(NewProjectError) -> NewProjectPlan {
        let blockers = blockers(input, choices: choices)
        guard blockers.isEmpty else { throw .blocked(blockers) }
        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let target: ProjectSetupTarget
        var scope: RepositoryScopeChoice?
        var initializeGit = false
        var hostId: HostID?
        var kind: RepositoryKind = .notARepository
        switch input.option {
        case .draft:
            target = .draftWithoutRepository
        case let .newSubfolder(parentPath, folderName):
            target = .newSubfolder(parentPath: parentPath, folderName: folderName)
            initializeGit = input.gitInitConsent
            hostId = choices.folders.first { $0.scanRootPath == parentPath || $0.canonicalPath == parentPath }?.hostId
        case let .existingFolder(folder, chosenScope):
            target = .indexedFolder(path: folder.canonicalPath)
            scope = folder.kind == .repositorySubfolder ? chosenScope : nil
            initializeGit = folder.kind == .plainFolder && input.gitInitConsent
            hostId = folder.hostId
            kind = folder.kind.repositoryKind ?? .notARepository
        case let .linkRepository(folder):
            target = .indexedFolder(path: folder.canonicalPath)
            hostId = folder.hostId
            kind = .gitRepository
        }
        let consent = initializeGit ? GitInitConsent(grantedBy: device, grantedAt: now) : nil
        let projectId = input.linkToProject ?? ProjectID()
        let command = ProjectSetupCommand(
            kind: input.linkToProject == nil ? .createProject : .linkProject, projectId: projectId, projectName: name,
            target: target, repositoryScope: scope, initializeGitRepository: initializeGit, gitInitConsent: consent,
            requestedBy: device, hostId: hostId, createdAt: now)
        do {
            try command.validateStructure()
        } catch {
            throw .blocked([.invalidFolderName])
        }
        guard input.linkToProject == nil else { return NewProjectPlan(project: nil, settings: nil, command: command) }
        let settings = globalSettings.makeProjectSettings(updatedAt: now)
        let project = Project(id: projectId, name: name, repositoryKind: kind, hostId: hostId, status: .pendingMacSetup,
                              settingsId: settings.id, createdAt: now)
        return NewProjectPlan(project: project, settings: settings, command: command)
    }
}

/// Stores a plan: the project (if new) and the command, both synced to the Mac (spec E2, N1).
public struct NewProjectSubmitter: Sendable {
    public let projects: any ProjectRepository
    public let commands: any ProjectSetupCommandRepository

    public init(projects: any ProjectRepository, commands: any ProjectSetupCommandRepository) {
        self.projects = projects
        self.commands = commands
    }

    public func submit(_ plan: NewProjectPlan, at date: Date) async throws {
        if let project = plan.project, let settings = plan.settings {
            try await projects.create(project, settings: settings, at: date)
        }
        try await commands.insert(plan.command, at: date)
    }
}

/// State of a setup command for the UI (spec E2: Projektstatus sichtbar).
public enum SetupCommandStatus: Hashable, Sendable {
    /// Waiting for the Mac (offline Mac: stays here; nothing happens on the iPhone).
    case waitingForMac
    case completed(path: String?)
    case failed(ProjectSetupFailure)

    public init(_ command: ProjectSetupCommand) {
        switch command.state {
        case .pending: self = .waitingForMac
        case .completed: self = .completed(path: command.resultPath)
        case .failed: self = .failed(command.failure ?? ProjectSetupFailure(.invalidCommand, ""))
        }
    }

    /// Latest command of a project.
    public static func latest(_ commands: [ProjectSetupCommand]) -> SetupCommandStatus? {
        commands.max { $0.createdAt < $1.createdAt }.map(SetupCommandStatus.init)
    }
}
