import Darwin
import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurGit
import SoftwareRegisseurPersistence

/// Root folders and scan rules configured on the Mac (spec E1).
public struct CatalogConfiguration: Sendable, Hashable {
    public var roots: [URL]
    public var options: ScanOptions
    /// Repository subfolders deeper than this (below the repository root) are indexed but not offered.
    public var maxSelectableSubfolderDepth: Int

    public init(roots: [URL], options: ScanOptions = ScanOptions(), maxSelectableSubfolderDepth: Int = 2) {
        self.roots = roots
        self.options = options
        self.maxSelectableSubfolderDepth = maxSelectableSubfolderDepth
    }
}

public struct CatalogScanReport: Sendable, Hashable {
    public var createdProjects: [ProjectID] = []
    public var updatedProjects: [ProjectID] = []
    /// Projects whose folder moved on the same volume (recognised by the git dir's device/inode).
    public var movedProjects: [ProjectID: String] = [:]
    public var unavailableProjects: [ProjectID] = []
    /// Unavailable projects → paths of folders with the same repository identity (relink workflow).
    public var relinkCandidates: [ProjectID: [String]] = [:]
    public var indexedFolderCount = 0
    public var issues: [String] = []
    public var statistics: ScanStatistics?
}

/// Project catalog of the Mac host (spec E1–E3): scans the configured root folders incrementally, keeps
/// projects and repository locations up to date, offers selectable folders for the iPhone (E2) and never
/// deletes data when folders move or disappear (relink workflow).
public actor ProjectCatalog {
    static let stateScope = "catalog"
    static let cacheKey = "scanCache"

    let environment: WorkspaceEnvironment
    public private(set) var configuration: CatalogConfiguration

    public init(environment: WorkspaceEnvironment, configuration: CatalogConfiguration) {
        self.environment = environment
        self.configuration = configuration
    }

    public func configure(_ configuration: CatalogConfiguration) {
        self.configuration = configuration
    }

    /// Path guard for the configured roots (spec E2 path validation).
    public func pathGuard() throws -> PathGuard {
        do {
            return try PathGuard(allowedRoots: configuration.roots)
        } catch {
            throw WorkspaceError.pathRejected("\(error)")
        }
    }

    // MARK: Scan

    public func scan() async throws -> CatalogScanReport {
        let database = environment.database
        let hostId = environment.hostId
        let now = environment.now()
        var report = CatalogScanReport()

        let cache: ScanCache = (try? await database.hostState.value(scope: Self.stateScope, key: Self.cacheKey))
            .flatMap { try? JSONDecoder().decode(ScanCache.self, from: $0) } ?? ScanCache()
        let scanner = RepositoryScanner(options: configuration.options, cache: cache)
        let result = try await scanner.scan(roots: configuration.roots)
        if let data = try? JSONEncoder().encode(await scanner.cache) {
            try await database.hostState.setValue(data, scope: Self.stateScope, key: Self.cacheKey, at: now)
        }
        report.statistics = result.statistics
        report.issues = result.issues.map { "\($0.url.path(percentEncoded: false)): \($0.message)" }

        var locationsByPath: [String: RepositoryLocation] = [:]
        for location in try await database.projects.locations(hostId: hostId) {
            locationsByPath[location.canonicalPath] = location
        }
        let previousFolders = try await database.indexedFolders.list(hostId: hostId)
        let inspector = environment.git.map(RepositoryInspector.init(git:))
        var seenPaths = Set<String>()
        var claimedProjects = Set<ProjectID>()

        // Main repositories → projects.
        for repository in result.repositories where !repository.isBare {
            let path = repository.rootURL.path(percentEncoded: false).trimmingSlash
            seenPaths.insert(path)
            let info = try? await inspector?.inspect(repository.rootURL)
            let identity = info.flatMap { MarkdownDomainBridge.domain($0.identity) }
            let fingerprint = Self.fingerprint(of: repository.gitDirectoryURL)
            let remote = info.flatMap { info in
                (info.remotes.first { $0.name == "origin" } ?? info.remotes.first)?.fetchURL
            }

            var projectId: ProjectID?
            if let location = locationsByPath[path] {
                projectId = location.projectId
                try await refresh(location.projectId, identity: identity, remote: remote, report: &report)
                try await saveLocation(projectId: location.projectId, path: path, previous: location)
            } else if let moved = previousFolders.first(where: {
                $0.kind == .gitRepository && $0.projectId != nil && $0.fileSystemFingerprint == fingerprint
                    && $0.canonicalPath != path && !FileSystem.exists(URL(filePath: $0.canonicalPath))
            }), let movedProject = moved.projectId {
                projectId = movedProject
                let previous = try await database.projects.locations(projectId: movedProject).first { $0.hostId == hostId }
                try await saveLocation(projectId: movedProject, path: path, previous: previous)
                try await refresh(movedProject, identity: identity, remote: remote, report: &report)
                report.movedProjects[movedProject] = path
                locationsByPath[path] = RepositoryLocation(projectId: movedProject, hostId: hostId, canonicalPath: path)
                if let old = previous?.canonicalPath { locationsByPath[old] = nil }
            } else if let identity, let waiting = try await unavailableProject(with: identity, locations: locationsByPath) {
                // Same repository identity as a project whose folder is missing: offer relink, never auto-duplicate.
                report.relinkCandidates[waiting, default: []].append(path)
            } else {
                let settings = await environment.newProjectSettings(now)
                let project = Project(
                    name: repository.rootURL.lastPathComponent, repositoryIdentity: identity, repositoryKind: .gitRepository,
                    remote: remote, hostId: hostId, status: .ready, settingsId: settings.id, createdAt: now
                )
                try await database.projects.create(project, settings: settings, at: now)
                try await saveLocation(projectId: project.id, path: path, previous: nil)
                locationsByPath[path] = RepositoryLocation(projectId: project.id, hostId: hostId, canonicalPath: path)
                projectId = project.id
                report.createdProjects.append(project.id)
            }
            if let projectId { claimedProjects.insert(projectId) }

            var settings = environment.defaultSettings(now)
            if let projectId { settings = try await environment.settings(projectId) }
            try await database.indexedFolders.upsert(IndexedFolder(
                hostId: hostId, canonicalPath: path, displayName: repository.rootURL.lastPathComponent, kind: .gitRepository,
                repositoryRootPath: repository.enclosingRepositoryURL?.path(percentEncoded: false).trimmingSlash,
                scanRootPath: Self.scanRoot(of: path, in: result) ?? path, depth: Self.depth(of: path, in: result),
                projectId: projectId, repositoryIdentity: identity, defaultBranch: info?.defaultBranch, remote: remote,
                fileSystemFingerprint: fingerprint,
                documents: Self.detectDocuments(at: repository.rootURL, settings: settings),
                isSelectable: true, lastSeenAt: now
            ))
        }

        // All other directories: worktrees/submodules attached, plain folders and subfolders selectable (E2).
        for directory in result.directories {
            let path = directory.url.path(percentEncoded: false).trimmingSlash
            guard !seenPaths.contains(path) else { continue }
            seenPaths.insert(path)
            let kind: IndexedFolderKind
            var selectable = false
            switch directory.kind {
            case .repositoryRoot: continue // handled above (bare or main)
            case .bareRepository: kind = .bareRepository
            case .linkedWorktree: kind = .linkedWorktree
            case .submodule: kind = .submodule
            case .plainFolder:
                kind = .plainFolder
                selectable = directory.depth >= 1
            case .repositorySubfolder:
                kind = .repositorySubfolder
                let repoDepth = directory.owningRepositoryURL.map {
                    Self.relativeDepth(path, below: $0.path(percentEncoded: false).trimmingSlash)
                } ?? Int.max
                selectable = repoDepth <= configuration.maxSelectableSubfolderDepth
            }
            let projectId = locationsByPath[path]?.projectId
            if let projectId {
                claimedProjects.insert(projectId)
                if let location = locationsByPath[path] { try await saveLocation(projectId: projectId, path: path, previous: location) }
                try await refresh(projectId, identity: nil, remote: nil, report: &report)
            }
            try await database.indexedFolders.upsert(IndexedFolder(
                hostId: hostId, canonicalPath: path, displayName: directory.url.lastPathComponent, kind: kind,
                repositoryRootPath: directory.owningRepositoryURL?.path(percentEncoded: false).trimmingSlash,
                scanRootPath: directory.scanRoot.path(percentEncoded: false).trimmingSlash, depth: directory.depth,
                projectId: projectId, isSelectable: selectable, lastSeenAt: now
            ))
        }

        // Missing folders: mark unavailable, never delete (spec E1 relink workflow).
        for (path, location) in locationsByPath where !claimedProjects.contains(location.projectId) {
            guard !FileSystem.isDirectory(URL(filePath: path)) else { continue }
            guard var project = try await database.projects.fetch(location.projectId) else { continue }
            if project.status != .unavailable, project.status != .archived {
                let base = project.revision
                try project.transition(to: .unavailable, reason: String(localized: "Ordner nicht gefunden: \(path)", bundle: .module), at: now)
                _ = try await database.projects.update(project, expectedRevision: base, at: now)
            }
            var updated = location
            updated.scanState = .unreachable
            updated.lastScanAt = now
            try await database.projects.saveLocation(updated, at: now)
            report.unavailableProjects.append(project.id)
        }
        for folder in previousFolders where !seenPaths.contains(folder.canonicalPath) {
            if FileSystem.isDirectory(URL(filePath: folder.canonicalPath)), folder.projectId == nil {
                try await database.indexedFolders.delete(hostId: hostId, path: folder.canonicalPath) // now excluded
            } else if folder.isAvailable, !FileSystem.isDirectory(URL(filePath: folder.canonicalPath)) {
                var missing = folder
                missing.isAvailable = false
                missing.isSelectable = false
                try await database.indexedFolders.upsert(missing)
            }
        }
        report.indexedFolderCount = try await database.indexedFolders.list(hostId: hostId).count(where: \.isAvailable)
        return report
    }

    // MARK: Queries

    /// Folders the iPhone may choose for a new project (spec E2).
    public func selectableFolders() async throws -> [IndexedFolder] {
        try await environment.database.indexedFolders.list(hostId: environment.hostId).filter { $0.isSelectable && $0.isAvailable }
    }

    /// Indexed folders that could be the new location of a (missing) project.
    public func relinkCandidates(projectId: ProjectID) async throws -> [IndexedFolder] {
        guard let project = try await environment.database.projects.fetch(projectId) else { throw WorkspaceError.projectNotFound(projectId) }
        let folders = try await environment.database.indexedFolders.list(hostId: environment.hostId)
            .filter { $0.isAvailable && $0.kind == .gitRepository && $0.projectId == nil }
        if let identity = project.repositoryIdentity {
            let matches = folders.filter { $0.repositoryIdentity == identity }
            if !matches.isEmpty { return matches }
        }
        return folders.filter { $0.displayName.caseInsensitiveCompare(project.name) == .orderedSame }
    }

    /// Re-links a project to a folder (spec E1 relink workflow). A different repository identity requires
    /// `allowDifferentRepository` (explicit user confirmation).
    @discardableResult
    public func relink(projectId: ProjectID, to url: URL, allowDifferentRepository: Bool = false) async throws -> Project {
        let database = environment.database
        let now = environment.now()
        guard var project = try await database.projects.fetch(projectId) else { throw WorkspaceError.projectNotFound(projectId) }
        let canonical: URL
        do {
            canonical = try pathGuard().validate(url)
        } catch let error as WorkspaceError {
            throw error
        } catch {
            throw WorkspaceError.pathRejected("\(error)")
        }
        let path = canonical.path(percentEncoded: false).trimmingSlash
        guard FileSystem.isDirectory(canonical) else { throw WorkspaceError.projectFolderMissing(path) }
        if let other = try await database.projects.locations(hostId: environment.hostId).first(where: { $0.canonicalPath == path }),
           other.projectId != projectId {
            throw WorkspaceError.alreadyLinked(path: path, projectId: other.projectId)
        }
        if let expected = project.repositoryIdentity, !expected.rawValue.hasPrefix("provisional:"), let git = environment.git {
            let found = try? await RepositoryInspector(git: git).identity(of: canonical)
            if found?.value != expected.rawValue, !allowDifferentRepository {
                throw WorkspaceError.identityMismatch(expected: expected.rawValue, found: found?.value ?? "kein Git-Repository")
            }
        }
        let previous = try await database.projects.locations(projectId: projectId).first { $0.hostId == environment.hostId }
        try await saveLocation(projectId: projectId, path: path, previous: previous)
        let base = project.revision
        try project.transition(to: .ready, reason: nil, at: now)
        project.hostId = environment.hostId
        if project.revision != base {
            project = try await database.projects.update(project, expectedRevision: base, at: now)
        }
        if var folder = try await database.indexedFolders.fetch(hostId: environment.hostId, path: path) {
            folder.projectId = projectId
            try await database.indexedFolders.upsert(folder)
        }
        return project
    }

    // MARK: Helpers

    private func refresh(_ projectId: ProjectID, identity: DomainRepositoryIdentity?, remote: String?, report: inout CatalogScanReport) async throws {
        let database = environment.database
        guard var project = try await database.projects.fetch(projectId) else { return }
        let base = project.revision
        if let identity, project.repositoryIdentity != identity {
            project.repositoryIdentity = identity // e.g. provisional → first commit
        }
        if let remote, project.remote != remote { project.remote = remote }
        if project.status == .unavailable {
            try project.transition(to: .ready, reason: nil, at: environment.now())
        }
        guard project != (try await database.projects.fetch(projectId)) else { return }
        _ = try await database.projects.update(project, expectedRevision: base, at: environment.now())
        report.updatedProjects.append(projectId)
    }

    private func saveLocation(projectId: ProjectID, path: String, previous: RepositoryLocation?) async throws {
        var location = previous ?? RepositoryLocation(projectId: projectId, hostId: environment.hostId, canonicalPath: path)
        location.canonicalPath = path
        location.scanState = .scanned
        location.lastScanAt = environment.now()
        guard location != previous else { return }
        try await environment.database.projects.saveLocation(location, at: environment.now())
    }

    private func unavailableProject(with identity: DomainRepositoryIdentity, locations: [String: RepositoryLocation]) async throws -> ProjectID? {
        for project in try await environment.database.projects.fetch(repositoryIdentity: identity) {
            let paths = locations.filter { $0.value.projectId == project.id }.map(\.key)
            if paths.isEmpty || paths.allSatisfy({ !FileSystem.isDirectory(URL(filePath: $0)) }) {
                if !paths.isEmpty || project.status == .unavailable { return project.id }
            }
        }
        return nil
    }

    static func fingerprint(of gitDirectory: URL) -> String? {
        var info = stat()
        guard stat(gitDirectory.path(percentEncoded: false), &info) == 0 else { return nil }
        return "\(info.st_dev)-\(info.st_ino)"
    }

    static func scanRoot(of path: String, in result: ScanResult) -> String? {
        result.directories.first { $0.url.path(percentEncoded: false).trimmingSlash == path }?.scanRoot.path(percentEncoded: false).trimmingSlash
    }

    static func depth(of path: String, in result: ScanResult) -> Int {
        result.directories.first { $0.url.path(percentEncoded: false).trimmingSlash == path }?.depth ?? 0
    }

    static func relativeDepth(_ path: String, below root: String) -> Int {
        guard path.hasPrefix(root + "/") else { return 0 }
        return path.dropFirst(root.count + 1).split(separator: "/").count
    }

    /// Existing AGENTS.md / CLAUDE.md / README / ADR / request folders (spec E3).
    public static func detectDocuments(at root: URL, settings: ProjectSettings) -> DetectedProjectDocuments {
        var documents = DetectedProjectDocuments()
        documents.hasAgentsFile = FileSystem.isRegularFile(root.appendingRelative("AGENTS.md"))
        documents.hasClaudeFile = FileSystem.isRegularFile(root.appendingRelative("CLAUDE.md"))
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? []
        documents.readmeFiles = entries.filter { $0.lowercased().hasPrefix("readme") }.sorted()
        for candidate in [settings.adrPath, "docs/adr", "doc/adr", "docs/decisions", "docs/architecture/decisions", "adr"]
        where FileSystem.isDirectory(root.appendingRelative(candidate)) {
            documents.adrFolder = candidate
            documents.adrFileCount = FileSystem.markdownFiles(in: root.appendingRelative(candidate), relativeTo: root, recursive: false)
                .filter { !ADRImporter.ignoredFileNames.contains(($0 as NSString).lastPathComponent.lowercased()) }.count
            break
        }
        for candidate in [settings.requestsRoot, "docs/requests", "requests"] where FileSystem.isDirectory(root.appendingRelative(candidate)) {
            documents.requestsFolder = candidate
            documents.requestFileCount = FileSystem.markdownFiles(in: root.appendingRelative(candidate), relativeTo: root).count
            break
        }
        return documents
    }
}
