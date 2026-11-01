import Foundation

// MARK: - TaskEvent

public enum TaskEventKind: String, Hashable, Sendable, Codable, CaseIterable {
    case created
    case edited
    case statusChanged
    case humanIDAssigned
    case jobRequested
    case jobStateChanged
    case configurationReplaced
    case lockAcquired
    case lockReleased
    case reviewDecided
    case integrated
    case externalChangeDetected
    case conflictDetected
    case comment
    // Additive kinds (raw values are stored; existing values keep decoding unchanged).
    /// The agent asked for an approval (payload: jobId, approvalId, requestId, kind, summary).
    case approvalRequested
    /// A user decision was relayed to the agent (payload: jobId, approvalId, decision, device).
    case approvalAnswered
    /// An approval timed out, expired or was withdrawn without an answer.
    case approvalExpired
    /// Job waits for quota (payload: jobId, attempt, nextAttemptAt, basis).
    case quotaWait
    /// A planned start passed while the Mac was off/asleep (payload: jobId, scheduledFor, policy, text).
    case missedRun
    /// A new job retries an earlier one (payload: jobId, retryOf).
    case jobRetried
    /// Work item reclassified (payload: from, to).
    case typeChanged
    case archived
    case unarchived
}

public enum EventActor: Hashable, Sendable, Codable {
    case user(DeviceID)
    case host(HostID)
    case agent(ProviderID, JobID)
    case external
}

/// Append-only history entry (spec M2).
public struct TaskEvent: Hashable, Sendable, Codable, Identifiable {
    public let eventId: EventID
    public let workItemId: WorkItemID
    public let kind: TaskEventKind
    public let actor: EventActor
    public let timestamp: Date
    public let payload: [String: String]
    /// WorkItem revision the event was produced against.
    public let sourceRevision: Int

    public var id: EventID { eventId }

    public init(
        eventId: EventID = EventID(),
        workItemId: WorkItemID,
        kind: TaskEventKind,
        actor: EventActor,
        timestamp: Date,
        payload: [String: String] = [:],
        sourceRevision: Int
    ) {
        self.eventId = eventId
        self.workItemId = workItemId
        self.kind = kind
        self.actor = actor
        self.timestamp = timestamp
        self.payload = payload
        self.sourceRevision = sourceRevision
    }
}

// MARK: - Review

public struct DiffSummary: Hashable, Sendable, Codable {
    public var filesChanged: Int
    public var insertions: Int
    public var deletions: Int
    public var files: [String]

    public init(filesChanged: Int, insertions: Int, deletions: Int, files: [String] = []) {
        self.filesChanged = filesChanged
        self.insertions = insertions
        self.deletions = deletions
        self.files = files
    }
}

public enum TestOutcome: String, Hashable, Sendable, Codable, CaseIterable {
    case passed
    case failed
    case skipped
    case notRun
}

public struct TestResult: Hashable, Sendable, Codable {
    public var name: String
    public var outcome: TestOutcome
    public var detail: String?

    public init(name: String, outcome: TestOutcome, detail: String? = nil) {
        self.name = name
        self.outcome = outcome
        self.detail = detail
    }
}

public enum ReviewDecision: String, Hashable, Sendable, Codable, CaseIterable {
    case pending
    case approved
    case changesRequested
    case rejected
}

public enum ReviewError: Error, Hashable, Sendable {
    case notApproved(ReviewDecision)
    case emptyCommitHash
    case alreadyIntegrated(String)
}

/// One commit of the job branch (spec M1/M2).
public struct ReviewCommit: Hashable, Sendable, Codable {
    public let sha: String
    public let subject: String

    public init(sha: String, subject: String) {
        self.sha = sha
        self.subject = subject
    }
}

/// Per-file statistics of the job branch against the default branch. `nil` counts for binary files.
public struct ReviewFileChange: Hashable, Sendable, Codable {
    /// Git status letter(s), e.g. `M`, `A`, `D`, `R100`.
    public let status: String
    public let path: String
    public let originalPath: String?
    public let additions: Int?
    public let deletions: Int?

    public init(status: String, path: String, originalPath: String? = nil, additions: Int?, deletions: Int?) {
        self.status = status
        self.path = path
        self.originalPath = originalPath
        self.additions = additions
        self.deletions = deletions
    }
}

/// Integration conflict of an approved review (ADR-0015): nothing was changed in the repository.
public struct ReviewConflictInfo: Hashable, Sendable, Codable {
    public let files: [String]
    /// German explanation.
    public let message: String
    public let detectedAt: Date

    public init(files: [String], message: String, detectedAt: Date) {
        self.files = files
        self.message = message
        self.detectedAt = detectedAt
    }
}

/// Aggregated test outcome of a run (spec M1: Teststatus; P 7 iPhone review).
public struct TestRunSummary: Hashable, Sendable, Codable {
    public var passed: Int
    public var failed: Int
    public var skipped: Int
    public var notRun: Int

    public init(passed: Int = 0, failed: Int = 0, skipped: Int = 0, notRun: Int = 0) {
        self.passed = passed
        self.failed = failed
        self.skipped = skipped
        self.notRun = notRun
    }

    public init(results: [TestResult]) {
        self.init()
        for result in results {
            switch result.outcome {
            case .passed: passed += 1
            case .failed: failed += 1
            case .skipped: skipped += 1
            case .notRun: notRun += 1
            }
        }
    }

    public var total: Int { passed + failed + skipped + notRun }
    public var hasFailures: Bool { failed > 0 }
}

/// Review of an agent run (spec M1, ADR-0007, ADR-0015). A task is `integrated` only with a recorded
/// commit in the default branch. Review content (summary, commits, file stats, conflicts, tests) is
/// synced so the iPhone can show a compact summary (spec M1 step 4, P 7).
public struct Review: Hashable, Sendable, Codable, Identifiable {
    public let reviewId: ReviewID
    public let jobId: JobID
    public var diffSummary: DiffSummary
    public var testResults: [TestResult]
    public private(set) var decision: ReviewDecision
    public private(set) var approvedAt: Date?
    public private(set) var integrationCommit: String?
    public private(set) var integrationStrategy: IntegrationStrategy?
    // Additive content (absent in older payloads → defaults).
    /// Agent's final summary (redacted, bounded).
    public var summary: String?
    public var commits: [ReviewCommit]
    public var fileChanges: [ReviewFileChange]
    public var conflict: ReviewConflictInfo?
    /// Explicit summary; nil → derived from `testResults` (see `effectiveTestSummary`).
    public var testSummary: TestRunSummary?
    /// Head commit of the job branch when the review was captured.
    public var headCommit: String?
    /// Further German notes for the reviewer (e.g. auto-committed agent output).
    public var notes: [String]

    public var id: ReviewID { reviewId }

    public init(
        reviewId: ReviewID = ReviewID(), jobId: JobID, diffSummary: DiffSummary, testResults: [TestResult] = [],
        summary: String? = nil, commits: [ReviewCommit] = [], fileChanges: [ReviewFileChange] = [],
        conflict: ReviewConflictInfo? = nil, testSummary: TestRunSummary? = nil, headCommit: String? = nil,
        notes: [String] = []
    ) {
        self.reviewId = reviewId
        self.jobId = jobId
        self.diffSummary = diffSummary
        self.testResults = testResults
        self.decision = .pending
        self.summary = summary
        self.commits = commits
        self.fileChanges = fileChanges
        self.conflict = conflict
        self.testSummary = testSummary
        self.headCommit = headCommit
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case reviewId, jobId, diffSummary, testResults, decision, approvedAt, integrationCommit, integrationStrategy
        case summary, commits, fileChanges, conflict, testSummary, headCommit, notes
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reviewId = try c.decode(ReviewID.self, forKey: .reviewId)
        jobId = try c.decode(JobID.self, forKey: .jobId)
        diffSummary = try c.decode(DiffSummary.self, forKey: .diffSummary)
        testResults = try c.decodeIfPresent([TestResult].self, forKey: .testResults) ?? []
        decision = try c.decode(ReviewDecision.self, forKey: .decision)
        approvedAt = try c.decodeIfPresent(Date.self, forKey: .approvedAt)
        integrationCommit = try c.decodeIfPresent(String.self, forKey: .integrationCommit)
        integrationStrategy = try c.decodeIfPresent(IntegrationStrategy.self, forKey: .integrationStrategy)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        commits = try c.decodeIfPresent([ReviewCommit].self, forKey: .commits) ?? []
        fileChanges = try c.decodeIfPresent([ReviewFileChange].self, forKey: .fileChanges) ?? []
        conflict = try c.decodeIfPresent(ReviewConflictInfo.self, forKey: .conflict)
        testSummary = try c.decodeIfPresent(TestRunSummary.self, forKey: .testSummary)
        headCommit = try c.decodeIfPresent(String.self, forKey: .headCommit)
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
    }

    public var allTestsPassed: Bool {
        !testResults.isEmpty && testResults.allSatisfy { $0.outcome == .passed || $0.outcome == .skipped }
    }

    public var effectiveTestSummary: TestRunSummary { testSummary ?? TestRunSummary(results: testResults) }

    public mutating func decide(_ decision: ReviewDecision, at date: Date) {
        self.decision = decision
        approvedAt = decision == .approved ? date : nil
    }

    public mutating func recordIntegration(commit: String, strategy: IntegrationStrategy) throws(ReviewError) {
        guard decision == .approved else { throw .notApproved(decision) }
        if let integrationCommit { throw .alreadyIntegrated(integrationCommit) }
        guard !commit.trimmingCharacters(in: .whitespaces).isEmpty else { throw .emptyCommitHash }
        integrationCommit = commit
        integrationStrategy = strategy
        conflict = nil
    }
}

// MARK: - SyncOperation

public enum SyncOperationType: String, Hashable, Sendable, Codable, CaseIterable {
    case create
    case update
    /// Tombstone (spec N3).
    case delete
}

public enum SyncOperationState: String, Hashable, Sendable, Codable, CaseIterable {
    case pending
    case inFlight
    case succeeded
    case failed
    case conflict
}

/// Idempotent outbox/inbox operation (spec N3).
public struct SyncOperation: Hashable, Sendable, Codable, Identifiable {
    public let operationId: SyncOperationID
    public let entityId: UUID
    public let entityType: String
    public let type: SyncOperationType
    /// Entity revision this operation carries.
    public let version: Int
    public var state: SyncOperationState
    public private(set) var attempts: Int
    public private(set) var lastError: String?

    public var id: SyncOperationID { operationId }

    public init(
        operationId: SyncOperationID = SyncOperationID(),
        entityId: UUID,
        entityType: String,
        type: SyncOperationType,
        version: Int,
        state: SyncOperationState = .pending
    ) {
        self.operationId = operationId
        self.entityId = entityId
        self.entityType = entityType
        self.type = type
        self.version = version
        self.state = state
        self.attempts = 0
    }

    public mutating func recordAttempt(error: String?) {
        attempts += 1
        lastError = error
        state = error == nil ? .succeeded : .failed
    }
}

// MARK: - GitHubIssueLink

/// Optional GitHub issue link; the local request file stays authoritative (ADR-0016).
public struct GitHubIssueLink: Hashable, Sendable, Codable {
    public let workItemId: WorkItemID
    /// `owner/name`
    public var repo: String
    public var issueNumber: Int
    public var url: String
    public var lastSyncedRevision: Int

    public init(workItemId: WorkItemID, repo: String, issueNumber: Int, url: String, lastSyncedRevision: Int) {
        self.workItemId = workItemId
        self.repo = repo
        self.issueNumber = issueNumber
        self.url = url
        self.lastSyncedRevision = lastSyncedRevision
    }
}
