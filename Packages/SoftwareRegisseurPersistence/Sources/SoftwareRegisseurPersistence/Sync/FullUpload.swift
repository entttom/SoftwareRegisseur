import Foundation
import GRDB
import SoftwareRegisseurDomain

/// Enumeration of everything that syncs, and re-queueing it for a full upload after the server copy
/// was lost (zone purged or deleted, encrypted data reset, switch to another iCloud account).
extension GRDBSyncStore {
    /// Entity kinds that can leave the device, in a stable order (parents before children where
    /// it matters for readers on other devices: projects and settings first).
    static let enumerationOrder: [SyncEntityType] = SyncEntityType.allCases.filter { !$0.isDeviceLocal }

    /// Pages through all locally stored entities that sync (spec N1), with their current payload and
    /// versions. `limit` bounds the number of stored rows inspected per call, so a page may hold fewer
    /// entities (non-syncing values such as device-only provider profiles are skipped).
    public func syncableEntities(after cursor: SyncEntityCursor?, limit: Int) async throws -> SyncableEntityPage {
        try await database.read { db in
            var entities: [SyncableEntity] = []
            let next = try Self.scan(db, after: cursor, limit: limit) { type, id in
                guard let payload = try type.syncablePayload(db, id: id) else { return }
                entities.append(SyncableEntity(
                    entityType: type, entityId: id, payload: payload,
                    version: try SyncBookkeeping.entityVersion(db, type, id)
                ))
            }
            return SyncableEntityPage(entities: entities, next: next)
        }
    }

    /// Every locally stored entity kind: the syncing kinds in `enumerationOrder`, then the device-local
    /// kinds (audio notes), so a reader sees parents before children and device-only data last.
    public static let storedEntityOrder: [SyncEntityType] =
        enumerationOrder + SyncEntityType.allCases.filter(\.isDeviceLocal)

    /// Pages through **all** locally stored entities, including values that never leave the device
    /// (device-local kinds such as audio notes, device-only provider profiles), with their current
    /// payload in the canonical sync format (data export, spec Q1/A34). Read-only; works on a read-only
    /// database as well. Keyset paging like `syncableEntities`: `limit` bounds the rows read per call and
    /// `next` is nil when everything was visited. A cursor returned by `syncableEntities` is accepted too.
    public func storedEntities(after cursor: SyncEntityCursor?, limit: Int) async throws -> StoredEntityPage {
        try await database.read { db in
            var entities: [StoredEntity] = []
            let next = try Self.scan(db, after: cursor, limit: limit, order: Self.storedEntityOrder) { type, id in
                // Rows can vanish between the ID scan and the read only across transactions; skip them.
                guard let payload = try type.fetchPayload(db, id: id) else { return }
                entities.append(StoredEntity(
                    entityType: type, entityId: id, payload: payload,
                    syncs: try type.syncsEntity(db, id: id) ?? false
                ))
            }
            return StoredEntityPage(entities: entities, next: next)
        }
    }

    /// Re-queues every syncable entity into the outbox, one batch (one transaction) per call. Start with
    /// `cursor == nil`; continue with `progress.next` until `isComplete`. The first batch also forgets
    /// all stored server change tags, because the records they refer to no longer exist.
    ///
    /// Each entity gets a normal outbox operation (local version + 1, based on its synced version), so
    /// other devices that still hold the entity fast-forward or, with unsent edits of their own, get a
    /// visible conflict instead of a silent overwrite. Entities that already have an unsent operation are
    /// skipped, which makes an interrupted re-upload safe to repeat.
    public func requeueForFullUpload(after cursor: SyncEntityCursor?, batchSize: Int, at date: Date = .now) async throws -> FullUploadProgress {
        try await database.write { db in
            if cursor == nil {
                try db.execute(sql: "UPDATE sync_entity_state SET system_fields = NULL, updated_at = ?",
                               arguments: [StoredDate.value(date)])
            }
            var requeued = 0
            var alreadyQueued = 0
            let next = try Self.scan(db, after: cursor, limit: batchSize) { type, id in
                guard try type.syncsEntity(db, id: id) == true else { return }
                if try SyncBookkeeping.hasOutstandingOperation(db, type, id) {
                    alreadyQueued += 1
                    return
                }
                let state = try SyncBookkeeping.entityVersion(db, type, id)
                let kind: SyncOperationType = (state?.syncedVersion ?? 0) > 0 ? .update : .create
                try SyncBookkeeping.enqueue(db, type, id, kind: kind, at: date)
                requeued += 1
            }
            return FullUploadProgress(requeued: requeued, alreadyQueued: alreadyQueued, next: next)
        }
    }

    /// Visits up to `limit` stored sync IDs after `cursor` in `enumerationOrder`, ordered by ID within a
    /// kind (keyset paging). Returns the cursor to continue from, or nil when everything was visited.
    static func scan(
        _ db: Database, after cursor: SyncEntityCursor?, limit: Int, order: [SyncEntityType] = enumerationOrder,
        _ visit: (SyncEntityType, UUID) throws -> Void
    ) throws -> SyncEntityCursor? {
        var remaining = max(limit, 1)
        var typeIndex = cursor.flatMap { order.firstIndex(of: $0.entityType) } ?? 0
        if let cursor, !order.contains(cursor.entityType) { return nil }
        var after = cursor?.afterEntityId
        while typeIndex < order.count {
            let type = order[typeIndex]
            let (table, column) = type.syncIDSource
            let ids: [String]
            if let after {
                ids = try String.fetchAll(db, sql: "SELECT \(column) FROM \(table) WHERE \(column) > ? ORDER BY \(column) LIMIT ?",
                                          arguments: [after.uuidString, remaining])
            } else {
                ids = try String.fetchAll(db, sql: "SELECT \(column) FROM \(table) ORDER BY \(column) LIMIT ?",
                                          arguments: [remaining])
            }
            for text in ids {
                guard let id = UUID(uuidString: text) else {
                    throw StoreError.corruptValue(column: "\(table).\(column)", detail: "invalid UUID '\(text)'")
                }
                try visit(type, id)
            }
            remaining -= ids.count
            if remaining == 0, let last = ids.last.flatMap(UUID.init(uuidString:)) {
                return SyncEntityCursor(entityType: type, afterEntityId: last)
            }
            typeIndex += 1
            after = nil
        }
        return nil
    }
}
