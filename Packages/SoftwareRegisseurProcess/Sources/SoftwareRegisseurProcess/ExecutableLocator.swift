import Darwin
import Foundation

/// Resolves tool names (`git`, `codex`, `claude`, …) without relying on the shell `PATH`, which a
/// LaunchAgent does not have (spec J1). Purely inspects the file system – no side effects.
public struct ExecutableLocator: Sendable {
    /// Ordered search directories (user-configured first, then defaults), deduplicated.
    public let searchDirectories: [URL]

    public init(
        userDirectories: [URL] = [],
        homeDirectory: URL = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory),
        includeDefaultDirectories: Bool = true
    ) {
        var seen = Set<String>()
        var directories: [URL] = []
        let all = userDirectories + (includeDefaultDirectories ? Self.defaultDirectories(homeDirectory: homeDirectory) : [])
        for directory in all {
            let standardized = directory.standardizedFileURL
            if seen.insert(standardized.path(percentEncoded: false)).inserted {
                directories.append(standardized)
            }
        }
        searchDirectories = directories
    }

    /// Apple Silicon Homebrew, Intel Homebrew, user-local installs, then system directories.
    public static func defaultDirectories(homeDirectory: URL) -> [URL] {
        [
            URL(filePath: "/opt/homebrew/bin", directoryHint: .isDirectory),
            URL(filePath: "/usr/local/bin", directoryHint: .isDirectory),
            homeDirectory.appending(path: ".local/bin", directoryHint: .isDirectory),
            URL(filePath: "/usr/bin", directoryHint: .isDirectory),
            URL(filePath: "/bin", directoryHint: .isDirectory),
        ]
    }

    /// `PATH` value matching `searchDirectories`, e.g. for agent child processes.
    public var pathEnvironmentValue: String {
        searchDirectories.map { $0.path(percentEncoded: false) }.joined(separator: ":")
    }

    /// Looks up `name` in every search directory and reports all candidates.
    public func locate(_ name: String) throws(ExecutableLocatorError) -> ExecutableLookup {
        guard Self.isValidToolName(name) else { throw .invalidName(name) }
        let candidates = searchDirectories.compactMap { directory -> ExecutableCandidate? in
            let url = directory.appending(path: name, directoryHint: .notDirectory)
            var info = stat()
            guard lstat(url.path(percentEncoded: false), &info) == 0 else { return nil }
            return Self.inspect(url, searchDirectory: directory)
        }
        return ExecutableLookup(name: name, candidates: candidates)
    }

    /// Inspects an explicitly configured executable path (e.g. a user override in settings).
    public static func inspect(_ url: URL, searchDirectory: URL? = nil) -> ExecutableCandidate {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        var linkInfo = stat()
        guard lstat(path, &linkInfo) == 0 else {
            return ExecutableCandidate(url: url, resolvedURL: nil, searchDirectory: searchDirectory,
                                       isSymbolicLink: false, status: .missing)
        }
        let isLink = (linkInfo.st_mode & S_IFMT) == S_IFLNK
        guard let resolved = realpath(path, nil) else {
            return ExecutableCandidate(url: url, resolvedURL: nil, searchDirectory: searchDirectory,
                                       isSymbolicLink: isLink, status: isLink ? .brokenSymbolicLink : .missing)
        }
        defer { free(resolved) }
        let resolvedPath = String(cString: resolved)
        let resolvedURL = URL(filePath: resolvedPath, directoryHint: .notDirectory)
        var info = stat()
        let status: ExecutableCandidate.Status
        if stat(resolvedPath, &info) != 0 {
            status = .missing
        } else if (info.st_mode & S_IFMT) != S_IFREG {
            status = .notRegularFile
        } else if access(resolvedPath, X_OK) != 0 {
            status = .notExecutable
        } else {
            status = .usable
        }
        return ExecutableCandidate(url: url, resolvedURL: resolvedURL, searchDirectory: searchDirectory,
                                   isSymbolicLink: isLink, status: status)
    }

    static func isValidToolName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.utf8.contains(0)
            && name.utf8.count <= 255
    }
}

public enum ExecutableLocatorError: Error, Sendable, Hashable {
    case invalidName(String)
}

public struct ExecutableCandidate: Sendable, Hashable {
    public enum Status: String, Sendable, Hashable, Codable {
        case usable, missing, brokenSymbolicLink, notRegularFile, notExecutable
    }

    /// Path inside the search directory.
    public let url: URL
    /// Fully symlink-resolved target, if it exists.
    public let resolvedURL: URL?
    public let searchDirectory: URL?
    public let isSymbolicLink: Bool
    public let status: Status

    public var isUsable: Bool { status == .usable }
}

public struct ExecutableLookup: Sendable, Hashable {
    public let name: String
    /// Every existing entry named `name`, in search order (including unusable ones, for diagnostics).
    public let candidates: [ExecutableCandidate]

    /// First usable candidate in search order.
    public var preferred: ExecutableCandidate? { candidates.first(where: \.isUsable) }
}
