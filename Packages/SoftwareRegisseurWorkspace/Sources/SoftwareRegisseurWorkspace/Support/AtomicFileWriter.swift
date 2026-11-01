import Darwin
import Foundation
import SoftwareRegisseurGit
import SoftwareRegisseurPersistence

/// Atomic file writes (temp file in the same directory + rename, spec G rule 3 / F3) that never
/// overwrite unrelated files.
public enum AtomicFileWriter {
    /// Prefix of temporary files; the watcher ignores them.
    public static let temporaryPrefix = ".sr-tmp-"

    public enum Mode: Sendable, Hashable {
        /// Fails with `collision` if the destination exists (exclusive rename).
        case createNew
        /// Replaces the destination only if its current content hash equals `expectedHash`
        /// (`nil` = destination must not exist).
        case replace(expectedHash: String?)
    }

    /// - Parameter root: Repository folder the file must stay in (SR-SEC-07). When given, no component
    ///   below it may be a symbolic link, and missing directories are created without following links.
    public static func write(_ data: Data, to url: URL, mode: Mode, confinedTo root: URL? = nil) throws {
        let directory = url.deletingLastPathComponent()
        if let root {
            try FileSystem.requireConfined(url, below: root)
            if !FileSystem.isDirectory(directory) { try FileSystem.createDirectories(directory, below: root) }
            try FileSystem.requireConfined(url, below: root)
        } else if !FileSystem.isDirectory(directory) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw WorkspaceError.ioError(error.localizedDescription)
            }
        }
        let destination = url.path(percentEncoded: false)
        let temporary = directory.appending(path: temporaryPrefix + UUID().uuidString, directoryHint: .notDirectory)
        let temporaryPath = temporary.path(percentEncoded: false)

        var permissions: mode_t = 0o644
        var info = stat()
        if lstat(destination, &info) == 0 {
            if (info.st_mode & S_IFMT) == S_IFLNK { throw WorkspaceError.collision(path: destination) }
            permissions = info.st_mode & 0o777
        }

        let fd = open(temporaryPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, permissions)
        guard fd >= 0 else { throw WorkspaceError.ioError("open \(temporaryPath): \(String(cString: strerror(errno)))") }
        var success = false
        defer {
            if !success { unlink(temporaryPath) }
        }
        let written = data.withUnsafeBytes { buffer -> Int in
            var offset = 0
            while offset < buffer.count {
                let result = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if result < 0 {
                    if errno == EINTR { continue }
                    return -1
                }
                offset += result
            }
            return offset
        }
        let synced = fsync(fd) == 0
        close(fd)
        guard written == data.count, synced else { throw WorkspaceError.ioError("write \(temporaryPath)") }

        switch mode {
        case .createNew:
            guard renamex_np(temporaryPath, destination, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { throw WorkspaceError.collision(path: destination) }
                throw WorkspaceError.ioError("rename \(destination): \(String(cString: strerror(errno)))")
            }
        case let .replace(expectedHash):
            if let expectedHash {
                let current = root.map { FileSystem.read(url, below: $0) } ?? FileSystem.read(url)
                guard let current else { throw WorkspaceError.fileChangedConcurrently(path: destination) }
                guard DocumentFileRecord.hash(current) == expectedHash else {
                    throw WorkspaceError.fileChangedConcurrently(path: destination)
                }
                guard rename(temporaryPath, destination) == 0 else {
                    throw WorkspaceError.ioError("rename \(destination): \(String(cString: strerror(errno)))")
                }
            } else {
                guard renamex_np(temporaryPath, destination, UInt32(RENAME_EXCL)) == 0 else {
                    if errno == EEXIST { throw WorkspaceError.fileChangedConcurrently(path: destination) }
                    throw WorkspaceError.ioError("rename \(destination): \(String(cString: strerror(errno)))")
                }
            }
        }
        success = true
    }
}

/// Moves files inside a repository: `git mv` for tracked files, plain rename otherwise. Never replaces an
/// existing destination (spec F5 folder moves, F2 migrations).
struct RepositoryFileMover: Sendable {
    let git: GitClient?

    func move(from source: String, to destination: String, in root: URL) async throws {
        let sourceURL = root.appendingRelative(source)
        let destinationURL = root.appendingRelative(destination)
        // SR-SEC-07: neither side may leave the repository through a symbolic link.
        try FileSystem.requireConfined(sourceURL, below: root)
        try FileSystem.requireConfined(destinationURL, below: root)
        guard FileSystem.isRegularFile(sourceURL) else { throw WorkspaceError.fileNotFound(path: source) }
        guard !FileSystem.exists(destinationURL) else { throw WorkspaceError.collision(path: destination) }
        let directory = destinationURL.deletingLastPathComponent()
        if !FileSystem.isDirectory(directory) { try FileSystem.createDirectories(directory, below: root) }
        try FileSystem.requireConfined(destinationURL, below: root)
        if try await isTracked(source, in: root), let git {
            try await git.run(["mv", "--", source, destination], in: root)
            return
        }
        guard renamex_np(sourceURL.path(percentEncoded: false), destinationURL.path(percentEncoded: false), UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw WorkspaceError.collision(path: destination) }
            throw WorkspaceError.ioError("rename \(source): \(String(cString: strerror(errno)))")
        }
    }

    func isTracked(_ path: String, in root: URL) async throws -> Bool {
        guard let git, FileSystem.exists(root.appending(path: ".git")) else { return false }
        let result = try await git.run(["ls-files", "--error-unmatch", "--", path], in: root, acceptedExitCodes: [0, 1, 128])
        return result.exitCode == 0
    }

    /// Whether `path` has uncommitted changes (modified, staged or untracked). nil when not a git repo.
    func hasUncommittedChanges(_ path: String, in root: URL) async -> Bool? {
        guard let git, FileSystem.exists(root.appending(path: ".git")) else { return nil }
        guard let result = try? await git.run(["status", "--porcelain=v1", "-z", "--", path], in: root) else { return nil }
        return !result.standardOutputData.isEmpty
    }
}
