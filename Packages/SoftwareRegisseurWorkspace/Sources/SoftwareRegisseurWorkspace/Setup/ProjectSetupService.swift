import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurGit
import SoftwareRegisseurPersistence

/// Executes `CreateProject`/`LinkProject` commands on the Mac host (spec E2, A03):
/// validate (structure, canonical path inside an allowed root, no traversal, no symlinks, explicit scope
/// for repository subfolders, explicit consent for `git init`) → execute → project `ready`, or
/// `needsAttention` with a German reason. The iPhone never touches the file system.
public actor ProjectSetupService {
    let environment: WorkspaceEnvironment
    let catalog: ProjectCatalog

    public init(environment: WorkspaceEnvironment, catalog: ProjectCatalog) {
        self.environment = environment
        self.catalog = catalog
    }

    /// Stores a new command (iPhone or Mac UI) and the project in `pendingMacSetup` (spec E2).
    public func submit(_ command: ProjectSetupCommand) async throws {
        try command.validateStructure()
        let database = environment.database
        let now = environment.now()
        if command.kind == .createProject, try await database.projects.fetch(command.projectId) == nil {
            let settings = await environment.newProjectSettings(now)
            let project = Project(
                id: command.projectId, name: command.projectName, repositoryKind: .notARepository,
                status: .pendingMacSetup, settingsId: settings.id, createdAt: now
            )
            try await database.projects.create(project, settings: settings, at: now)
        }
        try await database.projectSetupCommands.insert(command, at: now)
    }

    /// Executes all pending commands. Failures are recorded on the command and the project.
    @discardableResult
    public func processPending() async throws -> [ProjectSetupCommand] {
        var results: [ProjectSetupCommand] = []
        for command in try await environment.database.projectSetupCommands.list(states: [.pending]) {
            results.append(try await execute(command.id))
        }
        return results
    }

    @discardableResult
    public func execute(_ id: ProjectSetupCommandID) async throws -> ProjectSetupCommand {
        let database = environment.database
        guard var command = try await database.projectSetupCommands.fetch(id) else {
            throw WorkspaceError.proposalNotFound(id.rawValue)
        }
        guard command.isPending else { return command }
        let base = command.revision
        let now = environment.now()
        do {
            let resultPath = try await perform(command)
            command.hostId = environment.hostId
            command.complete(resultPath: resultPath, at: now)
        } catch {
            command.hostId = environment.hostId
            command.fail(error, at: now)
            try await markNeedsAttention(command.projectId, reason: error.message)
        }
        try await database.projectSetupCommands.update(command, expectedRevision: base)
        return command
    }

    // MARK: Execution

    private func perform(_ command: ProjectSetupCommand) async throws(ProjectSetupFailure) -> String? {
        try command.validateStructure()
        let database = environment.database
        let now = environment.now()
        let project: Project
        do {
            if let existing = try await database.projects.fetch(command.projectId) {
                project = existing
            } else if command.kind == .linkProject {
                throw ProjectSetupFailure(.projectNotFound, String(localized: "Das zu verknüpfende Projekt existiert nicht.", bundle: .module))
            } else {
                let settings = await environment.newProjectSettings(now)
                let created = Project(id: command.projectId, name: command.projectName, repositoryKind: .notARepository,
                                      status: .pendingMacSetup, settingsId: settings.id, createdAt: now)
                try await database.projects.create(created, settings: settings, at: now)
                project = created
            }
        } catch let failure as ProjectSetupFailure {
            throw failure
        } catch {
            throw ProjectSetupFailure(.fileSystemError, String(localized: "Datenbankfehler: \(String(describing: error))", bundle: .module))
        }

        let guardRoots: PathGuard
        do {
            guardRoots = try await catalog.pathGuard()
        } catch {
            throw ProjectSetupFailure(.pathOutsideAllowedRoots, String(localized: "Am Mac sind keine gültigen Stammordner freigegeben.", bundle: .module))
        }

        switch command.target {
        case .draftWithoutRepository:
            try await update(project, kind: .notARepository, identity: nil, remote: nil, status: .pendingMacSetup,
                             reason: String(localized: "Entwurf ohne Ordner – später mit einem Ordner verknüpfen.", bundle: .module))
            return nil

        case let .newSubfolder(parentPath, folderName):
            let parent = try validatedExistingPath(parentPath, guard: guardRoots)
            let target: URL
            do {
                target = try guardRoots.validateNewSubfolder(named: folderName, in: parent)
            } catch {
                throw Self.failure(for: error, path: parentPath + "/" + folderName)
            }
            do {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            } catch {
                throw ProjectSetupFailure(.fileSystemError, String(localized: "Ordner konnte nicht angelegt werden: \(error.localizedDescription)", bundle: .module))
            }
            return try await finishFolder(target, project: project, command: command, scopeRoot: nil)

        case let .indexedFolder(path):
            let folder = try validatedExistingPath(path, guard: guardRoots)
            let canonicalPath = folder.path(percentEncoded: false).trimmingSlash
            let indexed: IndexedFolder?
            do {
                indexed = try await database.indexedFolders.fetch(hostId: environment.hostId, path: canonicalPath)
            } catch {
                throw ProjectSetupFailure(.fileSystemError, String(localized: "Datenbankfehler: \(String(describing: error))", bundle: .module))
            }
            guard let indexed, indexed.isAvailable else {
                throw ProjectSetupFailure(.folderNotIndexed, "Der Ordner ist am Mac nicht indiziert. Bitte zuerst neu scannen.")
            }
            switch indexed.kind {
            case .repositorySubfolder:
                guard let scope = command.repositoryScope else {
                    throw ProjectSetupFailure(.scopeChoiceRequired,
                                              String(localized: "Der Ordner liegt in einem Repository: bitte wählen, ob das ganze Repository oder nur der Unterordner gemeint ist.", bundle: .module))
                }
                if scope == .wholeRepository, let rootPath = indexed.repositoryRootPath {
                    let root = try validatedExistingPath(rootPath, guard: guardRoots)
                    return try await finishFolder(root, project: project, command: command, scopeRoot: nil)
                }
                return try await finishFolder(folder, project: project, command: command, scopeRoot: indexed.repositoryRootPath)
            case .bareRepository, .linkedWorktree, .submodule:
                throw ProjectSetupFailure(.invalidCommand, "Bare-Repositories, Worktrees und Submodule werden nicht als eigene Projekte angelegt.")
            case .gitRepository, .plainFolder:
                return try await finishFolder(folder, project: project, command: command, scopeRoot: nil)
            }
        }
    }

    /// Links `folder`; runs `git init` only with explicit consent (spec E2).
    private func finishFolder(_ folder: URL, project: Project, command: ProjectSetupCommand, scopeRoot: String?) async throws(ProjectSetupFailure) -> String {
        let database = environment.database
        let path = folder.path(percentEncoded: false).trimmingSlash
        do {
            if let other = try await database.projects.locations(hostId: environment.hostId).first(where: { $0.canonicalPath == path }),
               other.projectId != project.id {
                throw ProjectSetupFailure(.alreadyLinked, String(localized: "Der Ordner ist bereits mit einem anderen Projekt verknüpft.", bundle: .module))
            }
        } catch let failure as ProjectSetupFailure {
            throw failure
        } catch {
            throw ProjectSetupFailure(.fileSystemError, String(localized: "Datenbankfehler: \(String(describing: error))", bundle: .module))
        }

        let isRepository = FileSystem.exists(folder.appending(path: ".git"))
        if command.initializeGitRepository, scopeRoot == nil, !isRepository {
            guard command.gitInitConsent != nil else {
                throw ProjectSetupFailure(.gitInitConsentMissing, String(localized: "„git init“ wurde ohne ausdrückliche Zustimmung angefordert.", bundle: .module))
            }
            guard let git = environment.git else {
                throw ProjectSetupFailure(.gitInitFailed, String(localized: "Git ist auf diesem Mac nicht verfügbar.", bundle: .module))
            }
            do {
                try await RepositoryInitializer(git: git).initRepository(at: folder)
            } catch {
                throw ProjectSetupFailure(.gitInitFailed, "„git init“ fehlgeschlagen: \(error)")
            }
        }

        let kind: RepositoryKind
        var identity: DomainRepositoryIdentity?
        var remote: String?
        if scopeRoot != nil {
            kind = .subfolderOfRepository
        } else if FileSystem.exists(folder.appending(path: ".git")) {
            kind = .gitRepository
            if let git = environment.git, let info = try? await RepositoryInspector(git: git).inspect(folder) {
                identity = MarkdownDomainBridge.domain(info.identity)
                remote = (info.remotes.first { $0.name == "origin" } ?? info.remotes.first)?.fetchURL
            }
        } else {
            kind = .notARepository
        }
        if scopeRoot != nil, let root = scopeRoot, let git = environment.git,
           let info = try? await RepositoryInspector(git: git).inspect(URL(filePath: root, directoryHint: .isDirectory)) {
            // Subfolder projects share the repository identity, distinguished by their location.
            identity = MarkdownDomainBridge.domain(info.identity).flatMap { DomainRepositoryIdentity(rawValue: $0.rawValue + "#" + path) }
            remote = (info.remotes.first { $0.name == "origin" } ?? info.remotes.first)?.fetchURL
        }

        do {
            let now = environment.now()
            var location = try await database.projects.locations(projectId: project.id).first { $0.hostId == environment.hostId }
                ?? RepositoryLocation(projectId: project.id, hostId: environment.hostId, canonicalPath: path)
            location.canonicalPath = path
            location.scanState = .scanned
            location.lastScanAt = now
            try await database.projects.saveLocation(location, at: now)
            if var indexed = try await database.indexedFolders.fetch(hostId: environment.hostId, path: path) {
                indexed.projectId = project.id
                if kind == .gitRepository { indexed.kind = .gitRepository }
                try await database.indexedFolders.upsert(indexed)
            } else {
                try await database.indexedFolders.upsert(IndexedFolder(
                    hostId: environment.hostId, canonicalPath: path, displayName: folder.lastPathComponent,
                    kind: kind == .gitRepository ? .gitRepository : .plainFolder, scanRootPath: path, depth: 0,
                    projectId: project.id, repositoryIdentity: identity, remote: remote, isSelectable: true, lastSeenAt: now
                ))
            }
        } catch {
            throw ProjectSetupFailure(.fileSystemError, String(localized: "Datenbankfehler: \(String(describing: error))", bundle: .module))
        }
        try await update(project, kind: kind, identity: identity, remote: remote, status: .ready, reason: nil)
        return path
    }

    private func update(
        _ project: Project, kind: RepositoryKind, identity: DomainRepositoryIdentity?, remote: String?,
        status: ProjectStatus, reason: String?
    ) async throws(ProjectSetupFailure) {
        do {
            guard var current = try await environment.database.projects.fetch(project.id) else {
                throw ProjectSetupFailure(.projectNotFound, String(localized: "Projekt nicht gefunden.", bundle: .module))
            }
            let base = current.revision
            current.repositoryKind = kind
            current.repositoryIdentity = identity ?? current.repositoryIdentity
            current.remote = remote ?? current.remote
            current.hostId = environment.hostId
            try current.transition(to: status, reason: reason, at: environment.now())
            _ = try await environment.database.projects.update(current, expectedRevision: base, at: environment.now())
        } catch let failure as ProjectSetupFailure {
            throw failure
        } catch {
            throw ProjectSetupFailure(.fileSystemError, String(localized: "Projekt konnte nicht aktualisiert werden: \(String(describing: error))", bundle: .module))
        }
    }

    private func markNeedsAttention(_ projectId: ProjectID, reason: String) async throws {
        guard var project = try await environment.database.projects.fetch(projectId) else { return }
        let base = project.revision
        try project.transition(to: .needsAttention, reason: reason, at: environment.now())
        if project.revision != base {
            _ = try await environment.database.projects.update(project, expectedRevision: base, at: environment.now())
        }
    }

    /// Canonicalizes `path` and rejects traversal, symlinks and paths outside the allowed roots.
    private func validatedExistingPath(_ path: String, guard pathGuard: PathGuard) throws(ProjectSetupFailure) -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        if components.contains("..") || components.contains(".") {
            throw ProjectSetupFailure(.pathTraversal, String(localized: "Pfade mit „..“ oder „.“ sind nicht erlaubt.", bundle: .module))
        }
        let requested = URL(filePath: path, directoryHint: .isDirectory)
        let canonical: URL
        do {
            canonical = try pathGuard.validate(requested)
        } catch {
            throw Self.failure(for: error, path: path)
        }
        let canonicalPath = canonical.path(percentEncoded: false).trimmingSlash
        // Any symlink in the requested path (or the folder itself being a link) is rejected.
        // (No `standardizedFileURL`: it rewrites `/private/var` to `/var`.)
        let normalized = "/" + path.split(separator: "/").joined(separator: "/")
        if canonicalPath != normalized || Self.containsSymlink(path) {
            throw ProjectSetupFailure(.symlinkNotAllowed, "Symbolische Links sind als Projektpfad nicht erlaubt.")
        }
        guard FileSystem.isDirectory(canonical) else {
            throw ProjectSetupFailure(.folderNotFound, "Der Ordner existiert nicht.")
        }
        return canonical
    }

    static func containsSymlink(_ path: String) -> Bool {
        var current = ""
        for component in path.split(separator: "/") {
            current += "/" + component
            var info = stat()
            if lstat(current, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK { return true }
        }
        return false
    }

    static func failure(for error: any Error, path: String) -> ProjectSetupFailure {
        guard let error = error as? PathGuardError else {
            return ProjectSetupFailure(.fileSystemError, String(localized: "Pfad konnte nicht geprüft werden: \(path)", bundle: .module))
        }
        switch error {
        case .outsideAllowedRoots, .relativePath, .notAFileURL:
            return ProjectSetupFailure(.pathOutsideAllowedRoots, String(localized: "Der Pfad liegt außerhalb der freigegebenen Stammordner.", bundle: .module))
        case .traversal:
            return ProjectSetupFailure(.pathTraversal, String(localized: "Pfade mit „..“ sind nicht erlaubt.", bundle: .module))
        case .danglingSymlink:
            return ProjectSetupFailure(.symlinkNotAllowed, String(localized: "Symbolische Links sind als Projektpfad nicht erlaubt.", bundle: .module))
        case .alreadyExists:
            return ProjectSetupFailure(.folderAlreadyExists, String(localized: "Ein Ordner mit diesem Namen existiert bereits.", bundle: .module))
        case let .invalidFolderName(name, reason):
            return ProjectSetupFailure(.invalidFolderName, String(localized: "Der Ordnername „\(name)“ ist nicht zulässig (\(reason.rawValue)).", bundle: .module))
        case .parentNotFound, .rootNotFound, .unresolvable:
            return ProjectSetupFailure(.folderNotFound, String(localized: "Der Ordner existiert nicht.", bundle: .module))
        case .invalidCharacters:
            return ProjectSetupFailure(.invalidFolderName, String(localized: "Der Pfad enthält ungültige Zeichen.", bundle: .module))
        }
    }
}
