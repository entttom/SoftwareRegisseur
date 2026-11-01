import Foundation
import GRDB
import SoftwareRegisseurDomain

/// Persistence-managed sync versions of one entity (spec N3). `localVersion` grows with every local
/// write; `syncedVersion` is the version last confirmed by / received from CloudKit. A difference
/// means unsent local changes.
public struct SyncEntityVersion: Hashable, Sendable {
    public let entityType: SyncEntityType
    public let entityId: UUID
    public let localVersion: Int
    public let syncedVersion: Int
    public let systemFields: Data?
    /// Last synced payload (common ancestor for 3-way merges); nil if unknown or deleted.
    public let ancestorPayload: Data?
    /// Version whose payload `ancestorPayload` is; nil if unknown.
    public let ancestorVersion: Int?

    public var hasUnsentChanges: Bool { localVersion > syncedVersion }
}

public enum TombstoneOrigin: String, Hashable, Sendable, Codable {
    case local
    case remote
}

/// Deletion marker that prevents stale records from resurrecting deleted entities (spec N3).
public struct SyncTombstone: Hashable, Sendable {
    public let entityType: SyncEntityType
    public let entityId: UUID
    public let version: Int
    public let origin: TombstoneOrigin
    public let deletedAt: Date
}

/// Internal helpers that run inside the caller's transaction, so the outbox entry commits or rolls
/// back together with the entity write.
enum SyncBookkeeping {
    static func entityVersion(_ db: Database, _ type: SyncEntityType, _ id: UUID) throws -> SyncEntityVersion? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT * FROM sync_entity_state WHERE entity_type = ? AND entity_id = ?
            """, arguments: [type.rawValue, id.uuidString]) else { return nil }
        return SyncEntityVersion(
            entityType: type,
            entityId: id,
            localVersion: try row.int("local_version"),
            syncedVersion: try row.int("synced_version"),
            systemFields: row["system_fields"],
            ancestorPayload: row["ancestor_payload"],
            ancestorVersion: row.optionalInt("ancestor_version")
        )
    }

    /// Records the payload of the version both sides now share (`nil` for a deletion). Separate from
    /// `setVersion`, so writes that only bump versions keep working on every schema version.
    static func setAncestor(_ db: Database, _ type: SyncEntityType, _ id: UUID, payload: Data?, version: Int) throws {
        try db.execute(sql: """
            UPDATE sync_entity_state SET ancestor_payload = ?, ancestor_version = ?
            WHERE entity_type = ? AND entity_id = ?
            """, arguments: [payload, version, type.rawValue, id.uuidString])
    }

    /// Whether an unsent outbox operation (pending, failed or in flight) exists for the entity.
    static func hasOutstandingOperation(_ db: Database, _ type: SyncEntityType, _ id: UUID) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM sync_outbox WHERE entity_type = ? AND entity_id = ?
                          AND state IN ('pending', 'failed', 'inFlight'))
            """, arguments: [type.rawValue, id.uuidString]) ?? false
    }

    static func setVersion(
        _ db: Database, _ type: SyncEntityType, _ id: UUID,
        local: Int, synced: Int, systemFields: Data?? = .none, at date: Date
    ) throws {
        let existing = try entityVersion(db, type, id)
        let fields: Data? =
            switch systemFields {
            case let .some(value): value
            case .none: existing?.systemFields
            }
        try db.upsert(into: "sync_entity_state", [
            "entity_type": type.rawValue,
            "entity_id": id.uuidString,
            "local_version": local,
            "synced_version": synced,
            "system_fields": fields,
            "updated_at": StoredDate.value(date),
        ], conflictKeys: ["entity_type", "entity_id"])
    }

    /// Bumps the local version and appends an outbox operation.
    @discardableResult
    static func enqueue(_ db: Database, _ type: SyncEntityType, _ id: UUID, kind: SyncOperationType, at date: Date) throws -> SyncOperation {
        let current = try entityVersion(db, type, id)
        let version = (current?.localVersion ?? 0) + 1
        try setVersion(db, type, id, local: version, synced: current?.syncedVersion ?? 0, at: date)
        let operation = SyncOperation(entityId: id, entityType: type.rawValue, type: kind, version: version)
        try db.insert(into: "sync_outbox", [
            "operation_id": operation.operationId.databaseText,
            "entity_type": type.rawValue,
            "entity_id": id.uuidString,
            "change_kind": kind.rawValue,
            "version": version,
            "state": SyncOperationState.pending.rawValue,
            "attempts": 0,
            "last_error": nil,
            "created_at": StoredDate.value(date),
            "updated_at": StoredDate.value(date),
        ])
        return operation
    }

    /// Writes the entity and, if it syncs, its outbox entry.
    static func save<S: EntityStorage>(_ db: Database, _ storage: S.Type, _ entity: S.Entity, isNew: Bool, at date: Date) throws {
        try S.save(db, entity)
        let id = S.syncID(of: entity)
        if S.shouldSync(entity) {
            try enqueue(db, S.entityType, id, kind: isNew ? .create : .update, at: date)
        } else if try entityVersion(db, S.entityType, id) != nil {
            // Previously synced value became device-local: remove it remotely, keep it here.
            try enqueue(db, S.entityType, id, kind: .delete, at: date)
            try db.execute(sql: "DELETE FROM sync_entity_state WHERE entity_type = ? AND entity_id = ?",
                           arguments: [S.entityType.rawValue, id.uuidString])
        }
    }

    /// Deletes the entity locally, records a tombstone and enqueues the remote deletion.
    static func delete<S: EntityStorage>(_ db: Database, _ storage: S.Type, syncID id: UUID, at date: Date) throws {
        guard let entity = try S.fetch(db, syncID: id) else {
            throw StoreError.notFound(entity: S.entityType, id: id.uuidString)
        }
        try S.delete(db, syncID: id)
        guard S.shouldSync(entity) else { return }
        let operation = try enqueue(db, S.entityType, id, kind: .delete, at: date)
        try writeTombstone(db, S.entityType, id, version: operation.version, origin: .local, at: date)
    }

    static func writeTombstone(_ db: Database, _ type: SyncEntityType, _ id: UUID, version: Int, origin: TombstoneOrigin, at date: Date) throws {
        try db.upsert(into: "sync_tombstones", [
            "entity_type": type.rawValue,
            "entity_id": id.uuidString,
            "version": version,
            "origin": origin.rawValue,
            "deleted_at": StoredDate.value(date),
        ], conflictKeys: ["entity_type", "entity_id"])
    }

    static func tombstone(_ db: Database, _ type: SyncEntityType, _ id: UUID) throws -> SyncTombstone? {
        try Row.fetchOne(db, sql: "SELECT * FROM sync_tombstones WHERE entity_type = ? AND entity_id = ?",
                         arguments: [type.rawValue, id.uuidString]).map(decodeTombstone)
    }

    static func decodeTombstone(_ row: Row) throws -> SyncTombstone {
        SyncTombstone(
            entityType: try row.enumValue("entity_type"),
            entityId: try row.uuid("entity_id"),
            version: try row.int("version"),
            origin: try row.enumValue("origin"),
            deletedAt: try row.date("deleted_at")
        )
    }
}

// Generic entry points that open the `any EntityStorage.Type` existential.
extension SyncEntityType {
    func fetchPayload(_ db: Database, id: UUID) throws -> Data? {
        func open<S: EntityStorage>(_ storage: S.Type) throws -> Data? { try S.fetchPayload(db, syncID: id) }
        return try open(storage)
    }

    func savePayload(_ db: Database, _ data: Data, id: UUID) throws {
        func open<S: EntityStorage>(_ storage: S.Type) throws { try S.savePayload(db, data, expectedSyncID: id) }
        try open(storage)
    }

    func deleteEntity(_ db: Database, id: UUID) throws {
        func open<S: EntityStorage>(_ storage: S.Type) throws { try S.delete(db, syncID: id) }
        try open(storage)
    }

    func entityExists(_ db: Database, id: UUID) throws -> Bool {
        func open<S: EntityStorage>(_ storage: S.Type) throws -> Bool { try S.exists(db, syncID: id) }
        return try open(storage)
    }

    /// nil if the entity does not exist locally; otherwise whether it syncs (spec N1).
    func syncsEntity(_ db: Database, id: UUID) throws -> Bool? {
        func open<S: EntityStorage>(_ storage: S.Type) throws -> Bool? {
            try S.fetch(db, syncID: id).map(S.shouldSync)
        }
        return try open(storage)
    }

    /// Current sync payload if the entity exists and syncs.
    func syncablePayload(_ db: Database, id: UUID) throws -> Data? {
        func open<S: EntityStorage>(_ storage: S.Type) throws -> Data? {
            guard let entity = try S.fetch(db, syncID: id), S.shouldSync(entity) else { return nil }
            return try S.payloadData(entity)
        }
        return try open(storage)
    }

    /// Table and column holding the sync ID of every stored entity of this kind (enumeration).
    var syncIDSource: (table: String, column: String) {
        switch self {
        case .project: ("projects", "id")
        case .projectSettings: ("project_settings", "id")
        case .repositoryLocation: ("repository_locations", "sync_id")
        case .workItem: ("work_items", "uuid")
        case .adr: ("adrs", "uuid")
        case .audioNote: ("audio_notes", "id")
        case .aiRequest: ("ai_requests", "id")
        case .aiConversation: ("ai_conversations", "id")
        case .agentHost: ("agent_hosts", "host_id")
        case .agentCapability: ("agent_capabilities", "sync_id")
        case .agentModelPreference: ("agent_model_preferences", "sync_id")
        case .agentJob: ("agent_jobs", "job_id")
        case .taskLock: ("task_locks", "lock_id")
        case .taskEvent: ("task_events", "event_id")
        case .review: ("reviews", "review_id")
        case .gitHubIssueLink: ("github_issue_links", "work_item_id")
        case .providerProfile: ("provider_profiles", "id")
        case .projectSetupCommand: ("project_setup_commands", "id")
        case .indexedFolder: ("indexed_folders", "id")
        case .fileConflict: ("file_conflicts", "id")
        case .pendingApproval: ("pending_approvals", "id")
        case .approvalDecision: ("approval_decisions", "id")
        case .draftVersion: ("draft_versions", "id")
        case .globalSettings: ("global_settings", "id")
        }
    }

    func validatePayload(_ data: Data, id: UUID) throws {
        func open<S: EntityStorage>(_ storage: S.Type) throws {
            let entity = try S.decodePayload(data)
            guard S.syncID(of: entity) == id else {
                throw StoreError.invalidRemoteChange("\(rawValue) payload ID does not match entity ID")
            }
        }
        try open(storage)
    }
}

extension SyncBookkeeping {
    /// Upsert with outbox entry; `create` if the entity did not exist before.
    @discardableResult
    static func upsert<S: EntityStorage>(_ db: Database, _ storage: S.Type, _ entity: S.Entity, at date: Date) throws -> Bool {
        let isNew = try S.fetch(db, syncID: S.syncID(of: entity)) == nil
        try save(db, storage, entity, isNew: isNew, at: date)
        return isNew
    }
}
