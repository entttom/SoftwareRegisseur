/// Configurable document layout of a repository (spec F2, F5; ADR-0004). All folder names are user settable,
/// e.g. `ideen/offen` or `features/erledigt`.
public struct FolderLayout: Sendable, Hashable, Codable {
    public var adrPath: RelativePath
    public var requestsRoot: RelativePath
    /// Status folder relative to `requestsRoot`. Statuses without an entry keep the file in its current folder.
    public var statusFolders: [WorkItemStatus: RelativePath]

    public init(adrPath: RelativePath, requestsRoot: RelativePath, statusFolders: [WorkItemStatus: RelativePath]) {
        self.adrPath = adrPath
        self.requestsRoot = requestsRoot
        self.statusFolders = statusFolders
    }

    /// Defaults per spec F2/F5: queued/scheduled live in `open`, integrated/done in `done`;
    /// blocked, failed, cancelled and paused stay where they are.
    public static var `default`: FolderLayout {
        // Literal paths are known valid.
        let open = try! RelativePath("open")
        let inProgress = try! RelativePath("in-progress")
        let review = try! RelativePath("review")
        let done = try! RelativePath("done")
        return FolderLayout(
            adrPath: try! RelativePath("docs/adr"),
            requestsRoot: try! RelativePath("docs/requests"),
            statusFolders: [
                .inbox: open, .open: open, .queued: open, .scheduled: open,
                .inProgress: inProgress, .waitingApproval: inProgress,
                .implementationFinished: review, .review: review,
                .integrated: done, .done: done,
            ]
        )
    }

    /// Folder (repository-relative) for a status, or nil when the status keeps the current folder.
    public func folder(for status: WorkItemStatus) -> RelativePath? {
        statusFolders[status].map { requestsRoot.appending($0) }
    }

    /// Repository-relative destination of a request file after a status change.
    public func destination(for status: WorkItemStatus, fileName: String, currentFolder: RelativePath)
        throws(RelativePathError) -> RelativePath {
        try (folder(for: status) ?? currentFolder).appending(component: fileName)
    }

    /// Statuses whose configured folder is `folder` (repository-relative); used when a file was moved externally.
    public func statuses(inFolder folder: RelativePath) -> [WorkItemStatus] {
        WorkItemStatus.allCases.filter { self.folder(for: $0) == folder }
    }

    /// All distinct request folders (repository-relative) in status order.
    public var requestFolders: [RelativePath] {
        var result: [RelativePath] = []
        for status in WorkItemStatus.allCases {
            if let folder = folder(for: status), !result.contains(folder) { result.append(folder) }
        }
        return result
    }

    public enum Issue: Sendable, Hashable {
        case adrFolderOverlapsRequests(RelativePath)
    }

    /// Structural problems that would make files ambiguous (e.g. ADRs inside a request folder).
    public func validate() -> [Issue] {
        var issues: [Issue] = []
        for folder in [requestsRoot] + requestFolders where folder == adrPath {
            let issue = Issue.adrFolderOverlapsRequests(folder)
            if !issues.contains(issue) { issues.append(issue) }
        }
        return issues
    }
}
