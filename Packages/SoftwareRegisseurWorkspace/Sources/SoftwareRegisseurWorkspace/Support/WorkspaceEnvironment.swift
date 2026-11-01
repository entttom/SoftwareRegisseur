import Darwin
import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurGit
import SoftwareRegisseurMarkdown
import SoftwareRegisseurPersistence

/// Errors of the workspace layer. Messages for the UI are German (spec P).
public enum WorkspaceError: Error, Hashable, Sendable, CustomStringConvertible {
    case projectNotFound(ProjectID)
    case projectHasNoLocation(ProjectID)
    case projectFolderMissing(String)
    case workItemNotFound(WorkItemID)
    case workItemWithoutProject(WorkItemID)
    case invalidLayout(String)
    /// Destination exists and is not the file being written/moved (never overwritten).
    case collision(path: String)
    /// File changed between reading and writing.
    case fileChangedConcurrently(path: String)
    case fileNotFound(path: String)
    case invalidRequestFile(path: String, detail: String)
    case pathOutsideRepository(String)
    case openConflict(FileConflictID)
    case conflictNotFound(FileConflictID)
    case activeJob(WorkItemID)
    case proposalNotFound(UUID)
    case staleProposal(path: String)
    case notApproved
    case planHasCollisions
    case instructionsDisabled
    case identityMismatch(expected: String, found: String)
    case alreadyLinked(path: String, projectId: ProjectID)
    case pathRejected(String)
    case ioError(String)

    public var description: String {
        switch self {
        case let .projectNotFound(id): String(localized: "Projekt \(id) nicht gefunden.", bundle: .module)
        case let .projectHasNoLocation(id): String(localized: "Projekt \(id) hat auf diesem Mac keinen Ordner.", bundle: .module)
        case let .projectFolderMissing(path): String(localized: "Projektordner fehlt: \(path)", bundle: .module)
        case let .workItemNotFound(id): String(localized: "Aufgabe \(id) nicht gefunden.", bundle: .module)
        case let .workItemWithoutProject(id): String(localized: "Aufgabe \(id) ist keinem Projekt zugeordnet.", bundle: .module)
        case let .invalidLayout(detail): String(localized: "Ungültige Ordnerstruktur: \(detail)", bundle: .module)
        case let .collision(path): String(localized: "Ziel existiert bereits und wird nicht überschrieben: \(path)", bundle: .module)
        case let .fileChangedConcurrently(path): String(localized: "Datei wurde zwischenzeitlich geändert: \(path)", bundle: .module)
        case let .fileNotFound(path): String(localized: "Datei nicht gefunden: \(path)", bundle: .module)
        case let .invalidRequestFile(path, detail): String(localized: "Ungültige Request-Datei \(path): \(detail)", bundle: .module)
        case let .pathOutsideRepository(path): String(localized: "Pfad liegt außerhalb des Repositorys: \(path)", bundle: .module)
        case let .openConflict(id): String(localized: "Offener Konflikt \(id) muss zuerst gelöst werden.", bundle: .module)
        case let .conflictNotFound(id): String(localized: "Konflikt \(id) nicht gefunden.", bundle: .module)
        case let .activeJob(id): String(localized: "Aufgabe \(id) hat einen aktiven Agentenlauf.", bundle: .module)
        case let .proposalNotFound(id): String(localized: "Vorschlag \(id) nicht gefunden oder bereits angewendet.", bundle: .module)
        case let .staleProposal(path): String(localized: "\(path) wurde seit dem Vorschlag geändert; bitte neu erzeugen.", bundle: .module)
        case .notApproved: String(localized: "Ausdrückliche Freigabe fehlt.", bundle: .module)
        case .planHasCollisions: String(localized: "Der Migrationsplan enthält Kollisionen.", bundle: .module)
        case .instructionsDisabled: String(localized: "Agentenanweisungen sind für dieses Projekt deaktiviert.", bundle: .module)
        case let .identityMismatch(expected, found): String(localized: "Anderes Repository (erwartet \(expected), gefunden \(found)).", bundle: .module)
        case let .alreadyLinked(path, projectId): String(localized: "\(path) ist bereits mit Projekt \(projectId) verknüpft.", bundle: .module)
        case let .pathRejected(detail): String(localized: "Pfad abgelehnt: \(detail)", bundle: .module)
        case let .ioError(detail): String(localized: "Dateifehler: \(detail)", bundle: .module)
        }
    }
}

/// Shared dependencies of the workspace services on the Mac host.
public struct WorkspaceEnvironment: Sendable {
    public let database: AppDatabase
    public let hostId: HostID
    /// `nil` disables git-specific behaviour (moves fall back to rename, no status warnings).
    public let git: GitClient?
    public var timeZone: TimeZone
    public var now: @Sendable () -> Date
    /// Global default folder layout for projects without own settings (spec F2, ADR-0004).
    public var defaultSettings: @Sendable (Date) -> ProjectSettings

    public init(
        database: AppDatabase,
        hostId: HostID,
        git: GitClient? = try? GitClient.locate(),
        timeZone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = { Date() },
        defaultSettings: @escaping @Sendable (Date) -> ProjectSettings = { ProjectSettings(updatedAt: $0) }
    ) {
        self.database = database
        self.hostId = hostId
        self.git = git
        self.timeZone = timeZone
        self.now = now
        self.defaultSettings = defaultSettings
    }

    /// Canonical project folder on this host.
    public func projectRoot(_ projectId: ProjectID) async throws -> URL {
        let locations = try await database.projects.locations(projectId: projectId)
        guard let location = locations.first(where: { $0.hostId == hostId }) else {
            throw WorkspaceError.projectHasNoLocation(projectId)
        }
        let url = URL(filePath: location.canonicalPath, directoryHint: .isDirectory)
        guard FileSystem.isDirectory(url) else { throw WorkspaceError.projectFolderMissing(location.canonicalPath) }
        return url
    }

    /// Settings for a project the host creates: the synced user-wide defaults (spec F2, `GlobalSettings`)
    /// once the user saved them, otherwise `defaultSettings`.
    public func newProjectSettings(_ now: Date) async -> ProjectSettings {
        if let global = try? await database.globalSettings.fetch(), global.isStored {
            return global.makeProjectSettings(updatedAt: now)
        }
        return defaultSettings(now)
    }

    public func settings(_ projectId: ProjectID) async throws -> ProjectSettings {
        try await database.projects.settings(forProject: projectId) ?? defaultSettings(now())
    }

    public func layout(_ projectId: ProjectID) async throws -> FolderLayout {
        do {
            return try MarkdownDomainBridge.folderLayout(try await settings(projectId))
        } catch let error as BridgeError {
            throw WorkspaceError.invalidLayout("\(error)")
        }
    }

    /// Repository-relative document folders of the effective layout that Software Regisseur maintains
    /// itself and never commits (ADR-0024): the ADR folder and the requests root – or, when the requests
    /// root is the repository root, its request folders, so the set never covers the whole repository.
    public func documentPaths(_ projectId: ProjectID) async throws -> [String] {
        Self.documentPaths(try await layout(projectId))
    }

    public static func documentPaths(_ layout: FolderLayout) -> [String] {
        let requests = layout.requestsRoot.isRoot ? layout.requestFolders : [layout.requestsRoot]
        var result: [String] = []
        for path in [layout.adrPath] + requests where !path.isRoot && !result.contains(path.string) {
            result.append(path.string)
        }
        return result
    }
}

// MARK: - File system helpers

enum FileSystem {
    static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path(percentEncoded: false), &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path(percentEncoded: false), &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG
    }

    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path(percentEncoded: false), &info) == 0
    }

    static func read(_ url: URL) -> Data? {
        guard isRegularFile(url) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Real path (symlinks resolved), or the standardized path if it does not exist.
    static func realPath(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        guard let resolved = realpath(path, nil) else { return path.trimmingSlash }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Repository-relative path of `url` below `root`, nil if outside.
    static func relativePath(of url: URL, in root: URL) -> String? {
        let rootPath = realPath(root)
        let path = url.path(percentEncoded: false).trimmingSlash
        let resolvedPath = path.hasPrefix(rootPath + "/") ? path : realPath(url)
        guard resolvedPath.hasPrefix(rootPath + "/") else { return nil }
        return String(resolvedPath.dropFirst(rootPath.count + 1))
    }

    // MARK: Confinement below a repository root (SR-SEC-07)

    /// First path component of `url` below `root` that is a symbolic link (or `url` itself when it is
    /// not lexically below `root`); nil when every existing component below the root is a real file or
    /// directory. Components above `root` (e.g. `/var` → `/private/var`) are not checked: the root is
    /// the user-approved repository folder. Components that do not exist yet are fine.
    static func symlinkComponent(of url: URL, below root: URL) -> String? {
        let rootPath = root.path(percentEncoded: false).trimmingSlash
        let path = url.path(percentEncoded: false).trimmingSlash
        guard path == rootPath || path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/") else { return path }
        var current = rootPath
        for component in path.dropFirst(rootPath.count).split(separator: "/") {
            guard component != "..", component != "." else { return path }
            current += (current.hasSuffix("/") ? "" : "/") + component
            var info = stat()
            guard lstat(current, &info) == 0 else { return nil }
            if (info.st_mode & S_IFMT) == S_IFLNK { return current }
        }
        return nil
    }

    /// Throws `pathOutsideRepository` when `url` leaves `root` through a symbolic link.
    static func requireConfined(_ url: URL, below root: URL) throws {
        if let component = symlinkComponent(of: url, below: root) {
            throw WorkspaceError.pathOutsideRepository(component)
        }
    }

    /// Regular file `relative` below `root`, read without following symbolic links in any component.
    static func read(_ relative: String, in root: URL) -> Data? {
        read(root.appendingRelative(relative), below: root)
    }

    /// Regular file `url` below `root`, read without following symbolic links in any component.
    static func read(_ url: URL, below root: URL) -> Data? {
        guard symlinkComponent(of: url, below: root) == nil else { return nil }
        let fd = open(url.path(percentEncoded: false), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return try? handle.readToEnd() ?? Data()
    }

    /// Creates the missing directories of `directory` below `root` one by one, refusing symbolic links
    /// (unlike `createDirectory(withIntermediateDirectories:)`, which follows them).
    static func createDirectories(_ directory: URL, below root: URL) throws {
        try requireConfined(directory, below: root)
        let rootPath = root.path(percentEncoded: false).trimmingSlash
        let path = directory.path(percentEncoded: false).trimmingSlash
        var current = rootPath
        for component in path.dropFirst(rootPath.count).split(separator: "/") {
            guard component != "..", component != "." else { throw WorkspaceError.pathOutsideRepository(path) }
            current += (current.hasSuffix("/") ? "" : "/") + component
            if mkdir(current, 0o755) != 0, errno != EEXIST {
                throw WorkspaceError.ioError("mkdir \(current): \(String(cString: strerror(errno)))")
            }
            var info = stat()
            guard lstat(current, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
                throw WorkspaceError.pathOutsideRepository(current)
            }
        }
    }

    /// Markdown files below `directory` (recursive, no symlinks, no hidden entries), as relative paths.
    /// Nothing is returned when `directory` itself is reached through a symbolic link below `root`.
    static func markdownFiles(in directory: URL, relativeTo root: URL, recursive: Bool = true) -> [String] {
        guard isDirectory(directory), symlinkComponent(of: directory, below: root) == nil else { return [] }
        var result: [String] = []
        var stack: [URL] = [directory]
        while let current = stack.popLast() {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: current, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries {
                let values = try? entry.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
                if values?.isSymbolicLink == true { continue }
                if values?.isDirectory == true {
                    if recursive { stack.append(entry) }
                } else if values?.isRegularFile == true, entry.pathExtension.lowercased() == "md",
                          let relative = relativePath(of: entry, in: root) {
                    result.append(relative)
                }
            }
        }
        return result.sorted()
    }
}

extension String {
    var trimmingSlash: String {
        var value = self
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value
    }
}

extension URL {
    func appendingRelative(_ relative: String) -> URL {
        relative == "." || relative.isEmpty ? self : appending(path: relative, directoryHint: .inferFromPath)
    }
}
