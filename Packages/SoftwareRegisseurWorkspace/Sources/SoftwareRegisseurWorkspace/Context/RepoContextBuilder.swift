import Foundation
import SoftwareRegisseurAI
import SoftwareRegisseurDomain
import SoftwareRegisseurMarkdown

/// Exactly what would be sent to the external provider (spec H4: "Dateiauswahl und Datenübermittlung …
/// nachvollziehbar"). Excluded entries never had their content read into the request.
public struct RepoContextManifest: Sendable, Hashable {
    public enum Exclusion: Sendable, Hashable, CustomStringConvertible {
        /// `.env`, keys, credentials, certificates (ContextSecretFilter patterns).
        case secretPath(pattern: String)
        case overBudget
        case outsideRepository
        case notFound
        case binary
        case symlink

        public var description: String {
            switch self {
            case let .secretPath(pattern): String(localized: "Ausgeschlossen: mögliche Geheimnisse (Muster „\(pattern)“)", bundle: .module)
            case .overBudget: String(localized: "Ausgeschlossen: Kontextbudget überschritten", bundle: .module)
            case .outsideRepository: String(localized: "Ausgeschlossen: liegt außerhalb des Repositorys", bundle: .module)
            case .notFound: "Ausgeschlossen: Datei nicht gefunden"
            case .binary: "Ausgeschlossen: keine Textdatei"
            case .symlink: "Ausgeschlossen: symbolischer Link"
            }
        }
    }

    public struct Entry: Sendable, Hashable {
        public let kind: AIContextKind
        public let title: String
        public let path: String?
        public let characterCount: Int
        public let redactionCount: Int
        public let truncated: Bool
    }

    public struct ExcludedEntry: Sendable, Hashable {
        public let kind: AIContextKind
        public let title: String
        public let path: String?
        public let reason: Exclusion
    }

    public var included: [Entry]
    public var excluded: [ExcludedEntry]
    public var budget: Int

    public var totalCharacters: Int { included.reduce(0) { $0 + $1.characterCount } }
    public var estimatedTokens: Int { (totalCharacters + 3) / 4 }
    public var totalRedactions: Int { included.reduce(0) { $0 + $1.redactionCount } }
}

public struct RepoContext: Sendable, Hashable {
    /// Items to hand to the AI layer (`DraftComposer` etc.); already filtered and redacted.
    public let items: [AIContextItem]
    public let manifest: RepoContextManifest
}

/// Selects repository context for the Mac-side AI elaboration (spec H4, A11): tree summary, accepted ADRs,
/// existing requests and user-chosen source files, within a character budget, secrets excluded/redacted.
public struct RepoContextBuilder: Sendable {
    public struct Options: Sendable, Hashable {
        /// Maximum characters of context data.
        public var maxCharacters: Int
        public var maxTreeEntries: Int
        public var maxTreeDepth: Int
        public var maxFileBytes: Int
        public var includeRequestStatuses: Set<MarkdownWorkItemStatus>
        public var excludedDirectoryNames: Set<String>

        public init(
            maxCharacters: Int = 60_000, maxTreeEntries: Int = 400, maxTreeDepth: Int = 4, maxFileBytes: Int = 200_000,
            includeRequestStatuses: Set<MarkdownWorkItemStatus> = [.inbox, .open, .queued, .scheduled, .inProgress, .review, .blocked],
            excludedDirectoryNames: Set<String> = [".git", "node_modules", ".build", "DerivedData", "Pods", "build", "dist", ".venv", ".swiftpm"]
        ) {
            self.maxCharacters = maxCharacters
            self.maxTreeEntries = maxTreeEntries
            self.maxTreeDepth = maxTreeDepth
            self.maxFileBytes = maxFileBytes
            self.includeRequestStatuses = includeRequestStatuses
            self.excludedDirectoryNames = excludedDirectoryNames
        }
    }

    public var filter: ContextSecretFilter
    public var options: Options

    public init(filter: ContextSecretFilter = ContextSecretFilter(), options: Options = Options()) {
        self.filter = filter
        self.options = options
    }

    /// Builds the context for a repository. `selectedFiles` are repository-relative paths chosen by the user.
    public func build(root: URL, layout: FolderLayout, selectedFiles: [String] = []) -> RepoContext {
        var candidates: [(AIContextItem, Bool)] = [] // (item, truncatable)
        var excluded: [RepoContextManifest.ExcludedEntry] = []

        candidates.append((AIContextItem(kind: .repositoryStructure, title: "Repository-Struktur", content: treeSummary(root: root)), true))

        // Accepted ADRs (spec H4) – full text.
        let adrFolder = root.appendingRelative(layout.adrPath.string)
        for relative in FileSystem.markdownFiles(in: adrFolder, relativeTo: root, recursive: false) {
            let name = (relative as NSString).lastPathComponent
            if ADRImporter.ignoredFileNames.contains(name.lowercased()) { continue }
            if let pattern = filter.exclusionPattern(forPath: relative) {
                excluded.append(.init(kind: .adrIndex, title: name, path: relative, reason: .secretPath(pattern: pattern)))
                continue
            }
            guard let data = FileSystem.read(relative, in: root) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            guard case let .compatible(record) = ADRParser.parse(fileName: name, text: text), record.status == .accepted else { continue }
            candidates.append((AIContextItem(kind: .adrIndex, title: "ADR-\(ADRNumbering.format(record.number)): \(record.title)",
                                             path: relative, content: text), false))
        }

        // Existing requests: compact index (ID, status, title), not full bodies.
        let requests = RequestFileScanner.scan(root: root, layout: layout).compactMap { entry -> String? in
            let metadata = entry.document.metadata
            guard let status = metadata.status, options.includeRequestStatuses.contains(status) else { return nil }
            return "- \(metadata.rawID ?? "?") [\(status.rawValue)] \(metadata.title ?? entry.fileName) (\(entry.relativePath))"
        }
        if !requests.isEmpty {
            candidates.append((AIContextItem(kind: .existingRequest, title: "Bestehende Requests",
                                             content: requests.joined(separator: "\n")), true))
        }

        // User-chosen source files.
        let rootPath = FileSystem.realPath(root)
        for path in selectedFiles {
            let title = (path as NSString).lastPathComponent
            if let pattern = filter.exclusionPattern(forPath: path) {
                excluded.append(.init(kind: .sourceFile, title: title, path: path, reason: .secretPath(pattern: pattern)))
                continue
            }
            let components = path.split(separator: "/")
            if path.hasPrefix("/") || components.contains("..") {
                excluded.append(.init(kind: .sourceFile, title: title, path: path, reason: .outsideRepository))
                continue
            }
            let url = root.appendingRelative(path)
            var info = stat()
            if lstat(url.path(percentEncoded: false), &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
                excluded.append(.init(kind: .sourceFile, title: title, path: path, reason: .symlink))
                continue
            }
            let resolved = FileSystem.realPath(url)
            guard resolved.hasPrefix(rootPath + "/") else {
                excluded.append(.init(kind: .sourceFile, title: title, path: path, reason: .outsideRepository))
                continue
            }
            // The resolved path is checked again (e.g. a folder named like a secret further up).
            if let pattern = filter.exclusionPattern(forPath: String(resolved.dropFirst(rootPath.count + 1))) {
                excluded.append(.init(kind: .sourceFile, title: title, path: path, reason: .secretPath(pattern: pattern)))
                continue
            }
            guard let data = FileSystem.read(url) else {
                excluded.append(.init(kind: .sourceFile, title: title, path: path, reason: .notFound))
                continue
            }
            let limited = data.prefix(options.maxFileBytes)
            guard !limited.contains(0), let text = String(data: limited, encoding: .utf8) else {
                excluded.append(.init(kind: .sourceFile, title: title, path: path, reason: .binary))
                continue
            }
            candidates.append((AIContextItem(kind: .sourceFile, title: path, path: path, content: text), false))
        }

        // Budget + redaction.
        var remaining = options.maxCharacters
        var items: [AIContextItem] = []
        var included: [RepoContextManifest.Entry] = []
        for (item, truncatable) in candidates {
            let redacted = filter.redact(item.content)
            var content = redacted.text
            var truncated = false
            if content.isEmpty { continue }
            if content.count > remaining {
                guard truncatable, remaining > 200 else {
                    excluded.append(.init(kind: item.kind, title: item.title, path: item.path, reason: .overBudget))
                    continue
                }
                content = String(content.prefix(remaining - 20)) + "\n[… gekürzt]"
                truncated = true
            }
            remaining -= content.count
            var sanitized = item
            sanitized.content = content
            items.append(sanitized)
            included.append(.init(kind: item.kind, title: item.title, path: item.path, characterCount: content.count,
                                  redactionCount: redacted.redactionCount, truncated: truncated))
        }
        return RepoContext(items: items, manifest: RepoContextManifest(included: included, excluded: excluded, budget: options.maxCharacters))
    }

    /// Indented tree of directories and files (secret paths and excluded folders omitted).
    func treeSummary(root: URL) -> String {
        var lines: [String] = []
        let rootPath = FileSystem.realPath(root)
        func walk(_ directory: URL, depth: Int) {
            guard lines.count < options.maxTreeEntries, let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]
            ) else { return }
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard lines.count < options.maxTreeEntries else { return }
                let name = entry.lastPathComponent
                let relative = String(FileSystem.realPath(entry).dropFirst(rootPath.count + 1))
                if filter.isExcluded(path: relative) { continue }
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { continue }
                let indent = String(repeating: "  ", count: depth)
                if values?.isDirectory == true {
                    if options.excludedDirectoryNames.contains(name) { continue }
                    lines.append("\(indent)\(name)/")
                    if depth + 1 < options.maxTreeDepth { walk(entry, depth: depth + 1) }
                } else {
                    lines.append("\(indent)\(name)")
                }
            }
        }
        walk(root, depth: 0)
        if lines.count >= options.maxTreeEntries { lines.append("… (gekürzt)") }
        return lines.joined(separator: "\n")
    }
}
