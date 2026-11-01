import Foundation
import GRDB
import SoftwareRegisseurDomain

/// Human-readable ID allocation on the Mac host (ADR-0018). Numbers come from a monotonic counter
/// per project and prefix that is raised by every ID seen in request files or the local index, so a
/// number is never handed out twice, even after deletion or renaming.
public protocol HumanIDAllocator: Sendable {
    /// Reserves the next number for `type` in `projectId`. `existingFileIDs` are IDs found in the
    /// repository files (including retired ones).
    func allocate(_ type: WorkItemType, projectId: ProjectID, existingFileIDs: [HumanID], at date: Date) async throws -> HumanID
    /// Allocates and assigns an ID to a work item in one transaction (with event and outbox entry).
    func assign(to workItemId: WorkItemID, existingFileIDs: [HumanID], actor: EventActor, at date: Date) async throws -> WorkItem
    /// Records an ID that already exists in a request file for this item (import, spec E3).
    func adopt(_ humanId: HumanID, for workItemId: WorkItemID, actor: EventActor, at date: Date) async throws -> WorkItem
    /// Raises the counters to cover IDs found in files without assigning anything.
    func observe(_ ids: [HumanID], projectId: ProjectID, at date: Date) async throws
    /// Next ADR number; separate range without prefix (ADR-0018).
    func allocateADRNumber(projectId: ProjectID, existing: [ADRNumber], at date: Date) async throws -> ADRNumber
    func highestAllocated(_ type: WorkItemType, projectId: ProjectID) async throws -> Int
}

enum HumanIDCounters {
    static let adrRangeKey = "ADR"

    static func highest(_ db: Database, projectId: ProjectID, rangeKey: String) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT highest_number FROM human_id_counters WHERE project_id = ? AND range_key = ?",
                         arguments: [projectId.databaseText, rangeKey]) ?? 0
    }

    /// Raises (never lowers) the counter.
    static func observe(_ db: Database, projectId: ProjectID, rangeKey: String, number: Int, at date: Date) throws {
        try db.execute(sql: """
            INSERT INTO human_id_counters (project_id, range_key, highest_number, updated_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(project_id, range_key) DO UPDATE SET
                highest_number = max(highest_number, excluded.highest_number),
                updated_at = excluded.updated_at
            """, arguments: [projectId.databaseText, rangeKey, number, StoredDate.value(date)])
    }

    static func ensureUnused(_ db: Database, _ humanId: HumanID, projectId: ProjectID, excluding id: WorkItemID?) throws {
        let owner = try String.fetchOne(db, sql: "SELECT uuid FROM work_items WHERE project_id = ? AND human_id = ?",
                                        arguments: [projectId.databaseText, humanId.formatted])
        if let owner, owner != id?.databaseText {
            throw StoreError.duplicateHumanID(humanId, projectId: projectId)
        }
    }

    static func allocate(_ db: Database, _ type: WorkItemType, projectId: ProjectID, existingFileIDs: [HumanID], at date: Date) throws -> HumanID {
        let prefix = type.humanIDPrefix
        let indexed = try Int.fetchOne(db, sql: """
            SELECT max(human_id_number) FROM work_items WHERE project_id = ? AND type = ? AND human_id IS NOT NULL
            """, arguments: [projectId.databaseText, type.rawValue]) ?? 0
        let counter = try highest(db, projectId: projectId, rangeKey: prefix)
        let seen = existingFileIDs + [counter, indexed].compactMap { $0 > 0 ? try? HumanID(type: type, number: $0) : nil }
        let next = HumanID.next(for: type, existing: seen)
        try observe(db, projectId: projectId, rangeKey: prefix, number: next.number, at: date)
        return next
    }
}

public struct GRDBHumanIDAllocator: HumanIDAllocator {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func allocate(_ type: WorkItemType, projectId: ProjectID, existingFileIDs: [HumanID] = [], at date: Date = .now) async throws -> HumanID {
        try await database.write { db in
            try HumanIDCounters.allocate(db, type, projectId: projectId, existingFileIDs: existingFileIDs, at: date)
        }
    }

    public func assign(to workItemId: WorkItemID, existingFileIDs: [HumanID] = [], actor: EventActor, at date: Date = .now) async throws -> WorkItem {
        try await database.write { db in
            guard var item = try WorkItemStorage.fetch(db, syncID: workItemId.rawValue) else {
                throw StoreError.notFound(entity: .workItem, id: workItemId.uuidString)
            }
            if let existing = item.humanId { throw StoreError.humanID(.humanIDAlreadyAssigned(existing)) }
            guard let projectId = item.projectId else { throw StoreError.workItemWithoutProject(workItemId) }
            let humanId = try HumanIDCounters.allocate(db, item.type, projectId: projectId, existingFileIDs: existingFileIDs, at: date)
            try Self.store(db, &item, humanId: humanId, actor: actor, at: date)
            return item
        }
    }

    public func adopt(_ humanId: HumanID, for workItemId: WorkItemID, actor: EventActor, at date: Date = .now) async throws -> WorkItem {
        try await database.write { db in
            guard var item = try WorkItemStorage.fetch(db, syncID: workItemId.rawValue) else {
                throw StoreError.notFound(entity: .workItem, id: workItemId.uuidString)
            }
            guard let projectId = item.projectId else { throw StoreError.workItemWithoutProject(workItemId) }
            if item.humanId == humanId { return item }
            try HumanIDCounters.ensureUnused(db, humanId, projectId: projectId, excluding: workItemId)
            try HumanIDCounters.observe(db, projectId: projectId, rangeKey: humanId.type.humanIDPrefix, number: humanId.number, at: date)
            try Self.store(db, &item, humanId: humanId, actor: actor, at: date)
            return item
        }
    }

    public func observe(_ ids: [HumanID], projectId: ProjectID, at date: Date = .now) async throws {
        try await database.write { db in
            for id in ids {
                try HumanIDCounters.observe(db, projectId: projectId, rangeKey: id.type.humanIDPrefix, number: id.number, at: date)
            }
        }
    }

    public func allocateADRNumber(projectId: ProjectID, existing: [ADRNumber] = [], at date: Date = .now) async throws -> ADRNumber {
        try await database.write { db in
            let indexed = try Int.fetchOne(db, sql: "SELECT max(decision_number) FROM adrs WHERE project_id = ?",
                                           arguments: [projectId.databaseText]) ?? 0
            let counter = try HumanIDCounters.highest(db, projectId: projectId, rangeKey: HumanIDCounters.adrRangeKey)
            let seen = existing + [indexed, counter].compactMap { try? ADRNumber($0) }
            let next = ADRNumber.next(after: seen)
            try HumanIDCounters.observe(db, projectId: projectId, rangeKey: HumanIDCounters.adrRangeKey, number: next.value, at: date)
            return next
        }
    }

    public func highestAllocated(_ type: WorkItemType, projectId: ProjectID) async throws -> Int {
        try await database.read { db in try HumanIDCounters.highest(db, projectId: projectId, rangeKey: type.humanIDPrefix) }
    }

    private static func store(_ db: Database, _ item: inout WorkItem, humanId: HumanID, actor: EventActor, at date: Date) throws {
        do throws(WorkItemError) {
            try item.assignHumanID(humanId, at: date)
        } catch {
            throw StoreError.humanID(error)
        }
        try SyncBookkeeping.save(db, WorkItemStorage.self, item, isNew: false, at: date)
        try EventLogWriter.append(db, workItem: item, kind: .humanIDAssigned, actor: actor,
                                  payload: ["humanId": humanId.formatted], at: date)
    }
}
