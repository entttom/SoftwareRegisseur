import Foundation
import GRDB
import SoftwareRegisseurDomain

// MARK: - Approvals (spec J6 V1 fallback, L3)

/// Pending approvals are written by the Mac host only; decisions by user devices only. Decisions are
/// immutable; the host consumes each approval's first applicable decision exactly once.
public protocol ApprovalRepository: Sendable {
    /// Upsert of a host-owned approval (new or state change).
    func save(_ approval: PendingApproval, at date: Date) async throws
    func fetch(_ id: PendingApprovalID) async throws -> PendingApproval?
    func approvals(jobId: JobID) async throws -> [PendingApproval]
    /// Open approvals, optionally of one host, oldest first.
    func openApprovals(hostId: HostID?) async throws -> [PendingApproval]
    /// Records a user decision. Idempotent per decision ID; rejected for unknown or closed approvals.
    func recordDecision(_ decision: ApprovalDecision) async throws
    /// Like `recordDecision`, for a decision made on the execution host after the full approval text was
    /// shown there and the user explicitly confirmed it (SR-SEC-08): checked against
    /// `PendingApproval.hostReviewedDecisions` instead of `allowedDecisions`. Never call it for synced
    /// decisions of other devices.
    func recordHostReviewedDecision(_ decision: ApprovalDecision) async throws
    func decisions(approvalId: PendingApprovalID) async throws -> [ApprovalDecision]
}

extension ApprovalRepository {
    /// Conservative default for other conformers: the same checks as a synced decision.
    public func recordHostReviewedDecision(_ decision: ApprovalDecision) async throws {
        try await recordDecision(decision)
    }
}

public struct GRDBApprovalRepository: ApprovalRepository {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func save(_ approval: PendingApproval, at date: Date = .now) async throws {
        try await database.write { db in
            if let stored = try PendingApprovalStorage.fetch(db, syncID: approval.id.rawValue) {
                guard stored.jobId == approval.jobId, stored.requestId == approval.requestId else {
                    throw StoreError.identityFieldChanged(entity: .pendingApproval, field: "jobId/requestId")
                }
                if stored == approval { return }
                guard approval.revision > stored.revision else {
                    throw StoreError.revisionConflict(entity: .pendingApproval, id: approval.id.uuidString,
                                                      expected: stored.revision, actual: approval.revision)
                }
            }
            _ = try SyncBookkeeping.upsert(db, PendingApprovalStorage.self, approval, at: date)
        }
    }

    public func fetch(_ id: PendingApprovalID) async throws -> PendingApproval? {
        try await database.read { db in try PendingApprovalStorage.fetch(db, syncID: id.rawValue) }
    }

    public func approvals(jobId: JobID) async throws -> [PendingApproval] {
        try await database.read { db in
            try String.fetchAll(db, sql: "SELECT payload FROM pending_approvals WHERE job_id = ? ORDER BY requested_at, id",
                                arguments: [jobId.databaseText]).map(PendingApprovalStorage.decode)
        }
    }

    public func openApprovals(hostId: HostID? = nil) async throws -> [PendingApproval] {
        try await database.read { db in
            if let hostId {
                return try String.fetchAll(db, sql: """
                    SELECT payload FROM pending_approvals WHERE state = 'pending' AND host_id = ? ORDER BY requested_at, id
                    """, arguments: [hostId.databaseText]).map(PendingApprovalStorage.decode)
            }
            return try String.fetchAll(db, sql: "SELECT payload FROM pending_approvals WHERE state = 'pending' ORDER BY requested_at, id")
                .map(PendingApprovalStorage.decode)
        }
    }

    public func recordDecision(_ decision: ApprovalDecision) async throws {
        try await record(decision, hostReviewed: false)
    }

    public func recordHostReviewedDecision(_ decision: ApprovalDecision) async throws {
        try await record(decision, hostReviewed: true)
    }

    private func record(_ decision: ApprovalDecision, hostReviewed: Bool) async throws {
        try await database.write { db in
            if try ApprovalDecisionStorage.fetch(db, syncID: decision.id.rawValue) != nil { return }
            guard let approval = try PendingApprovalStorage.fetch(db, syncID: decision.approvalId.rawValue),
                  approval.jobId == decision.jobId
            else { throw StoreError.notFound(entity: .pendingApproval, id: decision.approvalId.uuidString) }
            guard approval.isOpen else { throw StoreError.approvalClosed(approval.id, approval.state) }
            let permitted = hostReviewed ? approval.hostReviewedDecisions : approval.remoteDecisions
            guard permitted.contains(decision.decision) else {
                throw StoreError.approvalDecisionNotAllowed(approval.id, decision.decision)
            }
            try SyncBookkeeping.save(db, ApprovalDecisionStorage.self, decision, isNew: true, at: decision.decidedAt)
        }
    }

    public func decisions(approvalId: PendingApprovalID) async throws -> [ApprovalDecision] {
        try await database.read { db in
            try String.fetchAll(db, sql: "SELECT payload FROM approval_decisions WHERE approval_id = ? ORDER BY decided_at, id",
                                arguments: [approvalId.databaseText]).map(ApprovalDecisionStorage.decode)
        }
    }
}

// MARK: - Draft versions (spec H3)

public protocol DraftVersionRepository: Sendable {
    func save(_ version: DraftVersion, at date: Date) async throws
    func fetch(_ id: DraftVersionID) async throws -> DraftVersion?
    /// All versions of a work item ordered by version, then creation.
    func versions(workItemId: WorkItemID) async throws -> [DraftVersion]
    /// Appends a version with the next free number for the item (in one transaction).
    func append(_ make: @Sendable (_ nextVersion: Int) -> DraftVersion, for workItemId: WorkItemID, at date: Date) async throws -> DraftVersion
    /// Marks contents of a version as adopted (explicit user action).
    func accept(_ id: DraftVersionID, contentIndexes: [Int], at date: Date) async throws -> DraftVersion
}

public struct GRDBDraftVersionRepository: DraftVersionRepository {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func save(_ version: DraftVersion, at date: Date = .now) async throws {
        try await database.write { db in
            if let stored = try DraftVersionStorage.fetch(db, syncID: version.id.rawValue) {
                guard stored.workItemId == version.workItemId, stored.version == version.version, stored.source == version.source else {
                    throw StoreError.identityFieldChanged(entity: .draftVersion, field: "workItemId/version/source")
                }
                if stored == version { return }
            }
            _ = try SyncBookkeeping.upsert(db, DraftVersionStorage.self, version, at: date)
        }
    }

    public func fetch(_ id: DraftVersionID) async throws -> DraftVersion? {
        try await database.read { db in try DraftVersionStorage.fetch(db, syncID: id.rawValue) }
    }

    public func versions(workItemId: WorkItemID) async throws -> [DraftVersion] {
        try await database.read { db in try Self.versions(db, workItemId) }
    }

    public func append(
        _ make: @Sendable (_ nextVersion: Int) -> DraftVersion, for workItemId: WorkItemID, at date: Date = .now
    ) async throws -> DraftVersion {
        try await database.write { db in
            let next = DraftVersion.nextVersion(after: try Self.versions(db, workItemId))
            let version = make(next)
            guard version.workItemId == workItemId else {
                throw StoreError.identityFieldChanged(entity: .draftVersion, field: "workItemId")
            }
            if try DraftVersionStorage.fetch(db, syncID: version.id.rawValue) != nil {
                throw StoreError.alreadyExists(entity: .draftVersion, id: version.id.uuidString)
            }
            try SyncBookkeeping.save(db, DraftVersionStorage.self, version, isNew: true, at: date)
            return version
        }
    }

    public func accept(_ id: DraftVersionID, contentIndexes: [Int], at date: Date = .now) async throws -> DraftVersion {
        try await database.write { db in
            guard var version = try DraftVersionStorage.fetch(db, syncID: id.rawValue) else {
                throw StoreError.notFound(entity: .draftVersion, id: id.uuidString)
            }
            let before = version
            version.accept(contentIndexes: contentIndexes, at: date)
            if version != before {
                try SyncBookkeeping.save(db, DraftVersionStorage.self, version, isNew: false, at: date)
            }
            return version
        }
    }

    static func versions(_ db: Database, _ workItemId: WorkItemID) throws -> [DraftVersion] {
        try String.fetchAll(db, sql: "SELECT payload FROM draft_versions WHERE work_item_id = ? ORDER BY version, created_at, id",
                            arguments: [workItemId.databaseText]).map(DraftVersionStorage.decode)
    }
}

// MARK: - Global settings (spec F2, J2)

public protocol GlobalSettingsRepository: Sendable {
    /// Stored settings, or `GlobalSettings.defaults` (revision 0) if nothing was saved yet.
    func fetch() async throws -> GlobalSettings
    /// Optimistic save; `expectedRevision` 0 creates the record. Returns the stored value (revision bumped).
    func save(_ settings: GlobalSettings, expectedRevision: Int, at date: Date) async throws -> GlobalSettings
}

public struct GRDBGlobalSettingsRepository: GlobalSettingsRepository {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func fetch() async throws -> GlobalSettings {
        try await database.read { db in
            try GlobalSettingsStorage.fetch(db, syncID: GlobalSettings.singletonID.rawValue) ?? .defaults
        }
    }

    public func save(_ settings: GlobalSettings, expectedRevision: Int, at date: Date = .now) async throws -> GlobalSettings {
        try await database.write { db in
            let stored = try GlobalSettingsStorage.fetch(db, syncID: GlobalSettings.singletonID.rawValue)
            let actual = stored?.revision ?? 0
            guard actual == expectedRevision else {
                throw StoreError.revisionConflict(entity: .globalSettings, id: GlobalSettings.singletonID.uuidString,
                                                  expected: expectedRevision, actual: actual)
            }
            guard settings.folderLayout.isValid else {
                throw StoreError.invalidSettings("folderLayout")
            }
            var updated = GlobalSettings(defaultAgentId: settings.defaultAgentId, folderLayout: settings.folderLayout,
                                         workspace: settings.workspace, revision: actual, updatedAt: date)
            updated.touch(at: date)
            if let stored, stored.defaultAgentId == updated.defaultAgentId, stored.folderLayout == updated.folderLayout,
               stored.workspace == updated.workspace {
                return stored
            }
            try SyncBookkeeping.save(db, GlobalSettingsStorage.self, updated, isNew: stored == nil, at: date)
            return updated
        }
    }
}
