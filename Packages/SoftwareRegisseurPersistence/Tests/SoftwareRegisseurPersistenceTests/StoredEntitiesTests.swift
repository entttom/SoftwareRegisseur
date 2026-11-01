import Foundation
import SoftwareRegisseurDomain
import Testing
@testable import SoftwareRegisseurPersistence

@Suite("Stored entities: paged read of everything, including device-local values (export, A34)")
struct StoredEntitiesTests {
    func allStored(_ database: AppDatabase, pageSize: Int, after start: SyncEntityCursor? = nil) async throws -> [StoredEntity] {
        var cursor = start
        var result: [StoredEntity] = []
        var pages = 0
        repeat {
            let page = try await database.sync.storedEntities(after: cursor, limit: pageSize)
            #expect(page.entities.count <= pageSize)
            result += page.entities
            cursor = page.next
            pages += 1
            if pages > 1_000 { throw TestFailure() }
        } while cursor != nil
        return result
    }

    @Test func storedEntitiesIncludeDeviceLocalValuesWithSyncFlag() async throws {
        let database = try AppDatabase.inMemory()
        let (project, item) = try await database.seedItem()
        var notes: [AudioNote] = []
        for index in 0..<3 {
            let note = AudioNote(localAssetRef: "a\(index).m4a", provider: .appleOnDevice, consent: .notRequired, createdAt: t0)
            try await database.aiRecords.saveAudioNote(note, at: t0)
            notes.append(note)
        }
        let localProfile = ProviderProfile(providerId: .openAI, purpose: .textDrafting,
                                           keychainReference: KeychainReference(service: "s", account: "a"), deviceScope: .thisDeviceOnly)
        try await database.providerProfiles.save(localProfile, at: t0)
        let sharedProfile = ProviderProfile(providerId: .anthropic, purpose: .textDrafting,
                                            keychainReference: KeychainReference(service: "s", account: "b"), deviceScope: .iCloudKeychain)
        try await database.providerProfiles.save(sharedProfile, at: t0)

        let stored = try await allStored(database, pageSize: 2)
        let keys = stored.map { SyncEntityKey(entityType: $0.entityType, entityId: $0.entityId) }
        #expect(Set(keys).count == keys.count, "every entity exactly once")

        // Everything that syncs is part of it, with the same payload as `syncableEntities`.
        var cursor: SyncEntityCursor?
        repeat {
            let page = try await database.sync.syncableEntities(after: cursor, limit: 100)
            for entity in page.entities {
                let match = stored.first { $0.entityType == entity.entityType && $0.entityId == entity.entityId }
                #expect(match?.payload == entity.payload)
                #expect(match?.syncs == true)
            }
            cursor = page.next
        } while cursor != nil

        // Device-local values are included and flagged.
        let storedNotes = stored.filter { $0.entityType == .audioNote }
        #expect(Set(storedNotes.map(\.entityId)) == Set(notes.map(\.id.rawValue)))
        #expect(storedNotes.allSatisfy { !$0.syncs })
        let profiles = stored.filter { $0.entityType == .providerProfile }
        #expect(profiles.first { $0.entityId == localProfile.id.rawValue }?.syncs == false)
        #expect(profiles.first { $0.entityId == sharedProfile.id.rawValue }?.syncs == true)
        for entity in stored {
            #expect(try await database.sync.currentPayload(entityType: entity.entityType, entityId: entity.entityId) == entity.payload)
        }
        #expect(stored.contains { $0.entityType == .project && $0.entityId == project.id.rawValue })
        #expect(stored.contains { $0.entityType == .workItem && $0.entityId == item.uuid.rawValue })

        // Device-local kinds come last; page size does not change the result.
        let lastSyncing = try #require(stored.lastIndex { !$0.entityType.isDeviceLocal })
        let firstLocal = try #require(stored.firstIndex { $0.entityType.isDeviceLocal })
        #expect(lastSyncing < firstLocal)
        #expect(try await allStored(database, pageSize: 1_000).map(\.entityId) == stored.map(\.entityId))
        #expect(try await allStored(database, pageSize: 1).map(\.entityId) == stored.map(\.entityId))
    }

    @Test func storedEntitiesResumeFromACursorAndWorkReadOnly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stored-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("db.sqlite")
        let writer = try AppDatabase.openWriter(at: url)
        _ = try await writer.seedItem()
        let note = AudioNote(localAssetRef: "a.m4a", provider: .appleOnDevice, consent: .notRequired, createdAt: t0)
        try await writer.aiRecords.saveAudioNote(note, at: t0)

        let reader = try AppDatabase.openReadOnly(at: url)
        let all = try await allStored(reader, pageSize: 3)
        #expect(all.contains { $0.entityType == .audioNote && $0.entityId == note.id.rawValue })
        let first = try await reader.sync.storedEntities(after: nil, limit: 2)
        let rest = try await allStored(reader, pageSize: 3, after: try #require(first.next))
        #expect((first.entities + rest).map(\.entityId) == all.map(\.entityId))
    }

    @Test func closedDatabaseRefusesAccessAndFilesCanBeReopened() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("close-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("db.sqlite")
        let database = try AppDatabase.openWriter(at: url)
        let (project, _) = try await database.seedItem()
        try database.close()
        await #expect(throws: (any Error).self) { _ = try await database.projects.fetch(project.id) }
        let reopened = try AppDatabase.openWriter(at: url)
        #expect(try await reopened.projects.fetch(project.id) != nil)
    }
}
