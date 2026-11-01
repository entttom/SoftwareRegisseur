import Foundation
import GRDB
import SoftwareRegisseurDomain
import Testing
@testable import SoftwareRegisseurPersistence

@Suite("AppDatabase and migrations")
struct DatabaseTests {
    static let expectedTables: Set<String> = [
        "projects", "project_settings", "repository_locations", "work_items", "work_item_texts", "work_item_search",
        "adrs", "audio_notes", "ai_requests", "ai_conversations", "agent_hosts", "agent_capabilities",
        "agent_model_capabilities", "agent_model_preferences", "agent_jobs", "task_locks", "task_events", "reviews",
        "github_issue_links", "provider_profiles", "human_id_counters", "sync_outbox", "sync_inbox", "sync_tombstones",
        "sync_entity_state", "sync_engine_state", "sync_conflicts",
    ]

    @Test func migratesEmptyInMemoryDatabase() throws {
        let database = try AppDatabase.inMemory()
        #expect(try database.appliedMigrations() == AppSchema.migrationIdentifiers)
        let tables = try database.reader.read { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        }
        #expect(Self.expectedTables.isSubset(of: tables))
        let foreignKeys = try database.reader.read { db in try Bool.fetchOne(db, sql: "PRAGMA foreign_keys") }
        #expect(foreignKeys == true)
    }

    @Test func migratesEmptyOnDiskDatabaseInWALModeAndReopens() throws {
        let directory = try TemporaryDirectory()
        do {
            let database = try AppDatabase.openWriter(at: directory.databaseURL)
            #expect(try database.appliedMigrations() == AppSchema.migrationIdentifiers)
            let mode = try database.reader.read { db in try String.fetchOne(db, sql: "PRAGMA journal_mode") }
            #expect(mode == "wal")
        }
        // Reopening an up-to-date database runs no migration and keeps data.
        let reopened = try AppDatabase.openWriter(at: directory.databaseURL)
        #expect(try reopened.appliedMigrations() == AppSchema.migrationIdentifiers)
    }

    @Test func refusesDatabaseMigratedByNewerBuild() throws {
        let directory = try TemporaryDirectory()
        do {
            let database = try AppDatabase.openWriter(at: directory.databaseURL)
            try database.writer!.write { db in
                try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v999_future')")
            }
        }
        #expect(throws: StoreError.schemaTooNew) { try AppDatabase.openWriter(at: directory.databaseURL) }
        #expect(throws: StoreError.schemaTooNew) { try AppDatabase.openReadOnly(at: directory.databaseURL) }
    }

    @Test func readOnlyOpeningRequiresMigratedDatabase() throws {
        let directory = try TemporaryDirectory()
        #expect(throws: StoreError.schemaNotReady) { try AppDatabase.openReadOnly(at: directory.databaseURL) }
        // A plain SQLite file without our migrations is not accepted either.
        _ = try DatabaseQueue(path: directory.databaseURL.path)
        #expect(throws: StoreError.schemaNotReady) { try AppDatabase.openReadOnly(at: directory.databaseURL) }
    }

    @Test func providerProfilesHaveNoSecretColumns() throws {
        let database = try AppDatabase.inMemory()
        let columns = try database.reader.read { db in try db.columns(in: "provider_profiles").map(\.name) }
        for column in columns {
            for forbidden in ["secret", "token", "password", "api_key", "apikey", "key_value"] {
                #expect(!column.lowercased().contains(forbidden), "column \(column)")
            }
        }
        #expect(columns.contains("keychain_service"))
    }

    @Test func pooledWriterAndReadOnlyReaderSeeCommittedData() async throws {
        let directory = try TemporaryDirectory()
        let writer = try AppDatabase.openWriter(at: directory.databaseURL)
        let reader = try AppDatabase.openReadOnly(at: directory.databaseURL)
        #expect(reader.isReadOnly)

        let (project, item) = try await writer.seedItem()
        #expect(try await reader.workItems.fetch(item.uuid) == item)
        #expect(try await reader.projects.fetch(project.id) == project)

        let updated = try await writer.workItems.update(item.uuid, expectedRevision: item.revision, actor: deviceActor, at: at(10)) {
            $0.title = "Geändert vom Dienst"
        }
        #expect(try await reader.workItems.fetch(item.uuid)?.title == "Geändert vom Dienst")
        #expect(try await reader.workItems.fetch(item.uuid) == updated)

        // The UI process cannot write (ADR-0019: writes go through XPC).
        await #expect(throws: StoreError.readOnlyDatabase) {
            try await reader.workItems.insert(Fixture.workItem(projectId: nil), actor: deviceActor, at: t0)
        }
        #expect(throws: (any Error).self) {
            try reader.reader.read { db in try db.execute(sql: "DELETE FROM work_items") }
        }
    }

    @Test func readOnlyReaderOpensAfterWriterClosed() async throws {
        let directory = try TemporaryDirectory()
        var itemId: WorkItemID?
        do {
            let writer = try AppDatabase.openWriter(at: directory.databaseURL)
            itemId = try await writer.seedItem().1.uuid
        }
        // Persistent WAL keeps -wal/-shm so the read-only process can still open the file.
        #expect(FileManager.default.fileExists(atPath: directory.databaseURL.path + "-wal"))
        let reader = try AppDatabase.openReadOnly(at: directory.databaseURL)
        #expect(try await reader.workItems.fetch(itemId!) != nil)
    }
}
