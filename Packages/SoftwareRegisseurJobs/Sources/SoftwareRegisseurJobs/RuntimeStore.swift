import Foundation
import SoftwareRegisseurAgents
import SoftwareRegisseurDomain

/// Live bookkeeping of one approval request of a connected session. The approval itself is the
/// synced Domain `PendingApproval` (spec J6 V1 fallback); this keeps what only the session knows.
struct LiveApproval: Hashable, Sendable {
    let approvalId: PendingApprovalID
    let availableDecisions: [AgentApprovalDecision]
    let receivedAt: Date
    var timedOutAt: Date?
    /// Full redacted request text when the synced preview had to be truncated (SR-SEC-08). Host-local
    /// only: shown in the Mac UI before an explicit, host-reviewed `allow`.
    var fullPreview: String?
}

public enum MissedRunResolution: String, Hashable, Sendable, Codable {
    case awaitingUser
    case runNow
    case skipped
}

/// A planned start that passed while the host was off or asleep (spec K3, A18).
public struct MissedRunRecord: Hashable, Sendable, Codable {
    public let scheduledFor: Date
    public let detectedAt: Date
    public let hostLastSeen: Date?
    public let policy: MissedRunPolicy
    public var resolution: MissedRunResolution
    /// e.g. „für 22:00 geplant, Mac zuletzt online 21:30“.
    public let statusText: String
}

/// Host-local runtime state of one job that has no column in the synced job record (pid, process
/// group, worktree bookkeeping, scheduling bookkeeping). Stored as JSON per job in the app-support
/// directory; never synced (spec N1: no process environments). Approvals and the retry link are synced
/// Domain data since v4 (`PendingApproval`, `AgentJob.retryOfJobId`).
public struct JobRuntimeRecord: Hashable, Sendable, Codable {
    public let jobId: JobID
    public var hostId: HostID
    public var lockId: LockID?
    public var repositoryPath: String?
    public var defaultBranch: String?
    public var baseCommit: String?
    public var worktreePath: String?
    public var branch: String?
    public var processIdentifier: Int32?
    /// Process group reported by the session (liveness without cwd scan, spec L1).
    public var processGroupIdentifier: Int32?
    public var processStartedAt: Date?
    public var sessionUUID: UUID?
    public var threadId: String?
    public var dueObservedAt: Date?
    public var missedRun: MissedRunRecord?
    public var lastQuotaMessage: String?
    /// Agent process survived a service restart without a session connection.
    public var orphanedProcess: Bool
    public var admissionNote: String?
    public var updatedAt: Date

    init(jobId: JobID, hostId: HostID, at date: Date) {
        self.jobId = jobId
        self.hostId = hostId
        orphanedProcess = false
        updatedAt = date
    }
}

/// Review data for the Mac UI (spec M1/M2): the synced Domain `Review` content (summary, commits,
/// per-file stats, conflicts) plus host-local paths and refs that never leave the Mac.
public struct ReviewDetails: Hashable, Sendable {
    public let reviewId: ReviewID
    public let jobId: JobID
    public let workItemId: WorkItemID
    public let repositoryPath: String
    public let defaultBranch: String
    public let branch: String
    public let worktreePath: String?
    public let baseCommit: String?
    public let headCommit: String
    public let commits: [ReviewCommit]
    public let files: [ReviewFileChange]
    public let agentSummary: String?
    /// Paths of uncommitted agent output that the host committed on the job branch.
    public let autoCommittedPaths: [String]
    /// Uncommitted agent output that looked like a secret and was therefore *not* committed
    /// (SR-SEC-09, ADR-0026). It stays in the worktree; the integration is blocked until it is removed.
    public let excludedSecretPaths: [String]
    public let permissionDenials: [String]
    public let capturedAt: Date
    public let integrationConflictFiles: [String]?
    public let integrationProblem: String?
    public let integratedCommit: String?
    public let integratedAt: Date?

    init(review: Review, host: ReviewHostRecord) {
        reviewId = review.reviewId
        jobId = review.jobId
        workItemId = host.workItemId
        repositoryPath = host.repositoryPath
        defaultBranch = host.defaultBranch
        branch = host.branch
        worktreePath = host.worktreePath
        baseCommit = host.baseCommit
        headCommit = review.headCommit ?? host.headCommit
        commits = review.commits
        files = review.fileChanges
        agentSummary = review.summary
        autoCommittedPaths = host.autoCommittedPaths
        excludedSecretPaths = host.excludedSecretPaths ?? []
        permissionDenials = host.permissionDenials
        capturedAt = host.capturedAt
        integrationConflictFiles = review.conflict?.files
        integrationProblem = host.integrationProblem ?? review.conflict?.message
        integratedCommit = review.integrationCommit
        integratedAt = host.integratedAt
    }
}

/// Host-local part of a review: repository paths and refs (spec N1: no local paths in CloudKit beyond
/// what the project location already has). Review content lives in the synced Domain `Review`.
struct ReviewHostRecord: Hashable, Sendable, Codable {
    let reviewId: ReviewID
    let jobId: JobID
    let workItemId: WorkItemID
    let repositoryPath: String
    let defaultBranch: String
    let branch: String
    let worktreePath: String?
    let baseCommit: String?
    let headCommit: String
    /// Paths of uncommitted agent output that the host committed on the job branch.
    let autoCommittedPaths: [String]
    let permissionDenials: [String]
    let capturedAt: Date
    /// Non-conflict integration refusal or capture problem (German).
    var integrationProblem: String?
    var integratedAt: Date?
    /// Agent output not committed because it looked like a secret (SR-SEC-09). Absent in older records.
    var excludedSecretPaths: [String]? = nil
}

/// File-backed store (`<runtimeDirectory>/jobs/<job>.json`, `<runtimeDirectory>/reviews/<review>.json`).
struct JobRuntimeStore: Sendable {
    let directory: URL

    init(directory: URL) throws {
        self.directory = directory
        for sub in ["jobs", "reviews"] {
            try FileManager.default.createDirectory(at: directory.appending(path: sub, directoryHint: .isDirectory),
                                                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    func record(_ id: JobID) -> JobRuntimeRecord? { load(url(job: id)) }

    func save(_ record: JobRuntimeRecord) throws { try write(record, to: url(job: record.jobId)) }

    func reviewHost(_ id: ReviewID) -> ReviewHostRecord? { load(url(review: id)) }

    func save(_ record: ReviewHostRecord) throws { try write(record, to: url(review: record.reviewId)) }

    private func url(job: JobID) -> URL { directory.appending(path: "jobs/\(job.uuidString).json") }
    private func url(review: ReviewID) -> URL { directory.appending(path: "reviews/\(review.uuidString).json") }

    private func load<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(T.self, from: data)
    }

    private func write(_ value: some Encodable, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
    }
}
