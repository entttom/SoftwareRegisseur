import Foundation
import GRDB
import SoftwareRegisseurDomain

// Row mapping of the v4 sync entities. Entities with `private(set)` fields are stored as their JSON
// payload next to indexed columns (same convention as the v3 workspace tables).

enum ProjectSetupCommandStorage: EntityStorage {
    typealias Entity = ProjectSetupCommand
    static let entityType = SyncEntityType.projectSetupCommand

    static func syncID(of entity: ProjectSetupCommand) -> UUID { entity.id.rawValue }

    static func fetch(_ db: Database, syncID: UUID) throws -> ProjectSetupCommand? {
        try String.fetchOne(db, sql: "SELECT payload FROM project_setup_commands WHERE id = ?", arguments: [syncID.uuidString])
            .map { try JSONColumn.decode(ProjectSetupCommand.self, from: $0) }
    }

    static func save(_ db: Database, _ c: ProjectSetupCommand) throws {
        try db.upsert(into: "project_setup_commands", [
            "id": c.id.databaseText,
            "project_id": c.projectId.databaseText,
            "host_id": c.hostId?.databaseText,
            "state": c.state.rawValue,
            "payload": try JSONColumn.encode(c),
            "revision": c.revision,
            "created_at": StoredDate.value(c.createdAt),
            "updated_at": StoredDate.value(c.updatedAt),
        ], conflictKeys: ["id"])
    }

    static func delete(_ db: Database, syncID: UUID) throws {
        try db.execute(sql: "DELETE FROM project_setup_commands WHERE id = ?", arguments: [syncID.uuidString])
    }
}

enum IndexedFolderStorage: EntityStorage {
    typealias Entity = IndexedFolder
    static let entityType = SyncEntityType.indexedFolder

    static func syncID(of entity: IndexedFolder) -> UUID { entity.id.rawValue }

    static func fetch(_ db: Database, syncID: UUID) throws -> IndexedFolder? {
        try String.fetchOne(db, sql: "SELECT payload FROM indexed_folders WHERE id = ?", arguments: [syncID.uuidString])
            .map { try JSONColumn.decode(IndexedFolder.self, from: $0) }
    }

    static func fetch(_ db: Database, hostId: HostID, path: String) throws -> IndexedFolder? {
        try String.fetchOne(db, sql: "SELECT payload FROM indexed_folders WHERE host_id = ? AND canonical_path = ?",
                            arguments: [hostId.databaseText, path])
            .map { try JSONColumn.decode(IndexedFolder.self, from: $0) }
    }

    /// Upsert by ID. A row of the same host and path with another ID (replaced on the Mac) is removed
    /// first, so the Mac's latest record wins (Mac authoritative, spec N2).
    static func save(_ db: Database, _ f: IndexedFolder) throws {
        try db.execute(sql: "DELETE FROM indexed_folders WHERE host_id = ? AND canonical_path = ? AND id <> ?",
                       arguments: [f.hostId.databaseText, f.canonicalPath, f.id.databaseText])
        try db.upsert(into: "indexed_folders", [
            "id": f.id.databaseText,
            "host_id": f.hostId.databaseText,
            "canonical_path": f.canonicalPath,
            "kind": f.kind.rawValue,
            "project_id": f.projectId?.databaseText,
            "repository_identity": f.repositoryIdentity?.rawValue,
            "is_selectable": f.isSelectable,
            "is_available": f.isAvailable,
            "payload": try JSONColumn.encode(f),
            "last_seen_at": StoredDate.value(f.lastSeenAt),
        ], conflictKeys: ["id"])
    }

    static func delete(_ db: Database, syncID: UUID) throws {
        try db.execute(sql: "DELETE FROM indexed_folders WHERE id = ?", arguments: [syncID.uuidString])
    }
}

enum FileConflictStorage: EntityStorage {
    typealias Entity = FileConflict
    static let entityType = SyncEntityType.fileConflict

    static func syncID(of entity: FileConflict) -> UUID { entity.id.rawValue }

    static func fetch(_ db: Database, syncID: UUID) throws -> FileConflict? {
        try String.fetchOne(db, sql: "SELECT payload FROM file_conflicts WHERE id = ?", arguments: [syncID.uuidString])
            .map { try JSONColumn.decode(FileConflict.self, from: $0) }
    }

    static func save(_ db: Database, _ c: FileConflict) throws {
        try db.upsert(into: "file_conflicts", [
            "id": c.id.databaseText,
            "project_id": c.projectId.databaseText,
            "work_item_id": c.workItemId?.databaseText,
            "adr_id": c.adrId?.databaseText,
            "kind": c.kind.rawValue,
            "payload": try JSONColumn.encode(c),
            "detected_at": StoredDate.value(c.detectedAt),
            "resolved_at": StoredDate.value(c.resolvedAt),
        ], conflictKeys: ["id"])
    }

    static func delete(_ db: Database, syncID: UUID) throws {
        try db.execute(sql: "DELETE FROM file_conflicts WHERE id = ?", arguments: [syncID.uuidString])
    }
}

enum PendingApprovalStorage: EntityStorage {
    typealias Entity = PendingApproval
    static let entityType = SyncEntityType.pendingApproval

    static func syncID(of entity: PendingApproval) -> UUID { entity.id.rawValue }

    static func decode(_ payload: String) throws -> PendingApproval {
        try JSONColumn.decode(PendingApproval.self, from: payload)
    }

    static func fetch(_ db: Database, syncID: UUID) throws -> PendingApproval? {
        try String.fetchOne(db, sql: "SELECT payload FROM pending_approvals WHERE id = ?", arguments: [syncID.uuidString]).map(decode)
    }

    static func save(_ db: Database, _ a: PendingApproval) throws {
        try db.upsert(into: "pending_approvals", [
            "id": a.id.databaseText,
            "job_id": a.jobId.databaseText,
            "work_item_id": a.workItemId.databaseText,
            "host_id": a.hostId.databaseText,
            "request_id": a.requestId,
            "state": a.state.rawValue,
            "requested_at": StoredDate.value(a.requestedAt),
            "expires_at": StoredDate.value(a.expiresAt),
            "payload": try JSONColumn.encode(a),
            "revision": a.revision,
            "updated_at": StoredDate.value(a.updatedAt),
        ], conflictKeys: ["id"])
    }

    static func delete(_ db: Database, syncID: UUID) throws {
        try db.execute(sql: "DELETE FROM pending_approvals WHERE id = ?", arguments: [syncID.uuidString])
    }
}

enum ApprovalDecisionStorage: EntityStorage {
    typealias Entity = ApprovalDecision
    static let entityType = SyncEntityType.approvalDecision

    static func syncID(of entity: ApprovalDecision) -> UUID { entity.id.rawValue }

    static func decode(_ payload: String) throws -> ApprovalDecision {
        try JSONColumn.decode(ApprovalDecision.self, from: payload)
    }

    static func fetch(_ db: Database, syncID: UUID) throws -> ApprovalDecision? {
        try String.fetchOne(db, sql: "SELECT payload FROM approval_decisions WHERE id = ?", arguments: [syncID.uuidString]).map(decode)
    }

    /// Immutable: an existing decision ID is left untouched (idempotent replay).
    static func save(_ db: Database, _ d: ApprovalDecision) throws {
        try db.upsert(into: "approval_decisions", [
            "id": d.id.databaseText,
            "approval_id": d.approvalId.databaseText,
            "job_id": d.jobId.databaseText,
            "decision": d.decision.rawValue,
            "decided_by": d.decidedBy.databaseText,
            "decided_at": StoredDate.value(d.decidedAt),
            "payload": try JSONColumn.encode(d),
        ], conflictKeys: ["id"], ignoreExisting: true)
    }

    static func delete(_ db: Database, syncID: UUID) throws {
        try db.execute(sql: "DELETE FROM approval_decisions WHERE id = ?", arguments: [syncID.uuidString])
    }
}

enum DraftVersionStorage: EntityStorage {
    typealias Entity = DraftVersion
    static let entityType = SyncEntityType.draftVersion

    static func syncID(of entity: DraftVersion) -> UUID { entity.id.rawValue }

    static func decode(_ payload: String) throws -> DraftVersion {
        try JSONColumn.decode(DraftVersion.self, from: payload)
    }

    static func fetch(_ db: Database, syncID: UUID) throws -> DraftVersion? {
        try String.fetchOne(db, sql: "SELECT payload FROM draft_versions WHERE id = ?", arguments: [syncID.uuidString]).map(decode)
    }

    static func save(_ db: Database, _ v: DraftVersion) throws {
        try db.upsert(into: "draft_versions", [
            "id": v.id.databaseText,
            "work_item_id": v.workItemId.databaseText,
            "version": v.version,
            "source": v.source.rawValue,
            "created_at": StoredDate.value(v.createdAt),
            "accepted_at": StoredDate.value(v.acceptedAt),
            "payload": try JSONColumn.encode(v),
            "revision": v.revision,
            "updated_at": StoredDate.value(v.updatedAt),
        ], conflictKeys: ["id"])
    }

    static func delete(_ db: Database, syncID: UUID) throws {
        try db.execute(sql: "DELETE FROM draft_versions WHERE id = ?", arguments: [syncID.uuidString])
    }
}

enum GlobalSettingsStorage: EntityStorage {
    typealias Entity = GlobalSettings
    static let entityType = SyncEntityType.globalSettings

    static func syncID(of entity: GlobalSettings) -> UUID { entity.id.rawValue }

    static func fetch(_ db: Database, syncID: UUID) throws -> GlobalSettings? {
        try String.fetchOne(db, sql: "SELECT payload FROM global_settings WHERE id = ?", arguments: [syncID.uuidString])
            .map { try JSONColumn.decode(GlobalSettings.self, from: $0) }
    }

    static func save(_ db: Database, _ s: GlobalSettings) throws {
        try db.upsert(into: "global_settings", [
            "id": s.id.databaseText,
            "payload": try JSONColumn.encode(s),
            "revision": s.revision,
            "updated_at": StoredDate.value(s.updatedAt),
        ], conflictKeys: ["id"])
    }

    static func delete(_ db: Database, syncID: UUID) throws {
        try db.execute(sql: "DELETE FROM global_settings WHERE id = ?", arguments: [syncID.uuidString])
    }
}
