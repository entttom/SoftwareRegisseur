import Foundation
import GRDB
import SoftwareRegisseurDomain

public struct WorkItemFilter: Hashable, Sendable {
    public enum ProjectScope: Hashable, Sendable {
        case any
        /// Items without project (inbox, spec F1).
        case withoutProject
        case project(ProjectID)
    }

    /// Archived items (spec H1). Archiving is not a status (ADR-0012).
    public enum ArchiveScope: Hashable, Sendable {
        case any
        case activeOnly
        case archivedOnly
    }

    public var project: ProjectScope
    public var archive: ArchiveScope
    public var statuses: Set<WorkItemStatus>
    public var types: Set<WorkItemType>
    public var label: String?
    public var priorities: Set<Priority>
    /// Full-text search (prefix match) over title, original note, transcript and body.
    public var text: String?
    public var limit: Int?

    public init(
        project: ProjectScope = .any,
        statuses: Set<WorkItemStatus> = [],
        types: Set<WorkItemType> = [],
        label: String? = nil,
        priorities: Set<Priority> = [],
        text: String? = nil,
        limit: Int? = nil,
        archive: ArchiveScope = .any
    ) {
        self.project = project
        self.archive = archive
        self.statuses = statuses
        self.types = types
        self.label = label
        self.priorities = priorities
        self.text = text
        self.limit = limit
    }
}

public protocol WorkItemRepository: Sendable {
    func insert(_ item: WorkItem, actor: EventActor, at date: Date) async throws
    func fetch(_ id: WorkItemID) async throws -> WorkItem?
    func list(_ filter: WorkItemFilter) async throws -> [WorkItem]
    /// Optimistic update: fails with `revisionConflict` if the stored revision is not `expectedRevision`.
    func update(_ item: WorkItem, expectedRevision: Int, actor: EventActor, at date: Date) async throws -> WorkItem
    func update(
        _ id: WorkItemID, expectedRevision: Int, actor: EventActor, at date: Date,
        _ mutate: @Sendable (inout WorkItem) throws -> Void
    ) async throws -> WorkItem
    /// User status change; rejected while a job is active (ADR-0012).
    func changeStatus(_ id: WorkItemID, to status: WorkItemStatus, expectedRevision: Int, actor: EventActor, at date: Date) async throws -> WorkItem
    /// Host-side status step such as `implementation_finished → review` or `review → integrated → done`.
    func applyHostStatus(_ id: WorkItemID, to status: WorkItemStatus, actor: EventActor, at date: Date) async throws -> WorkItem
    func delete(_ id: WorkItemID, expectedRevision: Int, at date: Date) async throws
    func hasActiveJob(_ id: WorkItemID) async throws -> Bool
    /// Type change (spec H3/F1) with revision bump and `typeChanged` event; refused once the Mac
    /// assigned a human ID or while a job is active.
    func reclassify(_ id: WorkItemID, to type: WorkItemType, expectedRevision: Int, actor: EventActor, at date: Date) async throws -> WorkItem
    /// Archives (`true`) or restores (`false`) an item with `archived`/`unarchived` event. Not a status change.
    func setArchived(_ id: WorkItemID, _ archived: Bool, expectedRevision: Int, actor: EventActor, at date: Date) async throws -> WorkItem
}

public struct GRDBWorkItemRepository: WorkItemRepository {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func insert(_ item: WorkItem, actor: EventActor, at date: Date = .now) async throws {
        try await database.write { db in try Self.insert(db, item, actor: actor, at: date) }
    }

    public func fetch(_ id: WorkItemID) async throws -> WorkItem? {
        try await database.read { db in try WorkItemStorage.fetch(db, syncID: id.rawValue) }
    }

    public func list(_ filter: WorkItemFilter) async throws -> [WorkItem] {
        try await database.read { db in try Self.list(db, filter) }
    }

    public func update(_ item: WorkItem, expectedRevision: Int, actor: EventActor, at date: Date = .now) async throws -> WorkItem {
        try await database.write { db in
            let stored = try Self.fetchForUpdate(db, item.uuid, expectedRevision: expectedRevision)
            return try Self.store(db, stored: stored, updated: item, expectedRevision: expectedRevision, actor: actor, at: date)
        }
    }

    public func update(
        _ id: WorkItemID, expectedRevision: Int, actor: EventActor, at date: Date = .now,
        _ mutate: @Sendable (inout WorkItem) throws -> Void
    ) async throws -> WorkItem {
        try await database.write { db in
            let stored = try Self.fetchForUpdate(db, id, expectedRevision: expectedRevision)
            var updated = stored
            try mutate(&updated)
            return try Self.store(db, stored: stored, updated: updated, expectedRevision: expectedRevision, actor: actor, at: date)
        }
    }

    public func changeStatus(
        _ id: WorkItemID, to status: WorkItemStatus, expectedRevision: Int, actor: EventActor, at date: Date = .now
    ) async throws -> WorkItem {
        try await database.write { db in
            let stored = try Self.fetchForUpdate(db, id, expectedRevision: expectedRevision)
            var updated = stored
            let hasActiveJob = try Self.hasActiveJob(db, id)
            do throws(WorkItemError) {
                try updated.changeStatusManually(to: status, hasActiveJob: hasActiveJob, at: date)
            } catch {
                switch error {
                case let .statusChange(change): throw StoreError.workItemStatusChange(change)
                default: throw StoreError.humanID(error)
                }
            }
            try WorkItemStorage.save(db, updated)
            try SyncBookkeeping.enqueue(db, .workItem, id.rawValue, kind: .update, at: date)
            try EventLogWriter.append(db, workItem: updated, kind: .statusChanged, actor: actor,
                                      payload: ["from": stored.status.rawValue, "to": status.rawValue], at: date)
            return updated
        }
    }

    public func applyHostStatus(_ id: WorkItemID, to status: WorkItemStatus, actor: EventActor, at date: Date = .now) async throws -> WorkItem {
        try await database.write { db in
            guard let stored = try WorkItemStorage.fetch(db, syncID: id.rawValue) else {
                throw StoreError.notFound(entity: .workItem, id: id.uuidString)
            }
            var updated = stored
            do throws(InvalidStateTransition<WorkItemStatus>) {
                try updated.applyHostStatus(status, at: date)
            } catch {
                throw StoreError.invalidWorkItemTransition(error)
            }
            guard updated != stored else { return stored }
            try WorkItemStorage.save(db, updated)
            try SyncBookkeeping.enqueue(db, .workItem, id.rawValue, kind: .update, at: date)
            try EventLogWriter.append(db, workItem: updated, kind: .statusChanged, actor: actor,
                                      payload: ["from": stored.status.rawValue, "to": status.rawValue], at: date)
            return updated
        }
    }

    public func delete(_ id: WorkItemID, expectedRevision: Int, at date: Date = .now) async throws {
        try await database.write { db in
            _ = try Self.fetchForUpdate(db, id, expectedRevision: expectedRevision)
            if let job = try GRDBAgentJobRepository.activeJob(db, workItemId: id) {
                throw StoreError.activeJobExists(workItemId: id, jobId: job.jobId)
            }
            try SyncBookkeeping.delete(db, WorkItemStorage.self, syncID: id.rawValue, at: date)
        }
    }

    public func hasActiveJob(_ id: WorkItemID) async throws -> Bool {
        try await database.read { db in try Self.hasActiveJob(db, id) }
    }

    public func reclassify(
        _ id: WorkItemID, to type: WorkItemType, expectedRevision: Int, actor: EventActor, at date: Date = .now
    ) async throws -> WorkItem {
        try await database.write { db in
            let stored = try Self.fetchForUpdate(db, id, expectedRevision: expectedRevision)
            var updated = stored
            let active = try Self.hasActiveJob(db, id)
            do throws(WorkItemError) {
                try updated.reclassify(to: type, hasActiveJob: active, at: date)
            } catch {
                throw StoreError.reclassificationRefused(error)
            }
            guard updated != stored else { return stored }
            try SyncBookkeeping.save(db, WorkItemStorage.self, updated, isNew: false, at: date)
            try EventLogWriter.append(db, workItem: updated, kind: .typeChanged, actor: actor,
                                      payload: ["from": stored.type.rawValue, "to": type.rawValue], at: date)
            return updated
        }
    }

    public func setArchived(
        _ id: WorkItemID, _ archived: Bool, expectedRevision: Int, actor: EventActor, at date: Date = .now
    ) async throws -> WorkItem {
        try await database.write { db in
            let stored = try Self.fetchForUpdate(db, id, expectedRevision: expectedRevision)
            var updated = stored
            if archived { updated.archive(at: date) } else { updated.unarchive(at: date) }
            guard updated != stored else { return stored }
            try SyncBookkeeping.save(db, WorkItemStorage.self, updated, isNew: false, at: date)
            try EventLogWriter.append(db, workItem: updated, kind: archived ? .archived : .unarchived, actor: actor,
                                      payload: ["status": updated.status.rawValue], at: date)
            return updated
        }
    }

    // MARK: Transaction bodies

    static func insert(_ db: Database, _ item: WorkItem, actor: EventActor, at date: Date) throws {
        if try WorkItemStorage.fetch(db, syncID: item.uuid.rawValue) != nil {
            throw StoreError.alreadyExists(entity: .workItem, id: item.uuid.uuidString)
        }
        if let humanId = item.humanId {
            // Imported from an existing request file (ADR-0018): keep the number and advance the range.
            guard let projectId = item.projectId else { throw StoreError.workItemWithoutProject(item.uuid) }
            try HumanIDCounters.ensureUnused(db, humanId, projectId: projectId, excluding: item.uuid)
            try HumanIDCounters.observe(db, projectId: projectId, rangeKey: humanId.type.humanIDPrefix, number: humanId.number, at: date)
        }
        try SyncBookkeeping.save(db, WorkItemStorage.self, item, isNew: true, at: date)
        try EventLogWriter.append(db, workItem: item, kind: .created, actor: actor, at: date)
    }

    static func fetchForUpdate(_ db: Database, _ id: WorkItemID, expectedRevision: Int) throws -> WorkItem {
        guard let stored = try WorkItemStorage.fetch(db, syncID: id.rawValue) else {
            throw StoreError.notFound(entity: .workItem, id: id.uuidString)
        }
        guard stored.revision == expectedRevision else {
            throw StoreError.revisionConflict(entity: .workItem, id: id.uuidString, expected: expectedRevision, actual: stored.revision)
        }
        return stored
    }

    /// Validates an edit against the stored value. Execution metadata (human ID, job links) is
    /// owned by the allocator and job repository; status changes follow the manual rules.
    static func store(
        _ db: Database, stored: WorkItem, updated: WorkItem, expectedRevision: Int, actor: EventActor, at date: Date
    ) throws -> WorkItem {
        guard updated.uuid == stored.uuid else { throw StoreError.identityFieldChanged(entity: .workItem, field: "uuid") }
        // Type and archive state have dedicated operations with their own events.
        guard updated.type == stored.type else { throw StoreError.identityFieldChanged(entity: .workItem, field: "type") }
        guard updated.archivedAt == stored.archivedAt else {
            throw StoreError.identityFieldChanged(entity: .workItem, field: "archivedAt")
        }
        guard updated.originalNote == stored.originalNote else {
            throw StoreError.identityFieldChanged(entity: .workItem, field: "originalNote")
        }
        guard updated.createdAt == stored.createdAt else {
            throw StoreError.identityFieldChanged(entity: .workItem, field: "createdAt")
        }
        guard updated.humanId == stored.humanId else { throw StoreError.humanIDChangeNotAllowed(stored.uuid) }
        guard updated.agentJobIds == stored.agentJobIds else {
            throw StoreError.identityFieldChanged(entity: .workItem, field: "agentJobIds")
        }
        if updated.projectId != stored.projectId, stored.humanId != nil {
            // Human IDs are unique per repository; moving a numbered item would break that (ADR-0018).
            throw StoreError.identityFieldChanged(entity: .workItem, field: "projectId")
        }
        if updated.status != stored.status {
            let active = try hasActiveJob(db, stored.uuid)
            do throws(WorkItemStatusChangeError) {
                try stored.status.validateManualChange(to: updated.status, hasActiveJob: active)
            } catch {
                throw StoreError.workItemStatusChange(error)
            }
        }
        guard updated.revision >= expectedRevision else {
            throw StoreError.revisionConflict(entity: .workItem, id: stored.uuid.uuidString, expected: expectedRevision, actual: updated.revision)
        }
        var result = updated
        if result.revision == expectedRevision { result.touch(at: date) }
        guard result != stored else { return stored }

        try SyncBookkeeping.save(db, WorkItemStorage.self, result, isNew: false, at: date)
        if result.status != stored.status {
            try EventLogWriter.append(db, workItem: result, kind: .statusChanged, actor: actor,
                                      payload: ["from": stored.status.rawValue, "to": result.status.rawValue], at: date)
        } else {
            try EventLogWriter.append(db, workItem: result, kind: .edited, actor: actor,
                                      payload: ["fields": changedFields(stored, result).joined(separator: ",")], at: date)
        }
        return result
    }

    static func changedFields(_ a: WorkItem, _ b: WorkItem) -> [String] {
        var fields: [String] = []
        if a.title != b.title { fields.append("title") }
        if a.transcript != b.transcript { fields.append("transcript") }
        if a.structuredBody != b.structuredBody { fields.append("structuredBody") }
        if a.priority != b.priority { fields.append("priority") }
        if a.complexity != b.complexity { fields.append("complexity") }
        if a.labels != b.labels { fields.append("labels") }
        if a.dependencies != b.dependencies { fields.append("dependencies") }
        if a.reviewState != b.reviewState { fields.append("reviewState") }
        if a.projectId != b.projectId { fields.append("projectId") }
        return fields
    }

    static func hasActiveJob(_ db: Database, _ id: WorkItemID) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM agent_jobs WHERE work_item_id = ? AND state NOT IN \(AgentJobStorage.terminalStatesSQL))
            """, arguments: [id.databaseText]) ?? false
    }

    static func list(_ db: Database, _ filter: WorkItemFilter) throws -> [WorkItem] {
        var clauses: [String] = []
        var arguments: [any DatabaseValueConvertible] = []

        switch filter.project {
        case .any: break
        case .withoutProject: clauses.append("w.project_id IS NULL")
        case let .project(id):
            clauses.append("w.project_id = ?")
            arguments.append(id.databaseText)
        }
        switch filter.archive {
        case .any: break
        case .activeOnly: clauses.append("w.archived_at IS NULL")
        case .archivedOnly: clauses.append("w.archived_at IS NOT NULL")
        }
        func addSet(_ column: String, _ values: [String]) {
            guard !values.isEmpty else { return }
            clauses.append("\(column) IN (\(Array(repeating: "?", count: values.count).joined(separator: ", ")))")
            arguments.append(contentsOf: values)
        }
        addSet("w.status", filter.statuses.map(\.rawValue).sorted())
        addSet("w.type", filter.types.map(\.rawValue).sorted())
        addSet("w.priority", filter.priorities.map(\.rawValue).sorted())
        if let label = filter.label {
            clauses.append("EXISTS (SELECT 1 FROM json_each(w.labels) WHERE json_each.value = ?)")
            arguments.append(label)
        }
        if let text = filter.text, let pattern = FTS5Pattern(matchingAllPrefixesIn: text) {
            clauses.append("t.rowid IN (SELECT rowid FROM work_item_search WHERE work_item_search MATCH ?)")
            arguments.append(pattern)
        }

        var sql = WorkItemStorage.selectSQL
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        sql += " ORDER BY w.priority_rank DESC, w.updated_at DESC, w.uuid"
        if let limit = filter.limit {
            sql += " LIMIT ?"
            arguments.append(limit)
        }
        return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).map(WorkItemStorage.decode)
    }
}
