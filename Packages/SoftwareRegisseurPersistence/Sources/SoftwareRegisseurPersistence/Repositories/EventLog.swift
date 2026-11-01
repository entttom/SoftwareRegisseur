import Foundation
import GRDB
import SoftwareRegisseurDomain

/// Append-only task history (spec M2). Updates and deletes are rejected by database triggers.
public protocol EventLog: Sendable {
    func append(_ event: TaskEvent) async throws
    func events(forWorkItem id: WorkItemID) async throws -> [TaskEvent]
    func events(since date: Date, limit: Int) async throws -> [TaskEvent]
}

enum EventLogWriter {
    /// Appends within the caller's transaction, including the outbox entry (events sync, spec N1).
    static func append(_ db: Database, _ event: TaskEvent, at date: Date) throws {
        if try TaskEventStorage.fetch(db, syncID: event.eventId.rawValue) != nil { return }
        try SyncBookkeeping.save(db, TaskEventStorage.self, event, isNew: true, at: date)
    }

    static func append(
        _ db: Database, workItem: WorkItem, kind: TaskEventKind, actor: EventActor,
        payload: [String: String] = [:], at date: Date
    ) throws {
        let event = TaskEvent(
            workItemId: workItem.uuid, kind: kind, actor: actor, timestamp: date,
            payload: payload, sourceRevision: workItem.revision
        )
        try append(db, event, at: date)
    }
}

public struct GRDBEventLog: EventLog {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Idempotent: appending an event ID twice keeps the first.
    public func append(_ event: TaskEvent) async throws {
        try await database.write { db in try EventLogWriter.append(db, event, at: event.timestamp) }
    }

    public func events(forWorkItem id: WorkItemID) async throws -> [TaskEvent] {
        try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM task_events WHERE work_item_id = ? ORDER BY timestamp, rowid",
                             arguments: [id.databaseText]).map(TaskEventStorage.decode)
        }
    }

    public func events(since date: Date, limit: Int = 500) async throws -> [TaskEvent] {
        try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM task_events WHERE timestamp >= ? ORDER BY timestamp, rowid LIMIT ?",
                             arguments: [StoredDate.value(date), limit]).map(TaskEventStorage.decode)
        }
    }
}
