import CryptoKit
import Foundation
import GRDB
import SoftwareRegisseurDomain

// Workspace tables (migration v3). Since v4, setup commands, indexed folders and file conflicts sync
// through the outbox (spec E2, N1, N2): commands are created on any device and executed by the Mac,
// folders are Mac-authoritative, conflicts are resolved by the user on any device. Document files and
// host state stay host-local. Entities with private(set) fields are stored as JSON payloads next to
// the indexed columns.

// MARK: - Project setup commands (spec E2, A03)

public protocol ProjectSetupCommandRepository: Sendable {
    func insert(_ command: ProjectSetupCommand, at date: Date) async throws
    func fetch(_ id: ProjectSetupCommandID) async throws -> ProjectSetupCommand?
    func list(states: Set<ProjectSetupState>) async throws -> [ProjectSetupCommand]
    /// Optimistic update (revision of the stored command must be `expectedRevision`).
    func update(_ command: ProjectSetupCommand, expectedRevision: Int) async throws
    /// Commands for one project, newest last (UI: state of a `CreateProject`/`LinkProject` request).
    func list(projectId: ProjectID) async throws -> [ProjectSetupCommand]
}

public struct GRDBProjectSetupCommandRepository: ProjectSetupCommandRepository {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func insert(_ command: ProjectSetupCommand, at date: Date = .now) async throws {
        try await database.write { db in
            if try ProjectSetupCommandStorage.fetch(db, syncID: command.id.rawValue) != nil {
                throw StoreError.alreadyExists(entity: .projectSetupCommand, id: command.id.uuidString)
            }
            try SyncBookkeeping.save(db, ProjectSetupCommandStorage.self, command, isNew: true, at: date)
        }
    }

    public func fetch(_ id: ProjectSetupCommandID) async throws -> ProjectSetupCommand? {
        try await database.read { db in try ProjectSetupCommandStorage.fetch(db, syncID: id.rawValue) }
    }

    public func list(states: Set<ProjectSetupState> = []) async throws -> [ProjectSetupCommand] {
        try await database.read { db in
            var sql = "SELECT payload FROM project_setup_commands"
            let values = states.map(\.rawValue).sorted()
            if !values.isEmpty { sql += " WHERE state IN (\(GRDBAgentJobRepository.placeholders(values.count)))" }
            sql += " ORDER BY created_at, id"
            return try String.fetchAll(db, sql: sql, arguments: StatementArguments(values)).map {
                try JSONColumn.decode(ProjectSetupCommand.self, from: $0)
            }
        }
    }

    public func list(projectId: ProjectID) async throws -> [ProjectSetupCommand] {
        try await database.read { db in
            try String.fetchAll(db, sql: "SELECT payload FROM project_setup_commands WHERE project_id = ? ORDER BY created_at, id",
                                arguments: [projectId.databaseText])
                .map { try JSONColumn.decode(ProjectSetupCommand.self, from: $0) }
        }
    }

    public func update(_ command: ProjectSetupCommand, expectedRevision: Int) async throws {
        try await database.write { db in
            guard let stored = try ProjectSetupCommandStorage.fetch(db, syncID: command.id.rawValue) else {
                throw StoreError.notFound(entity: .projectSetupCommand, id: command.id.uuidString)
            }
            guard stored.revision == expectedRevision, command.revision > expectedRevision else {
                throw StoreError.revisionConflict(entity: .projectSetupCommand, id: command.id.uuidString,
                                                  expected: expectedRevision, actual: stored.revision)
            }
            try SyncBookkeeping.save(db, ProjectSetupCommandStorage.self, command, isNew: false, at: command.updatedAt)
        }
    }

    static func fetch(_ db: Database, _ id: ProjectSetupCommandID) throws -> ProjectSetupCommand? {
        try ProjectSetupCommandStorage.fetch(db, syncID: id.rawValue)
    }
}

// MARK: - Indexed folders (spec E1/E2)

public protocol IndexedFolderRepository: Sendable {
    /// Inserts or updates by (host, canonical path); an existing row keeps its ID.
    @discardableResult func upsert(_ folder: IndexedFolder) async throws -> IndexedFolder
    func fetch(hostId: HostID, path: String) async throws -> IndexedFolder?
    func list(hostId: HostID) async throws -> [IndexedFolder]
    func list(projectId: ProjectID) async throws -> [IndexedFolder]
    func list(repositoryIdentity: RepositoryIdentity) async throws -> [IndexedFolder]
    func delete(hostId: HostID, path: String) async throws
    /// Folders the iPhone may offer for a new project (spec E2), over all hosts.
    func selectable() async throws -> [IndexedFolder]
}

public struct GRDBIndexedFolderRepository: IndexedFolderRepository {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Only real changes enter the outbox: a rescan that merely refreshes `lastSeenAt` stays local, so
    /// periodic scans do not flood CloudKit (the synced `lastSeenAt` is the last change).
    @discardableResult
    public func upsert(_ folder: IndexedFolder) async throws -> IndexedFolder {
        try await database.write { db in
            var stored = folder
            let existing = try IndexedFolderStorage.fetch(db, hostId: folder.hostId, path: folder.canonicalPath)
            if let existing, existing.id != folder.id {
                stored = IndexedFolder(
                    id: existing.id, hostId: folder.hostId, canonicalPath: folder.canonicalPath, displayName: folder.displayName,
                    kind: folder.kind, repositoryRootPath: folder.repositoryRootPath, scanRootPath: folder.scanRootPath,
                    depth: folder.depth, projectId: folder.projectId, repositoryIdentity: folder.repositoryIdentity,
                    defaultBranch: folder.defaultBranch, remote: folder.remote, fileSystemFingerprint: folder.fileSystemFingerprint,
                    documents: folder.documents, isSelectable: folder.isSelectable, isAvailable: folder.isAvailable,
                    lastSeenAt: folder.lastSeenAt
                )
            }
            if let existing {
                var comparable = stored
                comparable.lastSeenAt = existing.lastSeenAt
                if comparable == existing {
                    try IndexedFolderStorage.save(db, stored)
                    return stored
                }
            }
            try SyncBookkeeping.save(db, IndexedFolderStorage.self, stored, isNew: existing == nil, at: stored.lastSeenAt)
            return stored
        }
    }

    public func fetch(hostId: HostID, path: String) async throws -> IndexedFolder? {
        try await database.read { db in try IndexedFolderStorage.fetch(db, hostId: hostId, path: path) }
    }

    public func list(hostId: HostID) async throws -> [IndexedFolder] {
        try await query("WHERE host_id = ? ORDER BY canonical_path", [hostId.databaseText])
    }

    public func list(projectId: ProjectID) async throws -> [IndexedFolder] {
        try await query("WHERE project_id = ? ORDER BY canonical_path", [projectId.databaseText])
    }

    public func list(repositoryIdentity: RepositoryIdentity) async throws -> [IndexedFolder] {
        try await query("WHERE repository_identity = ? ORDER BY canonical_path", [repositoryIdentity.rawValue])
    }

    public func selectable() async throws -> [IndexedFolder] {
        try await query("WHERE is_selectable = 1 AND is_available = 1 ORDER BY canonical_path", [])
    }

    public func delete(hostId: HostID, path: String) async throws {
        try await database.write { db in
            guard let folder = try IndexedFolderStorage.fetch(db, hostId: hostId, path: path) else { return }
            try SyncBookkeeping.delete(db, IndexedFolderStorage.self, syncID: folder.id.rawValue, at: Date())
        }
    }

    private func query(_ clause: String, _ arguments: [String]) async throws -> [IndexedFolder] {
        try await database.read { db in
            try String.fetchAll(db, sql: "SELECT payload FROM indexed_folders " + clause, arguments: StatementArguments(arguments))
                .map { try JSONColumn.decode(IndexedFolder.self, from: $0) }
        }
    }

    static func fetch(_ db: Database, hostId: HostID, path: String) throws -> IndexedFolder? {
        try IndexedFolderStorage.fetch(db, hostId: hostId, path: path)
    }
}

// MARK: - Document files (spec E3, F3, A04)

public enum DocumentFileKind: String, Hashable, Sendable, Codable, CaseIterable {
    case request
    case adr
    case instructions
}

public enum DocumentCompatibility: String, Hashable, Sendable, Codable, CaseIterable {
    case compatible
    /// Kept as-is and shown for manual mapping (spec E3).
    case incompatible
}

/// Last reconciled version of one repository document. `content` is the common ancestor for the next
/// comparison (file vs. database), `entityRevision` the database revision it corresponds to.
public struct DocumentFileRecord: Hashable, Sendable, Codable {
    public var projectId: ProjectID
    /// Repository-relative path with `/` separators.
    public var relativePath: String
    public var kind: DocumentFileKind
    /// Work item UUID or ADR UUID.
    public var entityId: UUID?
    public var contentHash: String
    public var content: String
    public var entityRevision: Int?
    /// JSON snapshot of the entity at `entityRevision` (field-level 3-way comparison, spec N2).
    public var entitySnapshot: Data?
    public var compatibility: DocumentCompatibility
    public var issue: String?
    public var updatedAt: Date

    public init(
        projectId: ProjectID, relativePath: String, kind: DocumentFileKind, entityId: UUID?, content: String,
        entityRevision: Int?, entitySnapshot: Data? = nil, compatibility: DocumentCompatibility = .compatible,
        issue: String? = nil, updatedAt: Date
    ) {
        self.entitySnapshot = entitySnapshot
        self.projectId = projectId
        self.relativePath = relativePath
        self.kind = kind
        self.entityId = entityId
        self.content = content
        self.contentHash = Self.hash(Data(content.utf8))
        self.entityRevision = entityRevision
        self.compatibility = compatibility
        self.issue = issue
        self.updatedAt = updatedAt
    }

    /// SHA-256 hex of the raw bytes.
    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public protocol DocumentFileRepository: Sendable {
    func upsert(_ record: DocumentFileRecord) async throws
    func fetch(projectId: ProjectID, relativePath: String) async throws -> DocumentFileRecord?
    func fetch(entityId: UUID) async throws -> DocumentFileRecord?
    func list(projectId: ProjectID, kind: DocumentFileKind?) async throws -> [DocumentFileRecord]
    /// Moves a record to a new path (file renamed/moved), replacing nothing.
    func move(projectId: ProjectID, from: String, to: String, at date: Date) async throws
    func delete(projectId: ProjectID, relativePath: String) async throws
}

public struct GRDBDocumentFileRepository: DocumentFileRepository {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func upsert(_ record: DocumentFileRecord) async throws {
        try await database.write { db in
            // One record per entity: a moved file replaces the record at its old path.
            if let entityId = record.entityId {
                try db.execute(sql: "DELETE FROM document_files WHERE entity_id = ? AND NOT (project_id = ? AND relative_path = ?)",
                               arguments: [entityId.uuidString, record.projectId.databaseText, record.relativePath])
            }
            try db.upsert(into: "document_files", [
                "project_id": record.projectId.databaseText,
                "relative_path": record.relativePath,
                "kind": record.kind.rawValue,
                "entity_id": record.entityId?.uuidString,
                "content_hash": record.contentHash,
                "content": record.content,
                "entity_revision": record.entityRevision,
                "entity_snapshot": record.entitySnapshot,
                "compatibility": record.compatibility.rawValue,
                "issue": record.issue,
                "updated_at": StoredDate.value(record.updatedAt),
            ], conflictKeys: ["project_id", "relative_path"])
        }
    }

    public func fetch(projectId: ProjectID, relativePath: String) async throws -> DocumentFileRecord? {
        try await database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM document_files WHERE project_id = ? AND relative_path = ?",
                             arguments: [projectId.databaseText, relativePath]).map(Self.decode)
        }
    }

    public func fetch(entityId: UUID) async throws -> DocumentFileRecord? {
        try await database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM document_files WHERE entity_id = ?", arguments: [entityId.uuidString])
                .map(Self.decode)
        }
    }

    public func list(projectId: ProjectID, kind: DocumentFileKind? = nil) async throws -> [DocumentFileRecord] {
        try await database.read { db in
            if let kind {
                return try Row.fetchAll(db, sql: "SELECT * FROM document_files WHERE project_id = ? AND kind = ? ORDER BY relative_path",
                                        arguments: [projectId.databaseText, kind.rawValue]).map(Self.decode)
            }
            return try Row.fetchAll(db, sql: "SELECT * FROM document_files WHERE project_id = ? ORDER BY relative_path",
                                    arguments: [projectId.databaseText]).map(Self.decode)
        }
    }

    public func move(projectId: ProjectID, from: String, to: String, at date: Date = .now) async throws {
        try await database.write { db in
            let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM document_files WHERE project_id = ? AND relative_path = ?)",
                                           arguments: [projectId.databaseText, to]) ?? false
            if exists { throw StoreError.alreadyExists(entity: .workItem, id: to) }
            try db.execute(sql: "UPDATE document_files SET relative_path = ?, updated_at = ? WHERE project_id = ? AND relative_path = ?",
                           arguments: [to, StoredDate.value(date), projectId.databaseText, from])
        }
    }

    public func delete(projectId: ProjectID, relativePath: String) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM document_files WHERE project_id = ? AND relative_path = ?",
                           arguments: [projectId.databaseText, relativePath])
        }
    }

    static func decode(_ row: Row) throws -> DocumentFileRecord {
        var record = DocumentFileRecord(
            projectId: try row.id("project_id"),
            relativePath: try row.string("relative_path"),
            kind: try row.enumValue("kind"),
            entityId: try row.optionalUUID("entity_id"),
            content: try row.string("content"),
            entityRevision: row.optionalInt("entity_revision"),
            entitySnapshot: row["entity_snapshot"],
            compatibility: try row.enumValue("compatibility"),
            issue: row["issue"],
            updatedAt: try row.date("updated_at")
        )
        record.contentHash = try row.string("content_hash")
        return record
    }
}

// MARK: - File conflicts (spec N2, A04, A24, ADR-0016)

public protocol FileConflictRepository: Sendable {
    func insert(_ conflict: FileConflict) async throws
    func fetch(_ id: FileConflictID) async throws -> FileConflict?
    func open(projectId: ProjectID?) async throws -> [FileConflict]
    func open(workItemId: WorkItemID) async throws -> [FileConflict]
    func resolve(_ id: FileConflictID, resolution: FileConflictResolution, at date: Date) async throws -> FileConflict
    /// Records a resolution chosen on a device without file access (iPhone); the Mac applies it.
    func requestResolution(_ id: FileConflictID, resolution: FileConflictResolution, by device: DeviceID, at date: Date) async throws -> FileConflict
    /// Unresolved conflicts with a requested resolution (Mac host work list).
    func pendingRequests() async throws -> [FileConflict]
}

public struct GRDBFileConflictRepository: FileConflictRepository {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func insert(_ conflict: FileConflict) async throws {
        try await database.write { db in
            _ = try SyncBookkeeping.upsert(db, FileConflictStorage.self, conflict, at: conflict.detectedAt)
        }
    }

    public func fetch(_ id: FileConflictID) async throws -> FileConflict? {
        try await database.read { db in try FileConflictStorage.fetch(db, syncID: id.rawValue) }
    }

    public func open(projectId: ProjectID? = nil) async throws -> [FileConflict] {
        try await database.read { db in
            if let projectId {
                return try Self.decodeAll(db, "WHERE resolved_at IS NULL AND project_id = ?", [projectId.databaseText])
            }
            return try Self.decodeAll(db, "WHERE resolved_at IS NULL", [])
        }
    }

    public func open(workItemId: WorkItemID) async throws -> [FileConflict] {
        try await database.read { db in
            try Self.decodeAll(db, "WHERE resolved_at IS NULL AND work_item_id = ?", [workItemId.databaseText])
        }
    }

    public func resolve(_ id: FileConflictID, resolution: FileConflictResolution, at date: Date = .now) async throws -> FileConflict {
        try await database.write { db in
            guard var conflict = try FileConflictStorage.fetch(db, syncID: id.rawValue) else {
                throw StoreError.notFound(entity: .fileConflict, id: id.uuidString)
            }
            if conflict.isResolved { throw StoreError.conflictAlreadyResolved(id.rawValue) }
            conflict.resolve(resolution, at: date)
            try SyncBookkeeping.save(db, FileConflictStorage.self, conflict, isNew: false, at: date)
            return conflict
        }
    }

    public func requestResolution(
        _ id: FileConflictID, resolution: FileConflictResolution, by device: DeviceID, at date: Date = .now
    ) async throws -> FileConflict {
        try await database.write { db in
            guard var conflict = try FileConflictStorage.fetch(db, syncID: id.rawValue) else {
                throw StoreError.notFound(entity: .fileConflict, id: id.uuidString)
            }
            if conflict.isResolved { throw StoreError.conflictAlreadyResolved(id.rawValue) }
            conflict.requestResolution(resolution, by: device, at: date)
            try SyncBookkeeping.save(db, FileConflictStorage.self, conflict, isNew: false, at: date)
            return conflict
        }
    }

    public func pendingRequests() async throws -> [FileConflict] {
        try await database.read { db in
            try Self.decodeAll(db, "WHERE resolved_at IS NULL", []).filter(\.hasPendingRequest)
        }
    }

    static func decodeAll(_ db: Database, _ clause: String, _ arguments: [String]) throws -> [FileConflict] {
        try String.fetchAll(db, sql: "SELECT payload FROM file_conflicts \(clause) ORDER BY detected_at, id",
                            arguments: StatementArguments(arguments))
            .map { try JSONColumn.decode(FileConflict.self, from: $0) }
    }

    static func fetch(_ db: Database, _ id: FileConflictID) throws -> FileConflict? {
        try FileConflictStorage.fetch(db, syncID: id.rawValue)
    }
}

// MARK: - Host state (key/value)

/// Small host-local key/value store for workspace state that is not domain data (scan cache, GitHub
/// issue snapshots, per-project integration switches). Never synced.
public protocol HostStateStore: Sendable {
    func value(scope: String, key: String) async throws -> Data?
    func setValue(_ value: Data, scope: String, key: String, at date: Date) async throws
    func removeValue(scope: String, key: String) async throws
    func keys(scope: String) async throws -> [String]
}

public struct GRDBHostStateStore: HostStateStore {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func value(scope: String, key: String) async throws -> Data? {
        try await database.read { db in
            try Data.fetchOne(db, sql: "SELECT value FROM host_state WHERE scope = ? AND key = ?", arguments: [scope, key])
        }
    }

    public func setValue(_ value: Data, scope: String, key: String, at date: Date = .now) async throws {
        try await database.write { db in
            try db.upsert(into: "host_state", [
                "scope": scope, "key": key, "value": value, "updated_at": StoredDate.value(date),
            ], conflictKeys: ["scope", "key"])
        }
    }

    public func removeValue(scope: String, key: String) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM host_state WHERE scope = ? AND key = ?", arguments: [scope, key])
        }
    }

    public func keys(scope: String) async throws -> [String] {
        try await database.read { db in
            try String.fetchAll(db, sql: "SELECT key FROM host_state WHERE scope = ? ORDER BY key", arguments: [scope])
        }
    }
}
