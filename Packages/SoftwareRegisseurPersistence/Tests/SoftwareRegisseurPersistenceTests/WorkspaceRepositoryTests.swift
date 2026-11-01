import Foundation
import GRDB
import SoftwareRegisseurDomain
import Testing
@testable import SoftwareRegisseurPersistence

@Suite("Workspace host index (migration v3)")
struct WorkspaceRepositoryTests {
    @Test func migratesV2DatabaseToV3KeepingData() async throws {
        let directory = try TemporaryDirectory()
        let project: Project
        do {
            let v2 = try AppDatabase.openWriter(at: directory.databaseURL, migratingUpTo: "v2_sync_three_way_merge")
            (project, _) = try await v2.seedItem()
            #expect(try await v2.projects.fetch(project.id)?.statusReason == nil)
        }
        let database = try AppDatabase.openWriter(at: directory.databaseURL)
        // v2 → latest: v3 (and since v4 the cross-device contracts) are applied on top of the old data.
        #expect(try database.appliedMigrations() == AppSchema.migrationIdentifiers)
        #expect(try database.appliedMigrations().contains("v3_workspace_host_index"))
        var stored = try #require(try await database.projects.fetch(project.id))
        #expect(stored == project)
        try stored.transition(to: .needsAttention, reason: "Ordner nicht gefunden", at: at(5))
        let updated = try await database.projects.update(stored, expectedRevision: project.revision, at: at(5))
        #expect(try await database.projects.fetch(project.id)?.statusReason == "Ordner nicht gefunden")
        #expect(updated.revision == project.revision + 1)
    }

    /// Since v4 setup commands, indexed folders and file conflicts sync (spec E2, N2); document files and
    /// host state stay host-local and never enter the outbox.
    @Test func hostLocalTablesDoNotEnterTheOutbox() async throws {
        let database = try AppDatabase.inMemory()
        let before = try database.count("sync_outbox")
        let host = HostID()
        let projectId = ProjectID()

        var command = ProjectSetupCommand(kind: .createProject, projectId: projectId, projectName: "Neu",
                                          target: .draftWithoutRepository, createdAt: t0)
        try await database.projectSetupCommands.insert(command, at: t0)
        #expect(try await database.projectSetupCommands.list(states: [.pending]).map(\.id) == [command.id])
        let base = command.revision
        command.complete(resultPath: nil, at: at(1))
        try await database.projectSetupCommands.update(command, expectedRevision: base)
        await #expect(throws: StoreError.self) { try await database.projectSetupCommands.update(command, expectedRevision: base) }
        #expect(try await database.projectSetupCommands.list(states: [.pending]).isEmpty)

        let folder = IndexedFolder(hostId: host, canonicalPath: "/x/app", displayName: "app", kind: .plainFolder,
                                   scanRootPath: "/x", depth: 1, isSelectable: true, lastSeenAt: t0)
        let saved = try await database.indexedFolders.upsert(folder)
        var changed = IndexedFolder(hostId: host, canonicalPath: "/x/app", displayName: "app", kind: .gitRepository,
                                    scanRootPath: "/x", depth: 1, isSelectable: true, lastSeenAt: at(2))
        changed = try await database.indexedFolders.upsert(changed)
        #expect(changed.id == saved.id)
        #expect(try await database.indexedFolders.list(hostId: host).map(\.kind) == [.gitRepository])

        let entity = UUID()
        try await database.documentFiles.upsert(DocumentFileRecord(projectId: projectId, relativePath: "a.md", kind: .request,
                                                                   entityId: entity, content: "x", entityRevision: 1, updatedAt: t0))
        // Same entity at a new path replaces the old record.
        try await database.documentFiles.upsert(DocumentFileRecord(projectId: projectId, relativePath: "b.md", kind: .request,
                                                                   entityId: entity, content: "y", entityRevision: 2, updatedAt: t0))
        #expect(try await database.documentFiles.list(projectId: projectId, kind: .request).map(\.relativePath) == ["b.md"])
        #expect(try await database.documentFiles.fetch(entityId: entity)?.contentHash == DocumentFileRecord.hash(Data("y".utf8)))

        let conflict = FileConflict(projectId: projectId, location: "b.md", kind: .concurrentEdit, databaseRevision: 2, detectedAt: t0)
        try await database.fileConflicts.insert(conflict)
        #expect(try await database.fileConflicts.open(projectId: projectId).count == 1)
        _ = try await database.fileConflicts.resolve(conflict.id, resolution: .keptDatabase, at: at(3))
        #expect(try await database.fileConflicts.open(projectId: nil).isEmpty)
        await #expect(throws: StoreError.self) { _ = try await database.fileConflicts.resolve(conflict.id, resolution: .dismissed, at: at(4)) }

        try await database.hostState.setValue(Data([1, 2]), scope: "s", key: "k", at: t0)
        #expect(try await database.hostState.value(scope: "s", key: "k") == Data([1, 2]))
        #expect(try await database.hostState.keys(scope: "s") == ["k"])

        let synced = try database.count("sync_outbox", "entity_type IN ('projectSetupCommand', 'indexedFolder', 'fileConflict')")
        // command: create + update; folder: create + changed kind; conflict: insert + resolve.
        #expect(synced == 6)
        #expect(try database.count("sync_outbox") == before + synced)
    }
}
