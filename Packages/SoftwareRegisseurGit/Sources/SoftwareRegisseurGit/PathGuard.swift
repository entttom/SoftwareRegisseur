import Darwin
import Foundation

/// Canonicalizes paths and enforces that file operations stay inside user-approved root folders
/// (spec E2 "Pfadoperationen … gegen Traversal/Symlinks absichern", L3, Q1).
public struct PathGuard: Sendable {
    /// Canonical allowed roots.
    public let allowedRoots: [URL]

    public init(allowedRoots: [URL]) throws(PathGuardError) {
        var roots: [URL] = []
        for root in allowedRoots {
            let canonical = try Self.canonicalize(root)
            guard Self.isDirectory(canonical) else { throw .rootNotFound(root.plainPath) }
            roots.append(canonical)
        }
        self.allowedRoots = roots
    }

    /// Resolves `.`/`..` and every symlink of the existing part of `url`; a not-yet-existing tail is
    /// appended verbatim but must not contain `..`.
    public static func canonicalize(_ url: URL) throws(PathGuardError) -> URL {
        guard url.isFileURL else { throw .notAFileURL(url.absoluteString) }
        // Relative file URLs would silently resolve against the daemon's working directory.
        guard url.baseURL == nil, url.relativePath.hasPrefix("/") else { throw .relativePath(url.relativePath) }
        let rawPath = url.path(percentEncoded: false)
        guard !rawPath.utf8.contains(0) else { throw .invalidCharacters(rawPath) }

        var existing = rawPath
        var tail: [String] = []
        while true {
            if let resolved = realpath(existing, nil) {
                defer { free(resolved) }
                var path = String(cString: resolved)
                for component in tail {
                    guard component != ".." else { throw .traversal(rawPath) }
                    if component == "." || component.isEmpty { continue }
                    path += (path.hasSuffix("/") ? "" : "/") + component
                }
                return URL(filePath: path, directoryHint: .inferFromPath)
            }
            guard errno == ENOENT || errno == ENOTDIR else { throw .unresolvable(rawPath, errno: errno) }
            // A dangling symlink must not be treated as a not-yet-created path.
            var info = stat()
            if lstat(existing, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
                throw .danglingSymlink(existing)
            }
            let ns = existing as NSString
            let last = ns.lastPathComponent
            let parent = ns.deletingLastPathComponent
            guard parent != existing, !parent.isEmpty else { throw .unresolvable(rawPath, errno: ENOENT) }
            tail.insert(last, at: 0)
            existing = parent
        }
    }

    /// Canonical form of `url` if it is one of the roots or inside one; throws otherwise.
    @discardableResult
    public func validate(_ url: URL) throws(PathGuardError) -> URL {
        let canonical = try Self.canonicalize(url)
        guard root(containing: canonical) != nil else { throw .outsideAllowedRoots(canonical.plainPath) }
        return canonical
    }

    public func isAllowed(_ url: URL) -> Bool {
        (try? validate(url)) != nil
    }

    /// The allowed root containing an already canonical URL.
    public func root(containing canonical: URL) -> URL? {
        allowedRoots.first { Self.isSameOrDescendant(canonical, of: $0) }
    }

    /// Validates the target for a new subfolder `name` inside `parent` (iPhone `CreateProject`, spec E2).
    public func validateNewSubfolder(
        named name: String,
        in parent: URL,
        rules: FolderNameRules = FolderNameRules()
    ) throws(PathGuardError) -> URL {
        try Self.validateFolderName(name, rules: rules)
        let canonicalParent = try validate(parent)
        guard Self.isDirectory(canonicalParent) else { throw .parentNotFound(canonicalParent.plainPath) }
        let target = canonicalParent.appending(path: name, directoryHint: .isDirectory)
        var info = stat()
        guard lstat(target.path(percentEncoded: false), &info) != 0 else { throw .alreadyExists(target.plainPath) }
        return try validate(target)
    }

    public static func validateFolderName(_ name: String, rules: FolderNameRules = FolderNameRules()) throws(PathGuardError) {
        guard !name.isEmpty else { throw .invalidFolderName(name, reason: .empty) }
        guard name != ".", name != ".." else { throw .invalidFolderName(name, reason: .traversal) }
        guard !name.contains("/"), !name.contains(":") else { throw .invalidFolderName(name, reason: .separator) }
        guard !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw .invalidFolderName(name, reason: .controlCharacter)
        }
        guard rules.allowLeadingDot || !name.hasPrefix(".") else { throw .invalidFolderName(name, reason: .leadingDot) }
        guard name.trimmingCharacters(in: .whitespaces) == name else {
            throw .invalidFolderName(name, reason: .surroundingWhitespace)
        }
        guard name.utf8.count <= rules.maxByteLength else { throw .invalidFolderName(name, reason: .tooLong) }
    }

    static func isSameOrDescendant(_ url: URL, of root: URL) -> Bool {
        let path = url.path(percentEncoded: false).trimmingTrailingSlash
        let rootPath = root.path(percentEncoded: false).trimmingTrailingSlash
        return path == rootPath || path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/")
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

public struct FolderNameRules: Sendable, Hashable {
    public var allowLeadingDot: Bool
    public var maxByteLength: Int

    public init(allowLeadingDot: Bool = false, maxByteLength: Int = 255) {
        self.allowLeadingDot = allowLeadingDot
        self.maxByteLength = min(maxByteLength, 255)
    }
}

public enum PathGuardError: Error, Sendable, Hashable {
    public enum FolderNameProblem: String, Sendable, Hashable {
        case empty, traversal, separator, controlCharacter, leadingDot, surroundingWhitespace, tooLong
    }

    case notAFileURL(String)
    case relativePath(String)
    case invalidCharacters(String)
    case traversal(String)
    case danglingSymlink(String)
    case unresolvable(String, errno: Int32)
    case outsideAllowedRoots(String)
    case rootNotFound(String)
    case parentNotFound(String)
    case alreadyExists(String)
    case invalidFolderName(String, reason: FolderNameProblem)
}

extension String {
    var trimmingTrailingSlash: String {
        var value = self
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        return value
    }
}

extension URL {
    /// Path without trailing slash, for comparisons and dictionary keys.
    var plainPath: String { path(percentEncoded: false).trimmingTrailingSlash }
}
