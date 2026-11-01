import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurMarkdown
import SoftwareRegisseurPersistence

/// The request fields that are mirrored between database and file (spec F3). Execution metadata
/// (`agentJobIds`, human ID, UUID) is owned by the host and never taken from a file edit.
public struct RequestFields: Hashable, Sendable {
    public enum Field: String, Hashable, Sendable, CaseIterable {
        case title, status, priority, labels, body, reviewState
    }

    public var title: String
    public var status: DomainWorkItemStatus
    public var priority: Priority
    public var labels: [String]
    public var body: String
    public var reviewState: ReviewState

    public init(item: WorkItem) {
        title = item.title
        status = item.status
        priority = item.priority
        labels = item.labels
        body = RequestBody.normalize(item.structuredBody)
        reviewState = item.reviewState
    }

    /// nil when required fields are missing or invalid.
    public init?(document: RequestDocument) {
        let metadata = document.metadata
        guard let title = metadata.title, let status = metadata.status else { return nil }
        self.title = title
        self.status = MarkdownDomainBridge.domain(status)
        priority = metadata.priority.map(MarkdownDomainBridge.domain) ?? .medium
        labels = metadata.labels
        body = RequestBody.structuredBody(of: document)
        reviewState = metadata.reviewState.flatMap(ReviewState.init(rawValue:)) ?? .pending
    }

    public func changedFields(comparedTo other: RequestFields) -> Set<Field> {
        var fields: Set<Field> = []
        if title != other.title { fields.insert(.title) }
        if status != other.status { fields.insert(.status) }
        if priority != other.priority { fields.insert(.priority) }
        if labels != other.labels { fields.insert(.labels) }
        if body != other.body { fields.insert(.body) }
        if reviewState != other.reviewState { fields.insert(.reviewState) }
        return fields
    }

    func value(_ field: Field) -> AnyHashable {
        switch field {
        case .title: title
        case .status: status
        case .priority: priority
        case .labels: labels
        case .body: body
        case .reviewState: reviewState
        }
    }
}

/// Body ↔ `WorkItem.structuredBody`: the body after the `# ID: Titel` heading, line endings normalised.
public enum RequestBody {
    public static func normalize(_ text: String) -> String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        while let first = lines.first, first.isEmpty { lines.removeFirst() }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    public static func structuredBody(of document: RequestDocument) -> String {
        var lines = document.frontmatter.body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        if let first = lines.first, first.hasPrefix("# ") { lines.removeFirst() }
        return normalize(lines.joined(separator: "\n"))
    }

    /// Replaces the body after the H1 heading, keeping the heading (or writing `# ID: title`).
    static func replace(in document: inout RequestDocument, body: String, heading: String) {
        let lineEnding = document.frontmatter.lineEnding.rawValue
        var lines = document.frontmatter.body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var prefix: [String] = []
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { prefix.append(lines.removeFirst()) }
        let headingLine = lines.first.flatMap { $0.hasPrefix("# ") ? $0 : nil } ?? heading
        var result = prefix.isEmpty ? [""] : prefix
        result.append(headingLine)
        let normalized = normalize(body)
        if !normalized.isEmpty {
            result.append("")
            result.append(contentsOf: normalized.components(separatedBy: "\n"))
        }
        document.frontmatter.body = result.joined(separator: lineEnding) + lineEnding
    }

    /// Updates the first H1 if it has the generated form `# ID: …`; custom headings stay untouched.
    static func updateHeading(in document: inout RequestDocument, id: String, oldTitle: String, newTitle: String) {
        let lineEnding = document.frontmatter.lineEnding.rawValue
        var lines = document.frontmatter.body.components(separatedBy: lineEnding)
        guard let index = lines.firstIndex(where: { $0.hasPrefix("# ") }) else { return }
        guard lines[index].hasPrefix("# \(id): ") else { return }
        lines[index] = "# \(id): \(newTitle)"
        document.frontmatter.body = lines.joined(separator: lineEnding)
    }
}

/// One request file found in a repository.
public struct RequestFileEntry: Sendable, Hashable {
    public var relativePath: String
    public var data: Data
    public var document: RequestDocument
    public var uuid: UUID?
    public var humanId: MarkdownHumanID?

    public var text: String { String(decoding: data, as: UTF8.self) }
    public var hash: String { DocumentFileRecord.hash(data) }
    public var fileName: String { (relativePath as NSString).lastPathComponent }
    public var folder: String { (relativePath as NSString).deletingLastPathComponent }
}

/// Enumerates request files below the configured requests root (spec F2).
enum RequestFileScanner {
    static func scan(root: URL, layout: FolderLayout) -> [RequestFileEntry] {
        let requestsRoot = root.appendingRelative(layout.requestsRoot.string)
        var entries: [RequestFileEntry] = []
        for relative in FileSystem.markdownFiles(in: requestsRoot, relativeTo: root) {
            if layout.adrPath != .root, relative.hasPrefix(layout.adrPath.string + "/") { continue }
            guard let data = FileSystem.read(relative, in: root) else { continue }
            let document = RequestDocument(text: String(decoding: data, as: UTF8.self))
            let metadata = document.metadata
            let fileId = RequestFileName.parse((relative as NSString).lastPathComponent)?.id
            // Only files that look like requests (UUID in frontmatter or request file name).
            guard metadata.uuid != nil || fileId != nil else { continue }
            entries.append(RequestFileEntry(relativePath: relative, data: data, document: document,
                                            uuid: metadata.uuid, humanId: metadata.id ?? fileId))
        }
        return entries
    }

    /// Human IDs used by files (frontmatter and file names), for allocation (ADR-0018).
    static func usedHumanIDs(_ entries: [RequestFileEntry]) -> [DomainHumanID] {
        var ids: [DomainHumanID] = []
        for entry in entries {
            for candidate in [entry.document.metadata.id, RequestFileName.parse(entry.fileName)?.id].compactMap({ $0 }) {
                if let id = try? MarkdownDomainBridge.domain(candidate) { ids.append(id) }
            }
        }
        return ids
    }
}
