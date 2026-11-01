import Foundation
import GRDB
import SoftwareRegisseurDomain

/// A change fetched from CloudKit, already decoded by the sync layer into a JSON payload of the
/// domain value (the format produced by `GRDBSyncStore.currentPayload`).
public struct RemoteChange: Hashable, Sendable {
    /// Operation ID written by the sending device; used for replay protection (spec N3).
    public let operationId: SyncOperationID
    public let entityType: SyncEntityType
    public let entityId: UUID
    public let kind: SyncOperationType
    /// Sync version carried by the record.
    public let version: Int
    /// Version the sender's change was based on (its last synced version), if known.
    public let baseVersion: Int?
    /// JSON payload; nil for deletions.
    public let payload: Data?
    /// CKRecord encoded system fields, stored for the next send.
    public let systemFields: Data?

    public init(
        operationId: SyncOperationID,
        entityType: SyncEntityType,
        entityId: UUID,
        kind: SyncOperationType,
        version: Int,
        baseVersion: Int?,
        payload: Data?,
        systemFields: Data? = nil
    ) {
        self.operationId = operationId
        self.entityType = entityType
        self.entityId = entityId
        self.kind = kind
        self.version = version
        self.baseVersion = baseVersion
        self.payload = payload
        self.systemFields = systemFields
    }
}

public enum RemoteApplyOutcome: String, Hashable, Sendable, Codable {
    case applied
    case deleted
    /// Operation ID was applied before (replay protection).
    case duplicate
    /// Older than or equal to what is stored, or older than a tombstone.
    case stale
    /// Both versions kept in `sync_conflicts`; local data unchanged (spec N2, A24).
    case conflict
}

public enum ConflictResolution: Hashable, Sendable {
    case keepLocal
    case acceptRemote
    /// User-merged value as JSON payload (same format as `currentPayload`).
    case merged(Data)

    var storedName: String {
        switch self {
        case .keepLocal: "keepLocal"
        case .acceptRemote: "acceptRemote"
        case .merged: "merged"
        }
    }
}

/// Who resolved a conflict. Automatic resolutions are recorded like user decisions (spec N2: nothing is
/// resolved silently).
public enum ConflictResolver: String, Hashable, Sendable, Codable {
    case user
    /// Non-overlapping edits combined by a 3-way merge against the last synced version.
    case automaticMerge
    /// A fixed per-entity rule (e.g. the execution host owns job state).
    case automaticPolicy
}

/// A detected sync conflict with both versions (spec N2: no silent last-writer-wins).
public struct SyncConflict: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let entityType: SyncEntityType
    public let entityId: UUID
    public let baseVersion: Int?
    public let localVersion: Int
    public let remoteVersion: Int
    /// nil when the entity was deleted locally.
    public let localPayload: Data?
    /// nil when the remote change is a deletion.
    public let remotePayload: Data?
    public let remoteChangeKind: SyncOperationType
    public let remoteOperationId: SyncOperationID
    public let detectedAt: Date
    public let resolvedAt: Date?
    public let resolution: String?
    /// Last version both sides shared (common ancestor for a 3-way merge). nil if unknown (e.g. data
    /// from before schema v2, or the remote change is not based on it); then only the user decides.
    public let ancestorPayload: Data?
    public let ancestorVersion: Int?
    /// nil while open, and for conflicts resolved before schema v2.
    public let resolvedBy: ConflictResolver?

    public var isResolved: Bool { resolvedAt != nil }
}

/// Position in the outbox for paging (`pendingOperations(limit:after:)`). Opaque to callers.
public struct SyncOutboxCursor: Hashable, Sendable, Codable {
    let createdAt: Double
    let rowID: Int64
}

public struct SyncOutboxPage: Sendable {
    /// Pending and failed operations, oldest first.
    public let operations: [SyncOperation]
    /// Cursor for the next page; nil when the outbox has no further entries.
    public let next: SyncOutboxCursor?
}

/// Identity of one synced entity.
public struct SyncEntityKey: Hashable, Sendable, Codable {
    public let entityType: SyncEntityType
    public let entityId: UUID

    public init(entityType: SyncEntityType, entityId: UUID) {
        self.entityType = entityType
        self.entityId = entityId
    }
}

/// Position in the enumeration of all syncable entities (`syncableEntities`, `requeueForFullUpload`).
/// Codable, so a full upload can resume after a crash.
public struct SyncEntityCursor: Hashable, Sendable, Codable {
    public let entityType: SyncEntityType
    /// Last entity ID already handled within `entityType`; nil = start of that kind.
    public let afterEntityId: UUID?

    public init(entityType: SyncEntityType, afterEntityId: UUID?) {
        self.entityType = entityType
        self.afterEntityId = afterEntityId
    }
}

/// A locally stored entity that syncs, with its current payload and versions.
public struct SyncableEntity: Hashable, Sendable {
    public let entityType: SyncEntityType
    public let entityId: UUID
    /// Same format as `currentPayload`.
    public let payload: Data
    /// nil if the entity was never queued or received (no sync state yet).
    public let version: SyncEntityVersion?
}

public struct SyncableEntityPage: Sendable {
    public let entities: [SyncableEntity]
    /// nil when the enumeration is complete.
    public let next: SyncEntityCursor?
}

/// A locally stored entity of any kind (`GRDBSyncStore.storedEntities`), syncing or device-local.
public struct StoredEntity: Hashable, Sendable {
    public let entityType: SyncEntityType
    public let entityId: UUID
    /// Canonical payload (`SyncPayloadCodec`), same format as `currentPayload`.
    public let payload: Data
    /// false for device-local kinds and values that stay on this device (e.g. device-only provider profiles).
    public let syncs: Bool
}

public struct StoredEntityPage: Sendable {
    public let entities: [StoredEntity]
    /// nil when the enumeration is complete.
    public let next: SyncEntityCursor?
}

public struct FullUploadProgress: Hashable, Sendable {
    /// Entities that got a new outbox operation in this batch.
    public let requeued: Int
    /// Entities skipped because an unsent operation already exists (idempotent resume).
    public let alreadyQueued: Int
    /// Continue with this cursor; nil when every syncable entity has been queued.
    public let next: SyncEntityCursor?

    public var isComplete: Bool { next == nil }
}

public protocol SyncStore: Sendable {
    func pendingOperations(limit: Int) async throws -> [SyncOperation]
    /// One page of pending/failed operations after `cursor` (nil = from the start).
    func pendingOperations(limit: Int, after cursor: SyncOutboxCursor?) async throws -> SyncOutboxPage
    /// Pending/failed operations of the given entities, oldest first.
    func pendingOperations(for entities: [SyncEntityKey]) async throws -> [SyncOperation]
    /// Operations not yet confirmed by the server (pending, failed, in flight).
    func unsentOperationCount() async throws -> Int
    /// Returns in-flight operations to `pending` (send failed or was never acknowledged).
    func markPending(_ ids: [SyncOperationID], at date: Date) async throws
    /// Crash recovery: every operation left `inFlight` becomes `pending` again. Returns the count.
    func resetInFlightOperations(at date: Date) async throws -> Int
    func syncableEntities(after cursor: SyncEntityCursor?, limit: Int) async throws -> SyncableEntityPage
    func requeueForFullUpload(after cursor: SyncEntityCursor?, batchSize: Int, at date: Date) async throws -> FullUploadProgress
    func resolveConflict(_ id: UUID, resolution: ConflictResolution, resolvedBy: ConflictResolver, at date: Date) async throws
    func resolvedConflicts(limit: Int) async throws -> [SyncConflict]
    func operation(_ id: SyncOperationID) async throws -> SyncOperation?
    func markInFlight(_ ids: [SyncOperationID], at date: Date) async throws
    func markSent(_ id: SyncOperationID, systemFields: Data?, at date: Date) async throws
    func markFailed(_ id: SyncOperationID, error: String, at date: Date) async throws
    func pruneSucceededOperations(olderThan date: Date) async throws -> Int
    func currentPayload(entityType: SyncEntityType, entityId: UUID) async throws -> Data?
    func entityVersion(entityType: SyncEntityType, entityId: UUID) async throws -> SyncEntityVersion?
    func saveSystemFields(_ data: Data?, entityType: SyncEntityType, entityId: UUID, at date: Date) async throws
    func engineState(scope: String) async throws -> Data?
    func saveEngineState(_ data: Data, scope: String, at date: Date) async throws
    func applyRemoteChanges(_ changes: [RemoteChange], engineState: (scope: String, data: Data)?, at date: Date) async throws -> [RemoteApplyOutcome]
    /// Like `applyRemoteChanges(_:engineState:at:)`, enforcing device ownership on the execution host
    /// first (ADR-0026, SR-SEC-01). A rejected change yields `.stale`, is kept as a resolved
    /// `SyncConflict` with resolution `RemoteOwnershipPolicy.rejectedResolution`, and the local value is
    /// queued again. `ownership == nil` (mobile devices) behaves exactly like the method without it.
    func applyRemoteChanges(
        _ changes: [RemoteChange], engineState: (scope: String, data: Data)?, ownership: RemoteOwnershipPolicy?, at date: Date
    ) async throws -> [RemoteApplyOutcome]
    func hasAppliedOperation(_ id: SyncOperationID) async throws -> Bool
    func tombstone(entityType: SyncEntityType, entityId: UUID) async throws -> SyncTombstone?
    func openConflicts() async throws -> [SyncConflict]
    func conflict(_ id: UUID) async throws -> SyncConflict?
    func resolveConflict(_ id: UUID, resolution: ConflictResolution, at date: Date) async throws
}

extension SyncStore {
    /// Default for stores without ownership support (test doubles): ownership is not enforced.
    public func applyRemoteChanges(
        _ changes: [RemoteChange], engineState: (scope: String, data: Data)?, ownership: RemoteOwnershipPolicy?, at date: Date
    ) async throws -> [RemoteApplyOutcome] {
        try await applyRemoteChanges(changes, engineState: engineState, at: date)
    }
}

/// Storage for the later CKSyncEngine layer (ADR-0019): outbox, inbox, tombstones, system fields,
/// engine state serialization and conflicts. No CloudKit calls happen here.
public struct GRDBSyncStore: SyncStore {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    // MARK: Outbox

    /// Pending and previously failed operations, oldest first.
    public func pendingOperations(limit: Int = 250) async throws -> [SyncOperation] {
        try await pendingOperations(limit: limit, after: nil).operations
    }

    /// Keyset paging over pending and failed operations (oldest first), so a large backlog can be
    /// drained in one run without loading it at once.
    public func pendingOperations(limit: Int, after cursor: SyncOutboxCursor?) async throws -> SyncOutboxPage {
        let limit = max(limit, 1)
        return try await database.read { db in
            let rows: [Row]
            if let cursor {
                rows = try Row.fetchAll(db, sql: """
                    SELECT rowid AS outbox_rowid, * FROM sync_outbox
                    WHERE state IN ('pending', 'failed') AND (created_at, rowid) > (?, ?)
                    ORDER BY created_at, rowid LIMIT ?
                    """, arguments: [cursor.createdAt, cursor.rowID, limit])
            } else {
                rows = try Row.fetchAll(db, sql: """
                    SELECT rowid AS outbox_rowid, * FROM sync_outbox WHERE state IN ('pending', 'failed')
                    ORDER BY created_at, rowid LIMIT ?
                    """, arguments: [limit])
            }
            let operations = try rows.map(Self.decodeOperation)
            let next = rows.count == limit
                ? rows.last.map { SyncOutboxCursor(createdAt: $0["created_at"], rowID: $0["outbox_rowid"]) }
                : nil
            return SyncOutboxPage(operations: operations, next: next)
        }
    }

    public func pendingOperations(for entities: [SyncEntityKey]) async throws -> [SyncOperation] {
        guard !entities.isEmpty else { return [] }
        return try await database.read { db in
            var result: [(Double, Int64, SyncOperation)] = []
            for key in Set(entities) {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT rowid AS outbox_rowid, * FROM sync_outbox
                    WHERE entity_type = ? AND entity_id = ? AND state IN ('pending', 'failed')
                    """, arguments: [key.entityType.rawValue, key.entityId.uuidString])
                for row in rows {
                    result.append((row["created_at"], row["outbox_rowid"], try Self.decodeOperation(row)))
                }
            }
            return result.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
        }
    }

    public func unsentOperationCount() async throws -> Int {
        try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_outbox WHERE state IN ('pending', 'failed', 'inFlight')") ?? 0
        }
    }

    public func markPending(_ ids: [SyncOperationID], at date: Date = .now) async throws {
        guard !ids.isEmpty else { return }
        try await database.write { db in
            for id in ids {
                try db.execute(sql: "UPDATE sync_outbox SET state = 'pending', updated_at = ? WHERE operation_id = ? AND state = 'inFlight'",
                               arguments: [StoredDate.value(date), id.databaseText])
            }
        }
    }

    /// Spec N3 ("nach Absturz wiederholbar"): an operation is `inFlight` only between handing its record
    /// to CloudKit and the acknowledgement. Left over after a crash, it is sent again; the resend is
    /// idempotent because the record carries the same operation ID and version.
    public func resetInFlightOperations(at date: Date = .now) async throws -> Int {
        try await database.write { db in
            try db.execute(sql: "UPDATE sync_outbox SET state = 'pending', updated_at = ? WHERE state = 'inFlight'",
                           arguments: [StoredDate.value(date)])
            return db.changesCount
        }
    }

    public func operation(_ id: SyncOperationID) async throws -> SyncOperation? {
        try await database.read { db in try Self.fetchOperation(db, id) }
    }

    public func markInFlight(_ ids: [SyncOperationID], at date: Date = .now) async throws {
        try await database.write { db in
            for id in ids {
                try db.execute(sql: "UPDATE sync_outbox SET state = 'inFlight', updated_at = ? WHERE operation_id = ?",
                               arguments: [StoredDate.value(date), id.databaseText])
            }
        }
    }

    /// Confirms a sent operation and advances the entity's synced version.
    public func markSent(_ id: SyncOperationID, systemFields: Data?, at date: Date = .now) async throws {
        try await database.write { db in
            guard let operation = try Self.fetchOperation(db, id) else {
                throw StoreError.invalidRemoteChange("unknown outbox operation \(id)")
            }
            try db.execute(sql: """
                UPDATE sync_outbox SET state = 'succeeded', attempts = attempts + 1, last_error = NULL, updated_at = ?
                WHERE operation_id = ?
                """, arguments: [StoredDate.value(date), id.databaseText])
            guard let type = SyncEntityType(rawValue: operation.entityType) else { return }
            if let version = try SyncBookkeeping.entityVersion(db, type, operation.entityId) {
                let synced = max(version.syncedVersion, operation.version)
                try SyncBookkeeping.setVersion(
                    db, type, operation.entityId,
                    local: version.localVersion, synced: synced,
                    systemFields: systemFields.map { .some($0) } ?? .none, at: date
                )
                // The newest local version is now on the server: it is the ancestor of later edits.
                // (If it was edited again meanwhile, the sent payload is no longer known; keep the
                // previous ancestor, whose version then no longer matches and is not used for merging.)
                if operation.version >= version.localVersion, synced == operation.version {
                    let payload = operation.type == .delete ? nil : try type.fetchPayload(db, id: operation.entityId)
                    try SyncBookkeeping.setAncestor(db, type, operation.entityId, payload: payload, version: operation.version)
                }
            }
        }
    }

    public func markFailed(_ id: SyncOperationID, error: String, at date: Date = .now) async throws {
        try await database.write { db in
            try db.execute(sql: """
                UPDATE sync_outbox SET state = 'failed', attempts = attempts + 1, last_error = ?, updated_at = ?
                WHERE operation_id = ?
                """, arguments: [error, StoredDate.value(date), id.databaseText])
        }
    }

    public func pruneSucceededOperations(olderThan date: Date) async throws -> Int {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM sync_outbox WHERE state = 'succeeded' AND updated_at < ?",
                           arguments: [StoredDate.value(date)])
            return db.changesCount
        }
    }

    /// Current JSON payload of an entity for building the outgoing record; nil if deleted.
    public func currentPayload(entityType: SyncEntityType, entityId: UUID) async throws -> Data? {
        try await database.read { db in try entityType.fetchPayload(db, id: entityId) }
    }

    // MARK: Entity state, system fields, engine state

    public func entityVersion(entityType: SyncEntityType, entityId: UUID) async throws -> SyncEntityVersion? {
        try await database.read { db in try SyncBookkeeping.entityVersion(db, entityType, entityId) }
    }

    /// Stores the server change tag of an entity. Never creates sync state for entities that do not
    /// sync (device-local kinds such as audio notes, device-only provider profiles); clearing the fields
    /// of an entity without sync state is a no-op.
    public func saveSystemFields(_ data: Data?, entityType: SyncEntityType, entityId: UUID, at date: Date = .now) async throws {
        guard !entityType.isDeviceLocal else { return }
        try await database.write { db in
            let version = try SyncBookkeeping.entityVersion(db, entityType, entityId)
            if version == nil {
                if data == nil { return }
                if try entityType.syncsEntity(db, id: entityId) == false { return }
            }
            try SyncBookkeeping.setVersion(
                db, entityType, entityId,
                local: version?.localVersion ?? 0, synced: version?.syncedVersion ?? 0,
                systemFields: .some(data), at: date
            )
        }
    }

    public func engineState(scope: String) async throws -> Data? {
        try await database.read { db in
            try Data.fetchOne(db, sql: "SELECT serialization FROM sync_engine_state WHERE scope = ?", arguments: [scope])
        }
    }

    public func saveEngineState(_ data: Data, scope: String, at date: Date = .now) async throws {
        try await database.write { db in try Self.writeEngineState(db, data, scope: scope, at: date) }
    }

    // MARK: Inbox

    public func hasAppliedOperation(_ id: SyncOperationID) async throws -> Bool {
        try await database.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sync_inbox WHERE operation_id = ?)",
                              arguments: [id.databaseText]) ?? false
        }
    }

    public func tombstone(entityType: SyncEntityType, entityId: UUID) async throws -> SyncTombstone? {
        try await database.read { db in try SyncBookkeeping.tombstone(db, entityType, entityId) }
    }

    /// Applies fetched changes and the engine state that covers them in one transaction
    /// (CKSyncEngine requires the state to be persisted alongside the fetched changes).
    public func applyRemoteChanges(
        _ changes: [RemoteChange],
        engineState: (scope: String, data: Data)? = nil,
        at date: Date = .now
    ) async throws -> [RemoteApplyOutcome] {
        try await applyRemoteChanges(changes, engineState: engineState, ownership: nil, at: date)
    }

    public func applyRemoteChanges(
        _ changes: [RemoteChange],
        engineState: (scope: String, data: Data)? = nil,
        ownership: RemoteOwnershipPolicy?,
        at date: Date = .now
    ) async throws -> [RemoteApplyOutcome] {
        try await database.write { db in
            let outcomes = try changes.map { try Self.apply($0, db, ownership: ownership, at: date) }
            if let engineState {
                try Self.writeEngineState(db, engineState.data, scope: engineState.scope, at: date)
            }
            return outcomes
        }
    }

    // MARK: Conflicts

    public func openConflicts() async throws -> [SyncConflict] {
        try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM sync_conflicts WHERE resolved_at IS NULL ORDER BY detected_at, rowid")
                .map(Self.decodeConflict)
        }
    }

    public func conflict(_ id: UUID) async throws -> SyncConflict? {
        try await database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM sync_conflicts WHERE conflict_id = ?", arguments: [id.uuidString])
                .map(Self.decodeConflict)
        }
    }

    /// Resolves a conflict explicitly (user decision). `keepLocal`/`merged` re-send a version newer
    /// than the remote one; `acceptRemote` adopts the remote value.
    public func resolveConflict(_ id: UUID, resolution: ConflictResolution, at date: Date = .now) async throws {
        try await resolveConflict(id, resolution: resolution, resolvedBy: .user, at: date)
    }

    /// Like `resolveConflict(_:resolution:at:)`, recording who resolved it. Automatic resolutions of a
    /// work item additionally append an `edited` event to its history (spec N2, A24: transparent).
    public func resolveConflict(_ id: UUID, resolution: ConflictResolution, resolvedBy: ConflictResolver, at date: Date = .now) async throws {
        try await database.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM sync_conflicts WHERE conflict_id = ?", arguments: [id.uuidString]) else {
                throw StoreError.invalidRemoteChange("unknown conflict \(id)")
            }
            let conflict = try Self.decodeConflict(row)
            guard !conflict.isResolved else { throw StoreError.conflictAlreadyResolved(id) }
            let remoteFields: Data? = row["remote_system_fields"]
            let type = conflict.entityType
            let entityId = conflict.entityId
            let current = try SyncBookkeeping.entityVersion(db, type, entityId)
            let localVersion = current?.localVersion ?? conflict.localVersion

            // Outstanding operations carry the superseded local version.
            try db.execute(sql: """
                UPDATE sync_outbox SET state = 'conflict', updated_at = ?
                WHERE entity_type = ? AND entity_id = ? AND state IN ('pending', 'failed', 'inFlight')
                """, arguments: [StoredDate.value(date), type.rawValue, entityId.uuidString])

            switch resolution {
            case .acceptRemote:
                if let payload = conflict.remotePayload {
                    try type.savePayload(db, payload, id: entityId)
                    try db.execute(sql: "DELETE FROM sync_tombstones WHERE entity_type = ? AND entity_id = ?",
                                   arguments: [type.rawValue, entityId.uuidString])
                } else {
                    if try type.entityExists(db, id: entityId) { try type.deleteEntity(db, id: entityId) }
                    try SyncBookkeeping.writeTombstone(db, type, entityId, version: conflict.remoteVersion, origin: .remote, at: date)
                }
                try SyncBookkeeping.setVersion(db, type, entityId, local: conflict.remoteVersion, synced: conflict.remoteVersion,
                                               systemFields: .some(remoteFields), at: date)
                try SyncBookkeeping.setAncestor(db, type, entityId, payload: conflict.remotePayload, version: conflict.remoteVersion)
            case .keepLocal, .merged:
                if case let .merged(payload) = resolution {
                    try type.savePayload(db, payload, id: entityId)
                    try db.execute(sql: "DELETE FROM sync_tombstones WHERE entity_type = ? AND entity_id = ?",
                                   arguments: [type.rawValue, entityId.uuidString])
                }
                // Base the re-sent change on the remote version, so it supersedes it.
                let base = max(localVersion, conflict.remoteVersion)
                try SyncBookkeeping.setVersion(db, type, entityId, local: base, synced: conflict.remoteVersion,
                                               systemFields: .some(remoteFields), at: date)
                // The server holds the remote version until the re-sent change is confirmed.
                try SyncBookkeeping.setAncestor(db, type, entityId, payload: conflict.remotePayload, version: conflict.remoteVersion)
                let exists = try type.entityExists(db, id: entityId)
                let operation = try SyncBookkeeping.enqueue(db, type, entityId, kind: exists ? .update : .delete, at: date)
                if !exists {
                    try SyncBookkeeping.writeTombstone(db, type, entityId, version: operation.version, origin: .local, at: date)
                }
            }
            try db.execute(sql: "UPDATE sync_conflicts SET resolved_at = ?, resolution = ?, resolved_by = ? WHERE conflict_id = ?",
                           arguments: [StoredDate.value(date), resolution.storedName, resolvedBy.rawValue, id.uuidString])
            if resolvedBy != .user, type == .workItem, let item = try WorkItemStorage.fetch(db, syncID: entityId) {
                var payload = [
                    "conflictId": id.uuidString,
                    "resolution": resolution.storedName,
                    "resolvedBy": resolvedBy.rawValue,
                ]
                if let localPayload = conflict.localPayload,
                   let before = try? JSONColumn.decode(WorkItem.self, from: localPayload) {
                    payload["fields"] = GRDBWorkItemRepository.changedFields(before, item).joined(separator: ",")
                }
                try EventLogWriter.append(db, workItem: item, kind: .edited, actor: .external, payload: payload, at: date)
            }
        }
    }

    /// Most recently resolved conflicts first (history of user and automatic resolutions).
    public func resolvedConflicts(limit: Int = 100) async throws -> [SyncConflict] {
        try await database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM sync_conflicts WHERE resolved_at IS NOT NULL ORDER BY resolved_at DESC, rowid DESC LIMIT ?
                """, arguments: [limit]).map(Self.decodeConflict)
        }
    }

    // MARK: Internals

    static func apply(_ change: RemoteChange, _ db: Database, ownership: RemoteOwnershipPolicy? = nil, at date: Date) throws -> RemoteApplyOutcome {
        let alreadySeen = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sync_inbox WHERE operation_id = ?)",
                                            arguments: [change.operationId.databaseText]) ?? false
        if alreadySeen { return .duplicate }

        let outcome = try decideAndApply(change, db, ownership: ownership, at: date)
        try db.insert(into: "sync_inbox", [
            "operation_id": change.operationId.databaseText,
            "entity_type": change.entityType.rawValue,
            "entity_id": change.entityId.uuidString,
            "change_kind": change.kind.rawValue,
            "version": change.version,
            "base_version": change.baseVersion,
            "outcome": outcome.rawValue,
            "received_at": StoredDate.value(date),
        ])
        return outcome
    }

    /// Conflict rule (spec N2/N3): a remote change is applied only if this device has no unsent local
    /// changes for the entity. With unsent changes (local version ahead of the synced version, which
    /// therefore differs from the remote change's base) both versions are kept as a `SyncConflict`.
    /// Without local changes a newer remote version fast-forwards even if intermediate versions were
    /// never received (CloudKit only delivers the latest record).
    private static func decideAndApply(
        _ change: RemoteChange, _ db: Database, ownership: RemoteOwnershipPolicy?, at date: Date
    ) throws -> RemoteApplyOutcome {
        let type = change.entityType
        let id = change.entityId
        if change.kind != .delete {
            guard let payload = change.payload else {
                throw StoreError.invalidRemoteChange("\(type.rawValue) \(change.kind.rawValue) without payload")
            }
            try type.validatePayload(payload, id: id)
        }

        let state = try SyncBookkeeping.entityVersion(db, type, id)
        let tombstone = try SyncBookkeeping.tombstone(db, type, id)
        let exists = try type.entityExists(db, id: id)
        let hasLocalChanges = state?.hasUnsentChanges ?? false

        if change.kind == .delete, !exists {
            // Already gone here (deleted on both sides, or never received): converge. A pending local
            // deletion is thereby confirmed.
            let version = max(change.version, state?.localVersion ?? 0, tombstone?.version ?? 0)
            try SyncBookkeeping.setVersion(db, type, id, local: version, synced: version,
                                           systemFields: .some(change.systemFields), at: date)
            try SyncBookkeeping.setAncestor(db, type, id, payload: nil, version: version)
            try SyncBookkeeping.writeTombstone(db, type, id, version: version, origin: tombstone?.origin ?? .remote, at: date)
            try db.execute(sql: """
                UPDATE sync_outbox SET state = 'succeeded', updated_at = ?
                WHERE entity_type = ? AND entity_id = ? AND state IN ('pending', 'failed', 'inFlight')
                """, arguments: [StoredDate.value(date), type.rawValue, id.uuidString])
            return .deleted
        }
        if let tombstone, change.version <= tombstone.version { return .stale }
        if let state, change.version <= state.syncedVersion { return .stale }

        // ADR-0026 / SR-SEC-01: ownership first, independent of local edits or conflicts.
        if let ownership, let reason = try ownership.violation(of: change, db) {
            try rejectForOwnership(change, db, state: state, exists: exists, reason: reason, at: date)
            return .stale
        }

        if hasLocalChanges || tombstone?.origin == .local {
            // Same content on both sides (e.g. two devices re-uploading after a zone loss): converge
            // instead of reporting a conflict. Nothing is lost, so this is not last-writer-wins.
            if change.kind != .delete, exists, let payload = change.payload,
               try type.fetchPayload(db, id: id) == payload {
                let local = max(state?.localVersion ?? 0, change.version)
                try SyncBookkeeping.setVersion(db, type, id, local: local, synced: change.version,
                                               systemFields: .some(change.systemFields), at: date)
                try SyncBookkeeping.setAncestor(db, type, id, payload: payload, version: change.version)
                if local == change.version {
                    try db.execute(sql: """
                        UPDATE sync_outbox SET state = 'succeeded', updated_at = ?
                        WHERE entity_type = ? AND entity_id = ? AND state IN ('pending', 'failed', 'inFlight')
                        """, arguments: [StoredDate.value(date), type.rawValue, id.uuidString])
                }
                return .applied
            }
            try recordConflict(change, db, state: state, at: date)
            return .conflict
        }

        switch change.kind {
        case .create, .update:
            try type.savePayload(db, change.payload!, id: id)
            try db.execute(sql: "DELETE FROM sync_tombstones WHERE entity_type = ? AND entity_id = ?",
                           arguments: [type.rawValue, id.uuidString])
            try SyncBookkeeping.setVersion(db, type, id, local: change.version, synced: change.version,
                                           systemFields: .some(change.systemFields), at: date)
            try SyncBookkeeping.setAncestor(db, type, id, payload: change.payload, version: change.version)
            return .applied
        case .delete:
            if exists { try type.deleteEntity(db, id: id) }
            try SyncBookkeeping.writeTombstone(db, type, id, version: change.version, origin: .remote, at: date)
            try SyncBookkeeping.setVersion(db, type, id, local: change.version, synced: change.version,
                                           systemFields: .some(change.systemFields), at: date)
            try SyncBookkeeping.setAncestor(db, type, id, payload: nil, version: change.version)
            return .deleted
        }
    }

    /// Keeps a rejected change as a resolved conflict and re-asserts the host's own value on the server.
    private static func rejectForOwnership(
        _ change: RemoteChange, _ db: Database, state: SyncEntityVersion?, exists: Bool, reason: String, at date: Date
    ) throws {
        let type = change.entityType
        let id = change.entityId
        try db.insert(into: "sync_conflicts", [
            "conflict_id": UUID().uuidString,
            "entity_type": type.rawValue,
            "entity_id": id.uuidString,
            "base_version": change.baseVersion,
            "local_version": state?.localVersion ?? 0,
            "remote_version": change.version,
            "local_payload": try type.fetchPayload(db, id: id),
            "remote_payload": change.payload,
            "remote_change_kind": change.kind.rawValue,
            "remote_operation_id": change.operationId.databaseText,
            "remote_system_fields": change.systemFields,
            "detected_at": StoredDate.value(date),
            "resolved_at": StoredDate.value(date),
            "resolution": RemoteOwnershipPolicy.rejectedResolution,
            "ancestor_payload": nil,
            "ancestor_version": nil,
            "resolved_by": ConflictResolver.automaticPolicy.rawValue,
        ])
        // The server now holds the foreign value: send ours on top of it (like `keepLocal`).
        guard exists, try type.syncsEntity(db, id: id) != false else { return }
        try db.execute(sql: """
            UPDATE sync_outbox SET state = 'conflict', updated_at = ?
            WHERE entity_type = ? AND entity_id = ? AND state IN ('pending', 'failed', 'inFlight')
            """, arguments: [StoredDate.value(date), type.rawValue, id.uuidString])
        let base = max(state?.localVersion ?? 0, change.version)
        try SyncBookkeeping.setVersion(db, type, id, local: base, synced: change.version,
                                       systemFields: .some(change.systemFields), at: date)
        try SyncBookkeeping.setAncestor(db, type, id, payload: change.payload, version: change.version)
        _ = try SyncBookkeeping.enqueue(db, type, id, kind: .update, at: date)
    }

    private static func recordConflict(_ change: RemoteChange, _ db: Database, state: SyncEntityVersion?, at date: Date) throws {
        let conflictId = UUID()
        let localPayload = try change.entityType.fetchPayload(db, id: change.entityId)
        // The stored ancestor is the common base only if it is the synced version and the remote change
        // descends from it (its base is that version or a later one this device never received).
        var ancestor: (payload: Data?, version: Int?) = (nil, nil)
        if let state, let ancestorVersion = state.ancestorVersion, ancestorVersion == state.syncedVersion,
           let base = change.baseVersion, base >= ancestorVersion {
            ancestor = (state.ancestorPayload, ancestorVersion)
        }
        try db.insert(into: "sync_conflicts", [
            "conflict_id": conflictId.uuidString,
            "entity_type": change.entityType.rawValue,
            "entity_id": change.entityId.uuidString,
            "base_version": change.baseVersion,
            "local_version": state?.localVersion ?? 0,
            "remote_version": change.version,
            "local_payload": localPayload,
            "remote_payload": change.payload,
            "remote_change_kind": change.kind.rawValue,
            "remote_operation_id": change.operationId.databaseText,
            "remote_system_fields": change.systemFields,
            "detected_at": StoredDate.value(date),
            "resolved_at": nil,
            "resolution": nil,
            "ancestor_payload": ancestor.payload,
            "ancestor_version": ancestor.version,
            "resolved_by": nil,
        ])
        // Make the conflict visible in the task history (A24).
        if change.entityType == .workItem, let item = try WorkItemStorage.fetch(db, syncID: change.entityId) {
            let event = TaskEvent(
                workItemId: item.uuid,
                kind: .conflictDetected,
                actor: .external,
                timestamp: date,
                payload: ["conflictId": conflictId.uuidString, "remoteVersion": String(change.version)],
                sourceRevision: item.revision
            )
            try EventLogWriter.append(db, event, at: date)
        }
    }

    static func writeEngineState(_ db: Database, _ data: Data, scope: String, at date: Date) throws {
        try db.upsert(into: "sync_engine_state", [
            "scope": scope,
            "serialization": data,
            "updated_at": StoredDate.value(date),
        ], conflictKeys: ["scope"])
    }

    static func fetchOperation(_ db: Database, _ id: SyncOperationID) throws -> SyncOperation? {
        try Row.fetchOne(db, sql: "SELECT * FROM sync_outbox WHERE operation_id = ?", arguments: [id.databaseText])
            .map(decodeOperation)
    }

    static func decodeOperation(_ row: Row) throws -> SyncOperation {
        let fields: [String: (any Encodable)?] = [
            "operationId": try row.uuid("operation_id"),
            "entityId": try row.uuid("entity_id"),
            "entityType": try row.string("entity_type"),
            "type": try row.string("change_kind"),
            "version": try row.int("version"),
            "state": try row.string("state"),
            "attempts": try row.int("attempts"),
            "lastError": row["last_error"] as String?,
        ]
        do {
            return try DomainBridge.make(SyncOperation.self, fields)
        } catch {
            throw StoreError.corruptValue(column: "sync_outbox", detail: "\(error)")
        }
    }

    static func decodeConflict(_ row: Row) throws -> SyncConflict {
        SyncConflict(
            id: try row.uuid("conflict_id"),
            entityType: try row.enumValue("entity_type"),
            entityId: try row.uuid("entity_id"),
            baseVersion: row.optionalInt("base_version"),
            localVersion: try row.int("local_version"),
            remoteVersion: try row.int("remote_version"),
            localPayload: row["local_payload"],
            remotePayload: row["remote_payload"],
            remoteChangeKind: try row.enumValue("remote_change_kind"),
            remoteOperationId: try row.id("remote_operation_id"),
            detectedAt: try row.date("detected_at"),
            resolvedAt: row.optionalDate("resolved_at"),
            resolution: row["resolution"],
            ancestorPayload: row["ancestor_payload"],
            ancestorVersion: row.optionalInt("ancestor_version"),
            resolvedBy: try row.optionalEnum("resolved_by")
        )
    }
}
