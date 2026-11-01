import Foundation
import GRDB
import GRDBSQLite

/// Local SQLite database (ADR-0019).
///
/// - Writer (`openWriter`): `DatabasePool` in WAL mode with persistent WAL, migrated on open. On macOS
///   only the Agent Service opens it this way (single writer).
/// - Reader (`openReadOnly`): read-only `DatabasePool` for the macOS UI process; refuses databases whose
///   schema is older or newer than this build.
/// - `inMemory()`: `DatabaseQueue` for tests and previews.
///
/// Repositories run every write in one `IMMEDIATE` transaction (GRDB default for writes).
public final class AppDatabase: Sendable {
    public let reader: any DatabaseReader
    let writer: (any DatabaseWriter)?

    public var isReadOnly: Bool { writer == nil }

    private init(reader: any DatabaseReader, writer: (any DatabaseWriter)?) {
        self.reader = reader
        self.writer = writer
    }

    /// Registered migrations, in order. Never uses `eraseDatabaseOnSchemaChange`.
    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        AppSchema.registerMigrations(in: &migrator)
        return migrator
    }

    // MARK: Opening

    /// Opens (creating if needed) the database at `url` as the single writer and migrates it.
    /// Creation is protected with `NSFileCoordinator` as recommended by GRDB for shared containers.
    public static func openWriter(at url: URL, busyTimeout: TimeInterval = 5) throws -> AppDatabase {
        try openWriter(at: url, busyTimeout: busyTimeout, migratingUpTo: nil)
    }

    /// `migratingUpTo` stops at an older migration (tests of upgrades from older schema versions).
    static func openWriter(at url: URL, busyTimeout: TimeInterval = 5, migratingUpTo target: String?) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try coordinated(writingAt: url) { url in
            var configuration = baseConfiguration()
            configuration.busyMode = .timeout(busyTimeout)
            configuration.prepareDatabase { db in
                // Persistent WAL keeps -wal/-shm files so read-only processes can always open the DB.
                if !db.configuration.readonly {
                    var flag: CInt = 1
                    let code = withUnsafeMutablePointer(to: &flag) { pointer in
                        sqlite3_file_control(db.sqliteConnection, nil, SQLITE_FCNTL_PERSIST_WAL, pointer)
                    }
                    guard code == SQLITE_OK else {
                        throw DatabaseError(resultCode: ResultCode(rawValue: code))
                    }
                }
            }
            let pool = try DatabasePool(path: url.path, configuration: configuration)
            if let target {
                try migrator.migrate(pool, upTo: target)
            } else {
                try migrator.migrate(pool)
            }
            if try pool.read(migrator.hasBeenSuperseded) {
                throw StoreError.schemaTooNew
            }
            return AppDatabase(reader: pool, writer: pool)
        }
    }

    /// Read-only access for the macOS UI process (ADR-0019). Writes go through XPC to the Agent Service.
    public static func openReadOnly(at url: URL, busyTimeout: TimeInterval = 5) throws -> AppDatabase {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StoreError.schemaNotReady
        }
        return try coordinated(readingAt: url) { url in
            var configuration = baseConfiguration()
            configuration.readonly = true
            configuration.busyMode = .timeout(busyTimeout)
            let pool = try DatabasePool(path: url.path, configuration: configuration)
            try pool.read { db in
                let migrator = migrator
                if try migrator.hasBeenSuperseded(db) { throw StoreError.schemaTooNew }
                if try !migrator.hasCompletedMigrations(db) { throw StoreError.schemaNotReady }
            }
            return AppDatabase(reader: pool, writer: nil)
        }
    }

    /// Migrated in-memory database (tests, previews).
    public static func inMemory() throws -> AppDatabase {
        let queue = try DatabaseQueue(configuration: baseConfiguration())
        try migrator.migrate(queue)
        return AppDatabase(reader: queue, writer: queue)
    }

    private static func baseConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.label = "SoftwareRegisseur"
        return configuration
    }

    private static func coordinated(writingAt url: URL, _ body: (URL) throws -> AppDatabase) throws -> AppDatabase {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatorError: NSError?
        var result: Result<AppDatabase, any Error>?
        coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &coordinatorError) { url in
            result = Result { try body(url) }
        }
        if let coordinatorError { throw coordinatorError }
        return try result!.get()
    }

    private static func coordinated(readingAt url: URL, _ body: (URL) throws -> AppDatabase) throws -> AppDatabase {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatorError: NSError?
        var result: Result<AppDatabase, any Error>?
        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinatorError) { url in
            result = Result { try body(url) }
        }
        if let coordinatorError { throw coordinatorError }
        return try result!.get()
    }

    // MARK: Closing

    /// Closes all connections, e.g. before the files are deleted (A34 „Daten löschen“). Afterwards every
    /// access throws (`SQLITE_MISUSE`); open a new `AppDatabase` to continue. Throws `SQLITE_BUSY` (and
    /// stays usable) while a read or write is still running.
    public func close() throws {
        try reader.close()
    }

    // MARK: Access

    /// Applied migration identifiers, in order.
    public func appliedMigrations() throws -> [String] {
        try reader.read { db in try Self.migrator.appliedMigrations(db) }
    }

    func write<T: Sendable>(_ updates: @Sendable (Database) throws -> T) async throws -> T {
        guard let writer else { throw StoreError.readOnlyDatabase }
        return try await writer.write(updates)
    }

    func read<T: Sendable>(_ value: @Sendable (Database) throws -> T) async throws -> T {
        try await reader.read(value)
    }

    // MARK: Repositories

    public var projects: GRDBProjectRepository { GRDBProjectRepository(database: self) }
    public var workItems: GRDBWorkItemRepository { GRDBWorkItemRepository(database: self) }
    public var jobs: GRDBAgentJobRepository { GRDBAgentJobRepository(database: self) }
    public var locks: GRDBTaskLockRepository { GRDBTaskLockRepository(database: self) }
    public var humanIDs: GRDBHumanIDAllocator { GRDBHumanIDAllocator(database: self) }
    public var events: GRDBEventLog { GRDBEventLog(database: self) }
    public var capabilities: GRDBCapabilityRepository { GRDBCapabilityRepository(database: self) }
    public var preferences: GRDBPreferenceRepository { GRDBPreferenceRepository(database: self) }
    public var adrs: GRDBADRRepository { GRDBADRRepository(database: self) }
    public var aiRecords: GRDBAIRecordRepository { GRDBAIRecordRepository(database: self) }
    public var reviews: GRDBReviewRepository { GRDBReviewRepository(database: self) }
    public var providerProfiles: GRDBProviderProfileRepository { GRDBProviderProfileRepository(database: self) }
    public var sync: GRDBSyncStore { GRDBSyncStore(database: self) }
    // Workspace host index (v3, host-local).
    public var projectSetupCommands: GRDBProjectSetupCommandRepository { GRDBProjectSetupCommandRepository(database: self) }
    public var indexedFolders: GRDBIndexedFolderRepository { GRDBIndexedFolderRepository(database: self) }
    public var documentFiles: GRDBDocumentFileRepository { GRDBDocumentFileRepository(database: self) }
    public var fileConflicts: GRDBFileConflictRepository { GRDBFileConflictRepository(database: self) }
    public var hostState: GRDBHostStateStore { GRDBHostStateStore(database: self) }
    // Cross-device contracts (v4).
    public var approvals: GRDBApprovalRepository { GRDBApprovalRepository(database: self) }
    public var draftVersions: GRDBDraftVersionRepository { GRDBDraftVersionRepository(database: self) }
    public var globalSettings: GRDBGlobalSettingsRepository { GRDBGlobalSettingsRepository(database: self) }
}
