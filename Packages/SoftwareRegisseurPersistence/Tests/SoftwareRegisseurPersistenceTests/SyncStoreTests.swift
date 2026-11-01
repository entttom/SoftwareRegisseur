import Foundation
import GRDB
import SoftwareRegisseurDomain
import Testing
@testable import SoftwareRegisseurPersistence

@Suite("Sync bookkeeping")
struct SyncStoreTests {
    func payload(_ item: WorkItem) throws -> Data { try JSONColumn.encodeData(item) }

    func remote(_ item: WorkItem, version: Int, base: Int?, kind: SyncOperationType = .update,
                operation: SyncOperationID = SyncOperationID()) throws -> RemoteChange {
        RemoteChange(operationId: operation, entityType: .workItem, entityId: item.uuid.rawValue, kind: kind,
                     version: version, baseVersion: base, payload: kind == .delete ? nil : try payload(item),
                     systemFields: Data("fields-v\(version)".utf8))
    }

    /// Marks every pending operation as sent, as the sync layer would after a successful batch.
    func sendAll(_ database: AppDatabase) async throws {
        for operation in try await database.sync.pendingOperations(limit: 1000) {
            try await database.sync.markSent(operation.operationId, systemFields: nil, at: at(5))
        }
    }

    @Test func outboxEntryIsWrittenInTheSameTransaction() async throws {
        let database = try AppDatabase.inMemory()
        let item = Fixture.workItem(projectId: nil)

        // Rollback: entity, outbox entry and version disappear together.
        await #expect(throws: TestFailure.self) {
            try await database.write { db in
                try SyncBookkeeping.save(db, WorkItemStorage.self, item, isNew: true, at: t0)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_outbox") == 1)
                throw TestFailure()
            }
        }
        #expect(try database.count("work_items") == 0)
        #expect(try database.count("sync_outbox") == 0)
        #expect(try database.count("sync_entity_state") == 0)

        // Commit: item + creation event, each with one outbox entry.
        try await database.workItems.insert(item, actor: deviceActor, at: t0)
        let outbox = try database.outbox()
        #expect(outbox.map(\.type) == ["workItem", "taskEvent"])
        #expect(outbox.first?.id == item.uuid.uuidString)
        #expect(outbox.first?.kind == "create")
        #expect(outbox.first?.version == 1)

        // A failing repository write leaves no outbox entry behind.
        let before = try database.count("sync_outbox")
        var wrong = Fixture.workItem(projectId: nil)
        wrong.title = "x"
        await #expect(throws: StoreError.self) {
            _ = try await database.workItems.update(wrong, expectedRevision: 1, actor: deviceActor, at: at(1))
        }
        #expect(try database.count("sync_outbox") == before)
    }

    @Test func deviceLocalDataNeverEntersTheOutbox() async throws {
        let database = try AppDatabase.inMemory()
        let note = AudioNote(localAssetRef: "a.m4a", provider: .appleOnDevice, consent: .notRequired, createdAt: t0)
        try await database.aiRecords.saveAudioNote(note, at: t0)
        var profile = ProviderProfile(providerId: .openAI, purpose: .textDrafting,
                                      keychainReference: KeychainReference(service: "s", account: "a"), deviceScope: .thisDeviceOnly)
        try await database.providerProfiles.save(profile, at: t0)
        #expect(try database.count("sync_outbox") == 0)

        profile.deviceScope = .iCloudKeychain
        try await database.providerProfiles.save(profile, at: at(1))
        #expect(try database.outbox().map(\.kind) == ["update"])
        profile.deviceScope = .thisDeviceOnly
        try await database.providerProfiles.save(profile, at: at(2))
        #expect(try database.outbox().map(\.kind) == ["update", "delete"])
        #expect(try await database.providerProfiles.fetch(profile.id) == profile)
    }

    @Test func markSentAdvancesSyncedVersionAndStoresSystemFields() async throws {
        let database = try AppDatabase.inMemory()
        let (_, item) = try await database.seedItem()
        let operation = try #require(try await database.sync.pendingOperations(limit: 100).first { $0.entityId == item.uuid.rawValue })
        try await database.sync.markInFlight([operation.operationId], at: at(1))
        #expect(try await database.sync.pendingOperations(limit: 100).contains { $0.operationId == operation.operationId } == false)
        try await database.sync.markSent(operation.operationId, systemFields: Data("tag-1".utf8), at: at(2))

        let version = try #require(try await database.sync.entityVersion(entityType: .workItem, entityId: item.uuid.rawValue))
        #expect(version.localVersion == 1)
        #expect(version.syncedVersion == 1)
        #expect(!version.hasUnsentChanges)
        #expect(version.systemFields == Data("tag-1".utf8))
        #expect(try await database.sync.operation(operation.operationId)?.state == .succeeded)
        #expect(try await database.sync.pruneSucceededOperations(olderThan: at(3)) == 1)
    }

    @Test func replayedOperationIsAppliedOnlyOnce() async throws {
        let database = try AppDatabase.inMemory()
        var item = Fixture.workItem(projectId: nil)
        let operation = SyncOperationID()
        let first = try await database.sync.applyRemoteChanges([try remote(item, version: 1, base: nil, kind: .create, operation: operation)],
                                                               engineState: nil, at: t0)
        #expect(first == [.applied])

        // Same operation again, even with different content: ignored.
        item.title = "Manipuliert"
        let second = try await database.sync.applyRemoteChanges([try remote(item, version: 2, base: 1, operation: operation)],
                                                                engineState: nil, at: at(1))
        #expect(second == [.duplicate])
        #expect(try await database.workItems.fetch(item.uuid)?.title == "Neue Funktion")
        #expect(try await database.sync.hasAppliedOperation(operation))
        #expect(try database.count("sync_inbox") == 1)
        // Remote changes do not echo back into the outbox.
        #expect(try database.count("sync_outbox") == 0)
    }

    @Test func remoteChangesFastForwardWithoutLocalEdits() async throws {
        let database = try AppDatabase.inMemory()
        var item = Fixture.workItem(projectId: nil)
        _ = try await database.sync.applyRemoteChanges([try remote(item, version: 1, base: nil, kind: .create)], engineState: nil, at: t0)
        item.title = "Version 3"
        item.touch(at: at(3))
        // Version 2 was never received; CloudKit only delivers the latest record.
        let outcome = try await database.sync.applyRemoteChanges([try remote(item, version: 3, base: 2)], engineState: nil, at: at(3))
        #expect(outcome == [.applied])
        #expect(try await database.workItems.fetch(item.uuid) == item)
        let version = try await database.sync.entityVersion(entityType: .workItem, entityId: item.uuid.rawValue)
        #expect(version?.syncedVersion == 3)
        #expect(version?.systemFields == Data("fields-v3".utf8))

        // Older or equal versions are stale.
        var old = item
        old.title = "Alt"
        #expect(try await database.sync.applyRemoteChanges([try remote(old, version: 2, base: 1)], engineState: nil, at: at(4)) == [.stale])
        #expect(try await database.workItems.fetch(item.uuid)?.title == "Version 3")
    }

    @Test func concurrentEditsProduceConflictWithBothVersions() async throws {
        let database = try AppDatabase.inMemory()
        let (_, item) = try await database.seedItem()
        try await sendAll(database)

        // Offline edit on the Mac (local version 2, unsent) …
        let local = try await database.workItems.update(item.uuid, expectedRevision: 1, actor: deviceActor, at: at(10)) {
            $0.structuredBody = "Mac-Text"
        }
        // … while the iPhone edited the same item from synced version 1 (A24).
        var phone = item
        phone.structuredBody = "iPhone-Text"
        phone.touch(at: at(11))
        let outcome = try await database.sync.applyRemoteChanges([try remote(phone, version: 2, base: 1)], engineState: nil, at: at(12))
        #expect(outcome == [.conflict])

        // No silent overwrite: local text unchanged, both versions stored.
        #expect(try await database.workItems.fetch(item.uuid) == local)
        let conflict = try #require(try await database.sync.openConflicts().first)
        #expect(conflict.entityType == .workItem)
        #expect(conflict.entityId == item.uuid.rawValue)
        #expect(conflict.baseVersion == 1)
        #expect(conflict.localVersion == 2)
        #expect(conflict.remoteVersion == 2)
        #expect(try JSONColumn.decode(WorkItem.self, from: conflict.localPayload!) == local)
        #expect(try JSONColumn.decode(WorkItem.self, from: conflict.remotePayload!) == phone)
        // Visible in the task history.
        #expect(try await database.events.events(forWorkItem: item.uuid).last?.kind == .conflictDetected)
    }

    @Test func conflictResolutionKeepLocalAcceptRemoteAndMerge() async throws {
        for resolution in ["keepLocal", "acceptRemote", "merged"] {
            let database = try AppDatabase.inMemory()
            let (_, item) = try await database.seedItem()
            try await sendAll(database)
            let local = try await database.workItems.update(item.uuid, expectedRevision: 1, actor: deviceActor, at: at(10)) {
                $0.title = "Lokal"
            }
            var phone = item
            phone.title = "Remote"
            phone.touch(at: at(11))
            _ = try await database.sync.applyRemoteChanges([try remote(phone, version: 2, base: 1)], engineState: nil, at: at(12))
            let conflict = try #require(try await database.sync.openConflicts().first)

            switch resolution {
            case "keepLocal":
                try await database.sync.resolveConflict(conflict.id, resolution: .keepLocal, at: at(20))
                #expect(try await database.workItems.fetch(item.uuid) == local)
                let pending = try await database.sync.pendingOperations(limit: 100).filter { $0.entityId == item.uuid.rawValue }
                #expect(pending.map(\.version) == [3])
            case "acceptRemote":
                try await database.sync.resolveConflict(conflict.id, resolution: .acceptRemote, at: at(20))
                #expect(try await database.workItems.fetch(item.uuid) == phone)
                #expect(try await database.sync.pendingOperations(limit: 100).contains { $0.entityId == item.uuid.rawValue } == false)
            default:
                var merged = local
                merged.title = "Lokal + Remote"
                merged.touch(at: at(20))
                try await database.sync.resolveConflict(conflict.id, resolution: .merged(try payload(merged)), at: at(20))
                #expect(try await database.workItems.fetch(item.uuid) == merged)
            }
            let version = try await database.sync.entityVersion(entityType: .workItem, entityId: item.uuid.rawValue)
            #expect(version?.syncedVersion == 2)
            #expect(version?.systemFields == Data("fields-v2".utf8))
            #expect(try await database.sync.openConflicts().isEmpty)
            await #expect(throws: StoreError.conflictAlreadyResolved(conflict.id)) {
                try await database.sync.resolveConflict(conflict.id, resolution: .keepLocal, at: at(21))
            }
        }
    }

    @Test func tombstonesPreventResurrection() async throws {
        let database = try AppDatabase.inMemory()
        var item = Fixture.workItem(projectId: nil)
        _ = try await database.sync.applyRemoteChanges([try remote(item, version: 1, base: nil, kind: .create)], engineState: nil, at: t0)

        // Remote deletion.
        let deleted = try await database.sync.applyRemoteChanges([try remote(item, version: 2, base: 1, kind: .delete)], engineState: nil, at: at(1))
        #expect(deleted == [.deleted])
        #expect(try await database.workItems.fetch(item.uuid) == nil)
        let tombstone = try #require(try await database.sync.tombstone(entityType: .workItem, entityId: item.uuid.rawValue))
        #expect(tombstone.version == 2)
        #expect(tombstone.origin == .remote)

        // A late, older update must not bring it back.
        item.title = "Spät"
        let late = try await database.sync.applyRemoteChanges([try remote(item, version: 2, base: 1)], engineState: nil, at: at(2))
        #expect(late == [.stale])
        #expect(try await database.workItems.fetch(item.uuid) == nil)
    }

    @Test func remoteEditOfLocallyDeletedEntityIsAConflict() async throws {
        let database = try AppDatabase.inMemory()
        let (_, item) = try await database.seedItem()
        try await sendAll(database)
        try await database.workItems.delete(item.uuid, expectedRevision: 1, at: at(1))
        let tombstone = try #require(try await database.sync.tombstone(entityType: .workItem, entityId: item.uuid.rawValue))
        #expect(tombstone.origin == .local)
        #expect(tombstone.version == 2)

        var phone = item
        phone.title = "Remote bearbeitet"
        phone.touch(at: at(2))
        let outcome = try await database.sync.applyRemoteChanges([try remote(phone, version: 3, base: 1)], engineState: nil, at: at(3))
        #expect(outcome == [.conflict])
        let conflict = try #require(try await database.sync.openConflicts().first)
        #expect(conflict.localPayload == nil)
        #expect(try await database.workItems.fetch(item.uuid) == nil)

        // Remote deletion of a locally deleted entity converges without conflict.
        let (_, other) = try await database.seedItem()
        try await sendAll(database)
        try await database.workItems.delete(other.uuid, expectedRevision: 1, at: at(4))
        let both = try await database.sync.applyRemoteChanges([try remote(other, version: 2, base: 1, kind: .delete)], engineState: nil, at: at(5))
        #expect(both == [.deleted])
    }

    @Test func engineStateIsSavedAtomicallyWithFetchedChanges() async throws {
        let database = try AppDatabase.inMemory()
        let item = Fixture.workItem(projectId: nil)
        _ = try await database.sync.applyRemoteChanges([try remote(item, version: 1, base: nil, kind: .create)],
                                                       engineState: (scope: "private", data: Data("state-1".utf8)), at: t0)
        #expect(try await database.sync.engineState(scope: "private") == Data("state-1".utf8))

        // A batch with an invalid record fails as a whole: no change, no new engine state.
        let good = Fixture.workItem(projectId: nil, title: "Gut")
        let mismatched = RemoteChange(operationId: SyncOperationID(), entityType: .workItem, entityId: UUID(), kind: .create,
                                      version: 1, baseVersion: nil, payload: try payload(good))
        await #expect(throws: StoreError.self) {
            _ = try await database.sync.applyRemoteChanges([try remote(good, version: 1, base: nil, kind: .create), mismatched],
                                                           engineState: (scope: "private", data: Data("state-2".utf8)), at: at(1))
        }
        #expect(try await database.workItems.fetch(good.uuid) == nil)
        #expect(try await database.sync.engineState(scope: "private") == Data("state-1".utf8))
        #expect(try database.count("sync_inbox") == 1)

        try await database.sync.saveEngineState(Data("state-3".utf8), scope: "private", at: at(2))
        #expect(try await database.sync.engineState(scope: "private") == Data("state-3".utf8))
    }

    @Test func systemFieldsCanBeStoredPerEntity() async throws {
        let database = try AppDatabase.inMemory()
        let entityId = UUID()
        try await database.sync.saveSystemFields(Data([1, 2, 3]), entityType: .agentHost, entityId: entityId, at: t0)
        #expect(try await database.sync.entityVersion(entityType: .agentHost, entityId: entityId)?.systemFields == Data([1, 2, 3]))
    }
}
