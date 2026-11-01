import Foundation
import GRDB
import SoftwareRegisseurDomain
import Testing
@testable import SoftwareRegisseurPersistence

@Suite("Sync hardening: paging, crash recovery, full upload, 3-way merge support")
struct SyncHardeningTests {
    func remote(_ item: WorkItem, version: Int, base: Int?) throws -> RemoteChange {
        RemoteChange(operationId: SyncOperationID(), entityType: .workItem, entityId: item.uuid.rawValue, kind: .update,
                     version: version, baseVersion: base, payload: try SyncPayloadCodec.encode(item),
                     systemFields: Data("fields-v\(version)".utf8))
    }

    func sendAll(_ database: AppDatabase, fields: Data? = nil) async throws {
        var cursor: SyncOutboxCursor?
        var operations: [SyncOperation] = []
        repeat {
            let page = try await database.sync.pendingOperations(limit: 100, after: cursor)
            operations += page.operations
            cursor = page.next
        } while cursor != nil
        for operation in operations {
            try await database.sync.markSent(operation.operationId, systemFields: fields, at: at(5))
        }
    }

    func allEntities(_ database: AppDatabase, pageSize: Int) async throws -> [SyncableEntity] {
        var cursor: SyncEntityCursor?
        var result: [SyncableEntity] = []
        var pages = 0
        repeat {
            let page = try await database.sync.syncableEntities(after: cursor, limit: pageSize)
            result += page.entities
            cursor = page.next
            pages += 1
            if pages > 1_000 { throw TestFailure() }
        } while cursor != nil
        return result
    }

    // MARK: Paging (gap 3)

    @Test func outboxPagingDrainsMoreThan500Entries() async throws {
        let database = try AppDatabase.inMemory()
        for index in 0..<300 {
            try await database.workItems.insert(Fixture.workItem(projectId: nil, title: "Aufgabe \(index)"),
                                                actor: deviceActor, at: at(Double(index % 7)))
        }
        let all = try await database.sync.pendingOperations(limit: 10_000)
        #expect(all.count == 600)

        var cursor: SyncOutboxCursor?
        var paged: [SyncOperation] = []
        var pages = 0
        repeat {
            let page = try await database.sync.pendingOperations(limit: 128, after: cursor)
            #expect(page.operations.count <= 128)
            paged += page.operations
            cursor = page.next
            pages += 1
        } while cursor != nil
        #expect(pages == 5)
        #expect(paged.map(\.operationId) == all.map(\.operationId))
        #expect(Set(paged.map(\.operationId)).count == 600)
        #expect(try await database.sync.unsentOperationCount() == 600)

        // Sent entries disappear from later pages; the cursor stays valid.
        let first = try await database.sync.pendingOperations(limit: 50, after: nil)
        for operation in first.operations.prefix(10) {
            try await database.sync.markSent(operation.operationId, systemFields: nil, at: at(10))
        }
        let rest = try await database.sync.pendingOperations(limit: 1_000, after: first.next)
        #expect(rest.operations.map(\.operationId) == Array(all.dropFirst(50)).map(\.operationId))
        #expect(rest.next == nil)

        // Lookup by entity, as the sync layer does per record batch.
        let keys = all.suffix(3).map { SyncEntityKey(entityType: SyncEntityType(rawValue: $0.entityType)!, entityId: $0.entityId) }
        let byEntity = try await database.sync.pendingOperations(for: keys)
        #expect(Set(byEntity.map(\.operationId)) == Set(all.suffix(3).map(\.operationId)))
    }

    // MARK: Crash safety (gap 2)

    @Test func inFlightOperationsAreResetAfterACrash() async throws {
        let database = try AppDatabase.inMemory()
        let (_, item) = try await database.seedItem()
        let pending = try await database.sync.pendingOperations(limit: 100)
        #expect(pending.count == 4) // settings, project, item, creation event
        let ids = pending.map(\.operationId)
        try await database.sync.markInFlight(ids, at: at(1))
        #expect(try await database.sync.pendingOperations(limit: 100).isEmpty)
        #expect(try await database.sync.unsentOperationCount() == 4)

        // One acknowledgement arrived before the "crash".
        try await database.sync.markSent(ids[0], systemFields: nil, at: at(2))
        #expect(try await database.sync.resetInFlightOperations(at: at(3)) == 3)
        #expect(try await database.sync.pendingOperations(limit: 100).map(\.operationId) == Array(ids.dropFirst()))
        #expect(try await database.sync.operation(ids[0])?.state == .succeeded)
        #expect(try await database.sync.resetInFlightOperations(at: at(4)) == 0)

        // markPending only returns in-flight entries; acknowledged ones stay acknowledged.
        try await database.sync.markInFlight([ids[1]], at: at(5))
        try await database.sync.markPending([ids[0], ids[1]], at: at(6))
        #expect(try await database.sync.operation(ids[0])?.state == .succeeded)
        #expect(try await database.sync.operation(ids[1])?.state == .pending)
        _ = item
    }

    // MARK: Full upload (gap 1)

    @Test func syncableEntitiesEnumeratesOnlySyncedValuesWithPayloadAndVersions() async throws {
        let database = try AppDatabase.inMemory()
        let (project, item) = try await database.seedItem()
        let note = AudioNote(localAssetRef: "a.m4a", provider: .appleOnDevice, consent: .notRequired, createdAt: t0)
        try await database.aiRecords.saveAudioNote(note, at: t0)
        let localProfile = ProviderProfile(providerId: .openAI, purpose: .textDrafting,
                                           keychainReference: KeychainReference(service: "s", account: "a"), deviceScope: .thisDeviceOnly)
        try await database.providerProfiles.save(localProfile, at: t0)
        let sharedProfile = ProviderProfile(providerId: .anthropic, purpose: .textDrafting,
                                            keychainReference: KeychainReference(service: "s", account: "b"), deviceScope: .iCloudKeychain)
        try await database.providerProfiles.save(sharedProfile, at: t0)
        try await database.capabilities.saveHost(AgentHost(hostId: Fixture.host, name: "Mac", lastSeen: t0, ready: true, serviceVersion: "1"), at: t0)

        let entities = try await allEntities(database, pageSize: 2)
        let keys = Set(entities.map { SyncEntityKey(entityType: $0.entityType, entityId: $0.entityId) })
        let events = try await database.events.events(forWorkItem: item.uuid)
        let expected = Set<SyncEntityKey>([
            SyncEntityKey(entityType: .project, entityId: project.id.rawValue),
            SyncEntityKey(entityType: .projectSettings, entityId: project.settingsId.rawValue),
            SyncEntityKey(entityType: .workItem, entityId: item.uuid.rawValue),
            SyncEntityKey(entityType: .providerProfile, entityId: sharedProfile.id.rawValue),
            SyncEntityKey(entityType: .agentHost, entityId: Fixture.host.rawValue),
        ]).union(events.map { SyncEntityKey(entityType: .taskEvent, entityId: $0.eventId.rawValue) })
        #expect(keys == expected)
        #expect(entities.count == expected.count)
        for entity in entities {
            #expect(try await database.sync.currentPayload(entityType: entity.entityType, entityId: entity.entityId) == entity.payload)
            #expect(entity.version?.localVersion == 1)
        }
        // Page size bounds the scanned rows; one large page returns the same.
        #expect(try await allEntities(database, pageSize: 1_000).map(\.entityId) == entities.map(\.entityId))
    }

    @Test func fullUploadRequeuesEverythingInResumableBatches() async throws {
        let database = try AppDatabase.inMemory()
        let (_, item) = try await database.seedItem()
        let note = AudioNote(localAssetRef: "a.m4a", provider: .appleOnDevice, consent: .notRequired, createdAt: t0)
        try await database.aiRecords.saveAudioNote(note, at: t0)
        for index in 0..<5 {
            try await database.workItems.insert(Fixture.workItem(projectId: nil, title: "Weitere \(index)"), actor: deviceActor, at: t0)
        }
        try await sendAll(database, fields: Data("old-zone-tag".utf8))
        #expect(try await database.sync.pendingOperations(limit: 100).isEmpty)
        let syncable = try await allEntities(database, pageSize: 100)
        #expect(syncable.count == 2 + 6 * 2)

        // An entity edited before the re-upload already has an operation; it is not queued twice.
        _ = try await database.workItems.update(item.uuid, expectedRevision: item.revision, actor: deviceActor, at: at(6)) {
            $0.title = "Lokal geändert"
        }
        let editedEvents = try await database.events.events(forWorkItem: item.uuid).count

        var cursor: SyncEntityCursor?
        var requeued = 0
        var alreadyQueued = 0
        var batches = 0
        repeat {
            let progress = try await database.sync.requeueForFullUpload(after: cursor, batchSize: 3, at: at(10))
            if batches == 0 {
                // The first batch drops every server change tag (the records are gone).
                #expect(try database.count("sync_entity_state", "system_fields IS NOT NULL") == 0)
            }
            requeued += progress.requeued
            alreadyQueued += progress.alreadyQueued
            cursor = progress.next
            batches += 1
        } while cursor != nil
        #expect(batches >= 5)
        let total = syncable.count + 1 // + the "edited" event
        #expect(requeued + alreadyQueued == total)
        #expect(alreadyQueued == 2) // edited item and its edit event
        #expect(editedEvents == 2)

        // Exactly one unsent operation per syncable entity, none for the audio note.
        let pending = try await database.sync.pendingOperations(limit: 1_000)
        #expect(pending.count == total)
        #expect(Set(pending.map { "\($0.entityType).\($0.entityId)" }).count == total)
        #expect(!pending.contains { $0.entityType == SyncEntityType.audioNote.rawValue })
        let reuploaded = try #require(pending.first { $0.entityType == "project" })
        #expect(reuploaded.version == 2)
        #expect(reuploaded.type == .update)
        let state = try await database.sync.entityVersion(entityType: .project, entityId: reuploaded.entityId)
        #expect(state?.syncedVersion == 1)
        #expect(state?.systemFields == nil)

        // Repeating (e.g. after a crash mid-way) queues nothing new.
        let again = try await database.sync.requeueForFullUpload(after: nil, batchSize: 1_000, at: at(11))
        #expect(again.requeued == 0)
        #expect(again.alreadyQueued == total)
        #expect(again.isComplete)
    }

    @Test func identicalRemoteContentConvergesInsteadOfConflicting() async throws {
        let database = try AppDatabase.inMemory()
        let (_, item) = try await database.seedItem()
        try await sendAll(database)
        // Zone lost: everything re-queued (local 2, synced 1) …
        _ = try await database.sync.requeueForFullUpload(after: nil, batchSize: 100, at: at(10))
        // … and another device re-uploaded the same content first.
        let outcome = try await database.sync.applyRemoteChanges([try remote(item, version: 2, base: 1)], engineState: nil, at: at(11))
        #expect(outcome == [.applied])
        #expect(try await database.sync.openConflicts().isEmpty)
        let state = try #require(try await database.sync.entityVersion(entityType: .workItem, entityId: item.uuid.rawValue))
        #expect(state.localVersion == 2)
        #expect(state.syncedVersion == 2)
        #expect(state.systemFields == Data("fields-v2".utf8))
        #expect(try await database.sync.pendingOperations(for: [SyncEntityKey(entityType: .workItem, entityId: item.uuid.rawValue)]).isEmpty)

        // Different content with unsent local edits is still a conflict.
        _ = try await database.workItems.update(item.uuid, expectedRevision: item.revision, actor: deviceActor, at: at(12)) { $0.title = "Lokal" }
        var other = item
        other.title = "Anders"
        other.touch(at: at(13))
        #expect(try await database.sync.applyRemoteChanges([try remote(other, version: 3, base: 2)], engineState: nil, at: at(13)) == [.conflict])
    }

    // MARK: System fields (gap 6)

    @Test func saveSystemFieldsNeverCreatesStateForUnsyncedEntities() async throws {
        let database = try AppDatabase.inMemory()
        let note = AudioNote(localAssetRef: "a.m4a", provider: .appleOnDevice, consent: .notRequired, createdAt: t0)
        try await database.aiRecords.saveAudioNote(note, at: t0)
        let profile = ProviderProfile(providerId: .openAI, purpose: .textDrafting,
                                      keychainReference: KeychainReference(service: "s", account: "a"), deviceScope: .thisDeviceOnly)
        try await database.providerProfiles.save(profile, at: t0)

        try await database.sync.saveSystemFields(Data([1]), entityType: .audioNote, entityId: note.id.rawValue, at: at(1))
        try await database.sync.saveSystemFields(Data([2]), entityType: .providerProfile, entityId: profile.id.rawValue, at: at(1))
        try await database.sync.saveSystemFields(nil, entityType: .workItem, entityId: UUID(), at: at(1))
        #expect(try database.count("sync_entity_state") == 0)

        // Synced entities still get their change tag.
        let (_, item) = try await database.seedItem()
        try await database.sync.saveSystemFields(Data([3]), entityType: .workItem, entityId: item.uuid.rawValue, at: at(2))
        #expect(try await database.sync.entityVersion(entityType: .workItem, entityId: item.uuid.rawValue)?.systemFields == Data([3]))
        try await database.sync.saveSystemFields(nil, entityType: .workItem, entityId: item.uuid.rawValue, at: at(3))
        #expect(try await database.sync.entityVersion(entityType: .workItem, entityId: item.uuid.rawValue)?.systemFields == nil)
        #expect(try await database.sync.entityVersion(entityType: .audioNote, entityId: note.id.rawValue) == nil)
    }

    // MARK: Ancestors (gap 4)

    @Test func ancestorIsTrackedAndSnapshottedIntoConflicts() async throws {
        let database = try AppDatabase.inMemory()
        let (_, item) = try await database.seedItem()
        try await sendAll(database)
        var state = try #require(try await database.sync.entityVersion(entityType: .workItem, entityId: item.uuid.rawValue))
        #expect(state.ancestorVersion == 1)
        #expect(state.ancestorPayload == (try SyncPayloadCodec.encode(item)))

        // A received version becomes the new ancestor.
        var remoteV2 = item
        remoteV2.structuredBody = "Zeile 1\nZeile 2\nZeile 3"
        remoteV2.touch(at: at(10))
        #expect(try await database.sync.applyRemoteChanges([try remote(remoteV2, version: 2, base: 1)], engineState: nil, at: at(10)) == [.applied])
        state = try #require(try await database.sync.entityVersion(entityType: .workItem, entityId: item.uuid.rawValue))
        #expect(state.ancestorVersion == 2)
        #expect(state.ancestorPayload == (try SyncPayloadCodec.encode(remoteV2)))

        // Concurrent edits: the conflict carries local, remote and their common ancestor.
        let local = try await database.workItems.update(item.uuid, expectedRevision: remoteV2.revision, actor: deviceActor, at: at(11)) {
            $0.structuredBody = "Zeile 1 lokal\nZeile 2\nZeile 3"
        }
        var remoteV3 = remoteV2
        remoteV3.structuredBody = "Zeile 1\nZeile 2\nZeile 3 remote"
        remoteV3.touch(at: at(12))
        #expect(try await database.sync.applyRemoteChanges([try remote(remoteV3, version: 3, base: 2)], engineState: nil, at: at(12)) == [.conflict])
        let conflict = try #require(try await database.sync.openConflicts().first)
        #expect(conflict.ancestorVersion == 2)
        #expect(try SyncPayloadCodec.decode(WorkItem.self, from: try #require(conflict.ancestorPayload)) == remoteV2)
        #expect(try SyncPayloadCodec.decode(WorkItem.self, from: try #require(conflict.localPayload)) == local)
        #expect(conflict.resolvedBy == nil)

        // Automatic merge: recorded as such, visible in the task history.
        var merged = local
        merged.structuredBody = "Zeile 1 lokal\nZeile 2\nZeile 3 remote"
        merged.touch(at: at(13))
        try await database.sync.resolveConflict(conflict.id, resolution: .merged(try SyncPayloadCodec.encode(merged)),
                                                resolvedBy: .automaticMerge, at: at(13))
        #expect(try await database.workItems.fetch(item.uuid) == merged)
        let resolved = try #require(try await database.sync.resolvedConflicts(limit: 10).first)
        #expect(resolved.id == conflict.id)
        #expect(resolved.resolution == "merged")
        #expect(resolved.resolvedBy == .automaticMerge)
        let event = try #require(try await database.events.events(forWorkItem: item.uuid).last)
        #expect(event.kind == .edited)
        #expect(event.actor == .external)
        #expect(event.payload["resolvedBy"] == "automaticMerge")
        #expect(event.payload["conflictId"] == conflict.id.uuidString)
        #expect(event.payload["fields"]?.contains("structuredBody") == true)
        // Until the merged value is confirmed, the server's version is the ancestor.
        state = try #require(try await database.sync.entityVersion(entityType: .workItem, entityId: item.uuid.rawValue))
        #expect(state.ancestorVersion == 3)
        try await sendAll(database)
        state = try #require(try await database.sync.entityVersion(entityType: .workItem, entityId: item.uuid.rawValue))
        #expect(state.ancestorVersion == state.localVersion)
        #expect(state.ancestorPayload == (try SyncPayloadCodec.encode(merged)))

        // User resolutions are recorded as `user`.
        let user = try await database.workItems.update(item.uuid, expectedRevision: merged.revision, actor: deviceActor, at: at(20)) { $0.title = "A" }
        var remoteV5 = merged
        remoteV5.title = "B"
        remoteV5.touch(at: at(21))
        _ = try await database.sync.applyRemoteChanges([try remote(remoteV5, version: state.localVersion + 1, base: state.localVersion)], engineState: nil, at: at(21))
        let second = try #require(try await database.sync.openConflicts().first)
        try await database.sync.resolveConflict(second.id, resolution: .keepLocal, at: at(22))
        #expect(try await database.sync.conflict(second.id)?.resolvedBy == .user)
        #expect(try await database.events.events(forWorkItem: item.uuid).last?.payload["resolvedBy"] == nil)
        _ = user
    }

    @Test func ancestorIsWithheldWhenTheRemoteChangeIsNotBasedOnIt() async throws {
        let database = try AppDatabase.inMemory()
        let (_, item) = try await database.seedItem()
        try await sendAll(database)
        var remoteV2 = item
        remoteV2.title = "V2"
        remoteV2.touch(at: at(10))
        _ = try await database.sync.applyRemoteChanges([try remote(remoteV2, version: 2, base: 1)], engineState: nil, at: at(10))
        _ = try await database.workItems.update(item.uuid, expectedRevision: remoteV2.revision, actor: deviceActor, at: at(11)) { $0.title = "Lokal" }
        // Based on version 1, which is older than the shared ancestor (2): the true base is unknown here.
        var stale = item
        stale.title = "Alt"
        stale.touch(at: at(12))
        _ = try await database.sync.applyRemoteChanges([try remote(stale, version: 3, base: 1)], engineState: nil, at: at(12))
        let conflict = try #require(try await database.sync.openConflicts().first)
        #expect(conflict.ancestorPayload == nil)
        #expect(conflict.ancestorVersion == nil)
    }

    // MARK: Migration v1 → v2 (gap 4)

    @Test func migratesExistingV1DatabaseFileWithData() async throws {
        let directory = try TemporaryDirectory()
        let item: WorkItem
        let project: Project
        let legacyConflict = UUID()
        do {
            let v1 = try AppDatabase.openWriter(at: directory.databaseURL, migratingUpTo: "v1_initial")
            #expect(try v1.appliedMigrations() == ["v1_initial"])
            (project, item) = try await v1.seedItem()
            // State as a v1 sync layer leaves it: everything sent, plus an open conflict.
            try await v1.writer!.write { db in
                try db.execute(sql: "UPDATE sync_outbox SET state = 'succeeded'")
                try db.execute(sql: "UPDATE sync_entity_state SET synced_version = local_version, system_fields = X'01'")
                try db.execute(sql: """
                    INSERT INTO sync_conflicts (conflict_id, entity_type, entity_id, base_version, local_version, remote_version,
                        local_payload, remote_payload, remote_change_kind, remote_operation_id, remote_system_fields, detected_at)
                    VALUES (?, 'project', ?, 1, 2, 2, NULL, NULL, 'delete', ?, NULL, ?)
                    """, arguments: [legacyConflict.uuidString, project.id.rawValue.uuidString, UUID().uuidString, StoredDate.value(t0)])
            }
            let columns = try await v1.reader.read { db in try db.columns(in: "sync_entity_state").map(\.name) }
            #expect(!columns.contains("ancestor_payload"))
        }

        let database = try AppDatabase.openWriter(at: directory.databaseURL)
        #expect(try database.appliedMigrations() == AppSchema.migrationIdentifiers)
        #expect(Array(AppSchema.migrationIdentifiers.prefix(2)) == ["v1_initial", "v2_sync_three_way_merge"])
        let stateColumns = try await database.reader.read { db in try db.columns(in: "sync_entity_state").map(\.name) }
        let conflictColumns = try await database.reader.read { db in try db.columns(in: "sync_conflicts").map(\.name) }
        #expect(stateColumns.contains("ancestor_payload") && stateColumns.contains("ancestor_version"))
        #expect(conflictColumns.contains("ancestor_payload") && conflictColumns.contains("resolved_by"))

        // Data is intact and readable; ancestors of old rows are unknown.
        #expect(try await database.workItems.fetch(item.uuid) == item)
        #expect(try await database.projects.fetch(project.id) == project)
        let state = try #require(try await database.sync.entityVersion(entityType: .workItem, entityId: item.uuid.rawValue))
        #expect(state.syncedVersion == 1)
        #expect(state.systemFields == Data([1]))
        #expect(state.ancestorPayload == nil)
        #expect(state.ancestorVersion == nil)
        let legacy = try #require(try await database.sync.conflict(legacyConflict))
        #expect(legacy.ancestorPayload == nil)
        #expect(legacy.resolvedBy == nil)
        #expect(try database.count("sync_outbox", "state = 'succeeded'") == 4)

        // A conflict on pre-v2 data has no ancestor (the user decides).
        _ = try await database.workItems.update(item.uuid, expectedRevision: item.revision, actor: deviceActor, at: at(10)) { $0.title = "Lokal" }
        var remoteItem = item
        remoteItem.title = "Remote"
        remoteItem.touch(at: at(11))
        #expect(try await database.sync.applyRemoteChanges([try remote(remoteItem, version: 2, base: 1)], engineState: nil, at: at(11)) == [.conflict])
        let conflict = try #require(try await database.sync.openConflicts().first { $0.entityType == .workItem })
        #expect(conflict.ancestorPayload == nil)

        // From now on ancestors are recorded, and the old conflict can still be resolved.
        try await database.sync.resolveConflict(conflict.id, resolution: .acceptRemote, at: at(12))
        #expect(try await database.sync.entityVersion(entityType: .workItem, entityId: item.uuid.rawValue)?.ancestorVersion == 2)
        try await database.sync.resolveConflict(legacyConflict, resolution: .keepLocal, at: at(13))
        #expect(try await database.sync.conflict(legacyConflict)?.resolvedBy == .user)

        // Reopening runs no further migration.
        let reopened = try AppDatabase.openWriter(at: directory.databaseURL)
        #expect(try reopened.appliedMigrations() == AppSchema.migrationIdentifiers)
    }

    // MARK: Codec (gap 5)

    @Test func publicCodecMatchesStoredPayloadsAndCanonicalizes() async throws {
        let database = try AppDatabase.inMemory()
        let (_, item) = try await database.seedItem()
        let stored = try #require(try await database.sync.currentPayload(entityType: .workItem, entityId: item.uuid.rawValue))
        #expect(try SyncPayloadCodec.encode(item) == stored)
        #expect(try SyncPayloadCodec.decode(WorkItem.self, from: stored) == item)

        // Same value, different formatting (unsorted keys, pretty printed) → identical canonical bytes.
        let object = try JSONSerialization.jsonObject(with: stored)
        let reformatted = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        #expect(reformatted != stored)
        #expect(try SyncPayloadCodec.canonicalize(reformatted, entityType: .workItem) == stored)
        #expect(throws: StoreError.self) {
            try SyncPayloadCodec.canonicalize(Data("{\"title\":1}".utf8), entityType: .workItem)
        }
    }
}
