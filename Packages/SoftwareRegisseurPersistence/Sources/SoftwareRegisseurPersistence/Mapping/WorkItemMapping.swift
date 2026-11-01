import Foundation
import GRDB
import SoftwareRegisseurDomain

extension Priority {
    var storedRank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        case .urgent: 3
        }
    }
}

/// Spec O: execution metadata in `work_items`, user-editable text in `work_item_texts`.
enum WorkItemStorage: EntityStorage {
    typealias Entity = WorkItem
    static let entityType = SyncEntityType.workItem

    static let selectSQL = """
        SELECT w.*, t.title, t.original_note, t.transcript, t.structured_body
        FROM work_items w JOIN work_item_texts t ON t.work_item_id = w.uuid
        """

    static func syncID(of entity: WorkItem) -> UUID { entity.uuid.rawValue }

    static func decode(_ row: Row) throws -> WorkItem {
        let humanId: HumanID? = try (row["human_id"] as String?).map { raw in
            do { return try HumanID(parsing: raw) } catch {
                throw StoreError.corruptValue(column: "human_id", detail: "\(error)")
            }
        }
        return WorkItem(
            uuid: try row.id("uuid"),
            humanId: humanId,
            projectId: try row.optionalID("project_id"),
            type: try row.enumValue("type"),
            title: try row.string("title"),
            originalNote: try row.string("original_note"),
            transcript: row["transcript"],
            structuredBody: try row.string("structured_body"),
            status: try row.enumValue("status"),
            priority: try row.enumValue("priority"),
            complexity: try row.optionalEnum("complexity"),
            labels: try row.json("labels"),
            dependencies: try row.json("dependencies"),
            agentJobIds: try row.json("agent_job_ids"),
            reviewState: try row.enumValue("review_state"),
            // v4 column; absent (nil) on databases migrated only to v1–v3.
            archivedAt: row.hasColumn("archived_at") ? row.optionalDate("archived_at") : nil,
            revision: try row.int("revision"),
            createdAt: try row.date("created_at"),
            updatedAt: try row.date("updated_at")
        )
    }

    static func fetch(_ db: Database, syncID: UUID) throws -> WorkItem? {
        try Row.fetchOne(db, sql: "\(selectSQL) WHERE w.uuid = ?", arguments: [syncID.uuidString]).map(decode)
    }

    static func save(_ db: Database, _ w: WorkItem) throws {
        try db.upsert(into: "work_items", [
            "uuid": w.uuid.databaseText,
            "project_id": w.projectId?.databaseText,
            "type": w.type.rawValue,
            "human_id": w.humanId?.formatted,
            "human_id_number": w.humanId?.number,
            "status": w.status.rawValue,
            "priority": w.priority.rawValue,
            "priority_rank": w.priority.storedRank,
            "complexity": w.complexity?.rawValue,
            "labels": try JSONColumn.encode(w.labels),
            "dependencies": try JSONColumn.encode(w.dependencies),
            "agent_job_ids": try JSONColumn.encode(w.agentJobIds),
            "review_state": w.reviewState.rawValue,
            "revision": w.revision,
            "created_at": StoredDate.value(w.createdAt),
            "updated_at": StoredDate.value(w.updatedAt),
        ], conflictKeys: ["uuid"])
        // `archived_at` exists from v4 on; writes keep working on older schema versions (migration tests).
        if try db.hasColumn("archived_at", in: "work_items") {
            try db.execute(sql: "UPDATE work_items SET archived_at = ? WHERE uuid = ?",
                           arguments: [StoredDate.value(w.archivedAt), w.uuid.databaseText])
        }
        try db.upsert(into: "work_item_texts", [
            "work_item_id": w.uuid.databaseText,
            "title": w.title,
            "original_note": w.originalNote,
            "transcript": w.transcript,
            "structured_body": w.structuredBody,
        ], conflictKeys: ["work_item_id"])
    }

    static func delete(_ db: Database, syncID: UUID) throws {
        // work_item_texts cascades.
        try db.execute(sql: "DELETE FROM work_items WHERE uuid = ?", arguments: [syncID.uuidString])
    }
}

enum ADRStorage: EntityStorage {
    typealias Entity = ADR
    static let entityType = SyncEntityType.adr

    static func syncID(of entity: ADR) -> UUID { entity.uuid.rawValue }

    static func decode(_ row: Row) throws -> ADR {
        func number(_ value: Int) throws -> ADRNumber {
            do { return try ADRNumber(value) } catch {
                throw StoreError.corruptValue(column: "decision_number", detail: "\(error)")
            }
        }
        return ADR(
            uuid: try row.id("uuid"),
            projectId: try row.id("project_id"),
            decisionNumber: try number(row.int("decision_number")),
            title: try row.string("title"),
            status: try row.enumValue("status"),
            date: row.optionalDate("date"),
            context: try row.string("context"),
            decision: try row.string("decision"),
            alternatives: try row.string("alternatives"),
            consequences: try row.string("consequences"),
            supersedes: try row.json("supersedes"),
            supersededBy: try row.optionalInt("superseded_by").map(number),
            revision: try row.int("revision"),
            createdAt: try row.date("created_at"),
            updatedAt: try row.date("updated_at")
        )
    }

    static func fetch(_ db: Database, syncID: UUID) throws -> ADR? {
        try Row.fetchOne(db, sql: "SELECT * FROM adrs WHERE uuid = ?", arguments: [syncID.uuidString]).map(decode)
    }

    static func save(_ db: Database, _ a: ADR) throws {
        try db.upsert(into: "adrs", [
            "uuid": a.uuid.databaseText,
            "project_id": a.projectId.databaseText,
            "decision_number": a.decisionNumber.value,
            "title": a.title,
            "status": a.status.rawValue,
            "date": StoredDate.value(a.date),
            "context": a.context,
            "decision": a.decision,
            "alternatives": a.alternatives,
            "consequences": a.consequences,
            "supersedes": try JSONColumn.encode(a.supersedes),
            "superseded_by": a.supersededBy?.value,
            "revision": a.revision,
            "created_at": StoredDate.value(a.createdAt),
            "updated_at": StoredDate.value(a.updatedAt),
        ], conflictKeys: ["uuid"])
    }

    static func delete(_ db: Database, syncID: UUID) throws {
        try db.execute(sql: "DELETE FROM adrs WHERE uuid = ?", arguments: [syncID.uuidString])
    }
}

enum TaskEventStorage: EntityStorage {
    typealias Entity = TaskEvent
    static let entityType = SyncEntityType.taskEvent

    static func syncID(of entity: TaskEvent) -> UUID { entity.eventId.rawValue }

    static func decode(_ row: Row) throws -> TaskEvent {
        TaskEvent(
            eventId: try row.id("event_id"),
            workItemId: try row.id("work_item_id"),
            kind: try row.enumValue("kind"),
            actor: try row.json("actor"),
            timestamp: try row.date("timestamp"),
            payload: try row.json("payload"),
            sourceRevision: try row.int("source_revision")
        )
    }

    static func fetch(_ db: Database, syncID: UUID) throws -> TaskEvent? {
        try Row.fetchOne(db, sql: "SELECT * FROM task_events WHERE event_id = ?", arguments: [syncID.uuidString]).map(decode)
    }

    /// Append-only: an existing event ID is left untouched (idempotent replay).
    static func save(_ db: Database, _ e: TaskEvent) throws {
        try db.upsert(into: "task_events", [
            "event_id": e.eventId.databaseText,
            "work_item_id": e.workItemId.databaseText,
            "kind": e.kind.rawValue,
            "actor": try JSONColumn.encode(e.actor),
            "timestamp": StoredDate.value(e.timestamp),
            "payload": try JSONColumn.encode(e.payload),
            "source_revision": e.sourceRevision,
        ], conflictKeys: ["event_id"], ignoreExisting: true)
    }

    static func delete(_ db: Database, syncID: UUID) throws {
        // Events are never deleted; the append-only trigger would reject it.
        throw StoreError.invalidRemoteChange("task events are append-only")
    }
}
