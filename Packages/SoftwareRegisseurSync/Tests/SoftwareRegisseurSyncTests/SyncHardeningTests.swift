import CloudKit
import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence
@testable import SoftwareRegisseurSync
import SoftwareRegisseurSyncTesting
import Synchronization
import Testing

// MARK: - 3-way merge helpers

@Suite("3-way merge")
struct ThreeWayMergeTests {
    @Test func nonOverlappingLineChangesMergeCleanly() {
        let base = "Ziel\nKontext\nAkzeptanz\nNotizen"
        let local = "Ziel (geschärft)\nKontext\nAkzeptanz\nNotizen"
        let remote = "Ziel\nKontext\nAkzeptanz\nNotizen\n- neue Notiz"
        #expect(ThreeWayTextMerge.merge(base: base, local: local, remote: remote)
            == .merged("Ziel (geschärft)\nKontext\nAkzeptanz\nNotizen\n- neue Notiz"))
        // Adjacent (not overlapping) line edits.
        #expect(ThreeWayTextMerge.merge(base: "a\nb\nc", local: "A\nb\nc", remote: "a\nB\nc") == .merged("A\nB\nc"))
        // Deletion on one side, edit elsewhere on the other.
        #expect(ThreeWayTextMerge.merge(base: "a\nb\nc\nd", local: "a\nc\nd", remote: "a\nb\nc\nD") == .merged("a\nc\nD"))
        // Identical edits on both sides are taken once.
        #expect(ThreeWayTextMerge.merge(base: "a\nb", local: "a\nX\nb", remote: "a\nX\nb") == .merged("a\nX\nb"))
        #expect(ThreeWayTextMerge.merge(base: "a\nb\nc", local: "A\nb\nc", remote: "A\nb\nC") == .merged("A\nb\nC"))
    }

    @Test func overlappingChangesAreAConflict() {
        #expect(ThreeWayTextMerge.merge(base: "a\nb\nc", local: "a\nB1\nc", remote: "a\nB2\nc") == .conflict)
        // Different insertions at the same place: order unknown.
        #expect(ThreeWayTextMerge.merge(base: "a\nb", local: "a\nX\nb", remote: "a\nY\nb") == .conflict)
        // Insertion at the edge of the other side's change.
        #expect(ThreeWayTextMerge.merge(base: "a\nb\nc", local: "a\nB\nc", remote: "a\nb\nY\nc") == .conflict)
        // Edit vs deletion of the same line.
        #expect(ThreeWayTextMerge.merge(base: "a\nb\nc", local: "a\nB\nc", remote: "a\nc") == .conflict)
    }

    @Test func payloadMergeCombinesFieldsAndBookkeeping() throws {
        var base = Fixture.workItem(projectId: nil, title: "Titel", body: "Zeile 1\nZeile 2\nZeile 3")
        base.labels = ["a"]
        var local = base
        local.title = "Titel lokal"
        local.structuredBody = "Zeile 1 lokal\nZeile 2\nZeile 3"
        local.touch(at: t0.addingTimeInterval(10))
        var remote = base
        remote.structuredBody = "Zeile 1\nZeile 2\nZeile 3 remote"
        remote.labels = ["a", "b"]
        remote.touch(at: t0.addingTimeInterval(20))

        let outcome = try SyncPayloadMerge.merge(ancestor: try payload(base), local: try payload(local), remote: try payload(remote))
        guard case let .merged(data, fields) = outcome else { Issue.record("expected merge, got \(outcome)"); return }
        #expect(fields == ["structuredBody"])
        let canonical = try SyncPayloadCodec.canonicalize(data, entityType: .workItem)
        let merged = try decode(WorkItem.self, canonical)
        #expect(merged.title == "Titel lokal")
        #expect(merged.labels == ["a", "b"])
        #expect(merged.structuredBody == "Zeile 1 lokal\nZeile 2\nZeile 3 remote")
        #expect(merged.revision == 3)
        #expect(merged.updatedAt == t0.addingTimeInterval(20))
        #expect(merged.uuid == base.uuid)

        // Same field changed differently (non-text and text) → conflict, with the field names.
        var otherLabels = local
        otherLabels.labels = ["c"]
        guard case let .conflict(conflicting) = try SyncPayloadMerge.merge(
            ancestor: try payload(base), local: try payload(otherLabels), remote: try payload(remote)
        ) else { Issue.record("expected conflict"); return }
        #expect(conflicting == ["labels"])
        var otherTitle = remote
        otherTitle.title = "Titel remote"
        guard case let .conflict(titleConflict) = try SyncPayloadMerge.merge(
            ancestor: try payload(base), local: try payload(local), remote: try payload(otherTitle)
        ) else { Issue.record("expected conflict"); return }
        #expect(titleConflict == ["title"])
    }
}

// MARK: - Coordinator hardening

/// `SyncStore` that "crashes" right after the first `markInFlight` was committed: from then on every
/// write fails, as if the process died after handing the records to CloudKit and before any
/// acknowledgement reached the database.
final class CrashingSyncStore: SyncStore {
    struct SimulatedCrash: Error {}
    let base: GRDBSyncStore
    private let crashed = Mutex(false)

    init(_ base: GRDBSyncStore) { self.base = base }

    var hasCrashed: Bool { crashed.withLock { $0 } }

    private func write<T>(_ body: () async throws -> T) async throws -> T {
        if hasCrashed { throw SimulatedCrash() }
        return try await body()
    }

    func markInFlight(_ ids: [SyncOperationID], at date: Date) async throws {
        try await write { try await base.markInFlight(ids, at: date) }
        crashed.withLock { $0 = true }
    }

    func pendingOperations(limit: Int) async throws -> [SyncOperation] { try await base.pendingOperations(limit: limit) }
    func pendingOperations(limit: Int, after cursor: SyncOutboxCursor?) async throws -> SyncOutboxPage {
        try await base.pendingOperations(limit: limit, after: cursor)
    }
    func pendingOperations(for entities: [SyncEntityKey]) async throws -> [SyncOperation] { try await base.pendingOperations(for: entities) }
    func unsentOperationCount() async throws -> Int { try await base.unsentOperationCount() }
    func markPending(_ ids: [SyncOperationID], at date: Date) async throws { try await write { try await base.markPending(ids, at: date) } }
    func resetInFlightOperations(at date: Date) async throws -> Int { try await write { try await base.resetInFlightOperations(at: date) } }
    func syncableEntities(after cursor: SyncEntityCursor?, limit: Int) async throws -> SyncableEntityPage {
        try await base.syncableEntities(after: cursor, limit: limit)
    }
    func requeueForFullUpload(after cursor: SyncEntityCursor?, batchSize: Int, at date: Date) async throws -> FullUploadProgress {
        try await write { try await base.requeueForFullUpload(after: cursor, batchSize: batchSize, at: date) }
    }
    func resolveConflict(_ id: UUID, resolution: ConflictResolution, resolvedBy: ConflictResolver, at date: Date) async throws {
        try await write { try await base.resolveConflict(id, resolution: resolution, resolvedBy: resolvedBy, at: date) }
    }
    func resolvedConflicts(limit: Int) async throws -> [SyncConflict] { try await base.resolvedConflicts(limit: limit) }
    func operation(_ id: SyncOperationID) async throws -> SyncOperation? { try await base.operation(id) }
    func markSent(_ id: SyncOperationID, systemFields: Data?, at date: Date) async throws {
        try await write { try await base.markSent(id, systemFields: systemFields, at: date) }
    }
    func markFailed(_ id: SyncOperationID, error: String, at date: Date) async throws {
        try await write { try await base.markFailed(id, error: error, at: date) }
    }
    func pruneSucceededOperations(olderThan date: Date) async throws -> Int { try await write { try await base.pruneSucceededOperations(olderThan: date) } }
    func currentPayload(entityType: SyncEntityType, entityId: UUID) async throws -> Data? {
        try await base.currentPayload(entityType: entityType, entityId: entityId)
    }
    func entityVersion(entityType: SyncEntityType, entityId: UUID) async throws -> SyncEntityVersion? {
        try await base.entityVersion(entityType: entityType, entityId: entityId)
    }
    func saveSystemFields(_ data: Data?, entityType: SyncEntityType, entityId: UUID, at date: Date) async throws {
        try await write { try await base.saveSystemFields(data, entityType: entityType, entityId: entityId, at: date) }
    }
    func engineState(scope: String) async throws -> Data? { try await base.engineState(scope: scope) }
    func saveEngineState(_ data: Data, scope: String, at date: Date) async throws {
        try await write { try await base.saveEngineState(data, scope: scope, at: date) }
    }
    func applyRemoteChanges(_ changes: [RemoteChange], engineState: (scope: String, data: Data)?, at date: Date) async throws -> [RemoteApplyOutcome] {
        try await write { try await base.applyRemoteChanges(changes, engineState: engineState, at: date) }
    }
    func hasAppliedOperation(_ id: SyncOperationID) async throws -> Bool { try await base.hasAppliedOperation(id) }
    func tombstone(entityType: SyncEntityType, entityId: UUID) async throws -> SyncTombstone? {
        try await base.tombstone(entityType: entityType, entityId: entityId)
    }
    func openConflicts() async throws -> [SyncConflict] { try await base.openConflicts() }
    func conflict(_ id: UUID) async throws -> SyncConflict? { try await base.conflict(id) }
    func resolveConflict(_ id: UUID, resolution: ConflictResolution, at date: Date) async throws {
        try await write { try await base.resolveConflict(id, resolution: resolution, at: date) }
    }
}

final class StoreBox: Sendable {
    private let store = Mutex<CrashingSyncStore?>(nil)
    var value: CrashingSyncStore? { store.withLock { $0 } }
    func set(_ value: CrashingSyncStore) { store.withLock { $0 = value } }
}

@Suite("Sync hardening")
struct SyncHardeningTests {
    let server = FakeCloudDatabase()
    let clock = TestClock()

    static let threeLines = "Zeile 1\nZeile 2\nZeile 3"

    func devices() async throws -> (mac: SimulatedDevice, phone: SimulatedDevice) {
        let mac = try await SimulatedDevice.make("mac", role: .executionHost(Fixture.host), server: server, clock: clock)
        let phone = try await SimulatedDevice.make("phone", role: .mobile, server: server, clock: clock)
        return (mac, phone)
    }

    /// Project from the Mac and a work item from the phone, known on both devices.
    func sharedItem(_ mac: SimulatedDevice, _ phone: SimulatedDevice) async throws -> (Project, WorkItem) {
        let (project, settings) = Fixture.project()
        try await mac.database.projects.create(project, settings: settings, at: t0)
        try await mac.sync(.appLaunch)
        try await phone.sync(.appLaunch)
        let item = Fixture.workItem(projectId: project.id, body: Self.threeLines)
        try await phone.database.workItems.insert(item, actor: phone.actor, at: t0)
        try await phone.sync(.localChange)
        try await mac.sync(.poll)
        #expect(try await mac.database.workItems.fetch(item.uuid) == item)
        return (project, item)
    }

    func expectedRecordNames(_ device: SimulatedDevice, _ project: Project, _ item: WorkItem) async throws -> Set<String> {
        var names: Set<String> = [
            SyncRecordSchema.recordName(.project, project.id.rawValue),
            SyncRecordSchema.recordName(.projectSettings, project.settingsId.rawValue),
            SyncRecordSchema.recordName(.workItem, item.uuid.rawValue),
        ]
        for event in try await device.database.events.events(forWorkItem: item.uuid) {
            names.insert(SyncRecordSchema.recordName(.taskEvent, event.eventId.rawValue))
        }
        return names
    }

    // MARK: Gap 4: 3-way merge in the coordinator

    @Test("Non-overlapping concurrent edits merge automatically on fetch, recorded in the history")
    func cleanMergeOnFetch() async throws {
        let (mac, phone) = try await devices()
        let (_, item) = try await sharedItem(mac, phone)

        mac.connection.isOnline = false
        _ = try await mac.database.workItems.update(item.uuid, expectedRevision: item.revision, actor: mac.actor, at: t0.addingTimeInterval(10)) {
            $0.structuredBody = "Zeile 1 (Mac)\nZeile 2\nZeile 3"
        }
        _ = try await phone.database.workItems.update(item.uuid, expectedRevision: item.revision, actor: phone.actor, at: t0.addingTimeInterval(11)) {
            $0.structuredBody = "Zeile 1\nZeile 2\nZeile 3 (iPhone)"
        }
        try await phone.sync(.foreground)

        mac.connection.isOnline = true
        let report = try await mac.sync(.poll)
        #expect(report.conflicts == 1)
        #expect(report.mergedAutomatically == 1)
        let merged = try #require(try await mac.database.workItems.fetch(item.uuid))
        #expect(merged.structuredBody == "Zeile 1 (Mac)\nZeile 2\nZeile 3 (iPhone)")
        #expect(merged.revision == 3)
        #expect(merged.updatedAt == t0.addingTimeInterval(11))
        #expect(try await mac.database.sync.openConflicts().isEmpty)
        #expect(await mac.status().openConflictCount == 0)

        // Transparent: resolution recorded with its origin, and visible in the task history.
        let resolved = try #require(try await mac.database.sync.resolvedConflicts(limit: 10).first)
        #expect(resolved.resolvedBy == .automaticMerge)
        #expect(resolved.resolution == "merged")
        #expect(resolved.ancestorPayload != nil)
        let events = try await mac.database.events.events(forWorkItem: item.uuid)
        #expect(events.contains { $0.kind == .conflictDetected })
        let mergeEvent = try #require(events.last { $0.kind == .edited && $0.payload["resolvedBy"] != nil })
        #expect(mergeEvent.payload["resolvedBy"] == "automaticMerge")
        #expect(mergeEvent.payload["conflictId"] == resolved.id.uuidString)

        // Both devices converge on the merged text, including the history entry.
        let phoneRun = try await phone.sync(.pullToRefresh)
        #expect(phoneRun.conflicts == 0)
        #expect(try await phone.database.workItems.fetch(item.uuid) == merged)
        #expect(try await phone.database.events.events(forWorkItem: item.uuid).contains { $0.eventId == mergeEvent.eventId })
        #expect(await mac.status().pendingCount == 0)
    }

    @Test("Non-overlapping edits merge on serverRecordChanged as well")
    func cleanMergeOnSend() async throws {
        let (mac, phone) = try await devices()
        let (_, item) = try await sharedItem(mac, phone)

        _ = try await phone.database.workItems.update(item.uuid, expectedRevision: item.revision, actor: phone.actor, at: t0.addingTimeInterval(10)) {
            $0.title = "Vom iPhone"
        }
        try await phone.sync(.localChange)
        _ = try await mac.database.workItems.update(item.uuid, expectedRevision: item.revision, actor: mac.actor, at: t0.addingTimeInterval(11)) {
            $0.structuredBody = "Zeile 1\nZeile 2\nZeile 3 (Mac)"
        }
        // Send without fetching first: CloudKit returns the phone's record.
        let report = try #require(await mac.coordinator.sendChanges().report)
        #expect(report.conflicts == 1)
        #expect(report.mergedAutomatically == 1)
        let merged = try #require(try await mac.database.workItems.fetch(item.uuid))
        #expect(merged.title == "Vom iPhone")
        #expect(merged.structuredBody == "Zeile 1\nZeile 2\nZeile 3 (Mac)")
        let serverRecord = try #require(await server.record(SyncRecordSchema.recordID(.workItem, item.uuid.rawValue)))
        #expect(try decode(WorkItem.self, try SyncRecordMapper(deviceId: DeviceID()).decode(serverRecord).change.payload) == merged)
        #expect(try await mac.database.sync.openConflicts().isEmpty)
        try await phone.sync(.foreground)
        #expect(try await phone.database.workItems.fetch(item.uuid) == merged)
    }

    @Test("Overlapping edits stay a conflict for the user, with the ancestor attached")
    func overlappingEditsStayAConflict() async throws {
        let (mac, phone) = try await devices()
        let (_, item) = try await sharedItem(mac, phone)

        mac.connection.isOnline = false
        let macVersion = try await mac.database.workItems.update(item.uuid, expectedRevision: item.revision, actor: mac.actor, at: t0.addingTimeInterval(10)) {
            $0.structuredBody = "Zeile 1\nZeile 2 vom Mac\nZeile 3"
        }
        _ = try await phone.database.workItems.update(item.uuid, expectedRevision: item.revision, actor: phone.actor, at: t0.addingTimeInterval(11)) {
            $0.structuredBody = "Zeile 1\nZeile 2 vom iPhone\nZeile 3"
        }
        try await phone.sync(.foreground)
        mac.connection.isOnline = true
        let report = try await mac.sync(.poll)
        #expect(report.conflicts == 1)
        #expect(report.mergedAutomatically == 0)
        #expect(try await mac.database.workItems.fetch(item.uuid) == macVersion)
        let conflict = try #require(try await mac.database.sync.openConflicts().first)
        #expect(try decode(WorkItem.self, conflict.ancestorPayload).structuredBody == Self.threeLines)
        #expect(await mac.status().attention.contains(.openConflicts(1)))
        #expect(try await mac.database.sync.resolvedConflicts(limit: 10).isEmpty)
    }

    // MARK: Gap 2: crash between send and acknowledgement

    @Test("Crash after the records reached CloudKit, before the ack: restart resends idempotently")
    func crashBetweenSendAndAck() async throws {
        let boxed = StoreBox()
        let phone = try await SimulatedDevice.make("phone", role: .mobile, server: server, clock: clock, wrapStore: { base in
            let store = CrashingSyncStore(base)
            boxed.set(store)
            return store
        })
        let mac = try await SimulatedDevice.make("mac", role: .executionHost(Fixture.host), server: server, clock: clock)
        let item = Fixture.workItem(projectId: nil, title: "Vor dem Absturz")
        try await phone.database.workItems.insert(item, actor: phone.actor, at: t0)

        _ = await phone.coordinator.syncNow(reason: .localChange)
        #expect(boxed.value?.hasCrashed == true)
        // The server has both records; locally they are still unacknowledged and marked in flight.
        #expect(await server.recordNames(in: SyncRecordSchema.zoneID).count == 2)
        #expect(try await phone.database.sync.pendingOperations(limit: 10).isEmpty)
        #expect(try await phone.database.sync.unsentOperationCount() == 2)

        // Restart with the real store: in-flight entries are reset and resent; the server recognizes
        // its own operation IDs, so nothing is duplicated.
        let restarted = SyncCoordinator(store: phone.database.sync, configuration: phone.coordinator.configuration,
                                        now: { clock.now }, engineFactory: FakeSyncEngine.factory(server: server, connection: phone.connection))
        try await restarted.start()
        #expect(try await phone.database.sync.pendingOperations(limit: 10).count == 2)
        let retry = try #require(await restarted.syncNow(reason: .appLaunch).report)
        #expect(retry.conflicts == 0)
        #expect(retry.mergedOnServerChange == 2)
        #expect(try await phone.database.sync.unsentOperationCount() == 0)
        #expect(await restarted.status.pendingCount == 0)
        #expect(await server.recordNames(in: SyncRecordSchema.zoneID).count == 2)

        let fetched = try await mac.sync(.poll)
        #expect(fetched.applied == 2)
        #expect(fetched.conflicts == 0)
        #expect(try await mac.database.workItems.fetch(item.uuid) == item)
        #expect(try await mac.database.events.events(forWorkItem: item.uuid).count == 1)
    }

    // MARK: Gap 3: paging

    @Test("A backlog of more than 500 outbox entries drains in one run within CloudKit batch limits")
    func largeBacklogDrainsInOneRun() async throws {
        let phone = try await SimulatedDevice.make("phone", role: .mobile, server: server, clock: clock, outboxScanLimit: 100)
        let mac = try await SimulatedDevice.make("mac", role: .executionHost(Fixture.host), server: server, clock: clock)
        for index in 0..<300 {
            try await phone.database.workItems.insert(Fixture.workItem(projectId: nil, title: "Aufgabe \(index)"),
                                                      actor: phone.actor, at: t0.addingTimeInterval(Double(index)))
        }
        #expect(try await phone.database.sync.unsentOperationCount() == 600)
        let report = try await phone.sync(.localChange)
        #expect(report.sent == 600)
        #expect(await phone.status().pendingCount == 0)
        let sizes = await server.modifyBatchSizes
        #expect(sizes.allSatisfy { $0 <= SyncRecordSchema.maxRecordsPerBatch })
        #expect(sizes.count == 3)
        let fetched = try await mac.sync(.poll)
        #expect(fetched.applied == 600)
    }

    // MARK: Gap 1: full re-upload

    @Test("Zone deleted, purged or encrypted data reset: on the user's decision everything is uploaded again",
          arguments: [ZoneDeletionReason.purged, .deleted, .encryptedDataReset])
    func zoneLossReuploadsEverything(reason: ZoneDeletionReason) async throws {
        let (mac, phone) = try await devices()
        let (project, item) = try await sharedItem(mac, phone)
        let expected = try await expectedRecordNames(phone, project, item)
        await server.deleteZone(SyncRecordSchema.zoneID, reason: reason)

        #expect(await phone.coordinator.syncNow(reason: .foreground) == .paused(.zoneDeleted))
        #expect(await phone.status().attention.contains(.zoneDeleted(reason)))
        #expect(await phone.status().pendingCount == 0)

        await phone.coordinator.recreateZoneAndResume()
        #expect(await phone.status().pendingCount == expected.count)
        let upload = try await phone.sync(.manual)
        #expect(upload.sent == expected.count)
        #expect(Set(await server.recordNames(in: SyncRecordSchema.zoneID)) == expected)
        #expect(await phone.status().attention.isEmpty)

        // The Mac learns about the loss as well, decides the same, and converges without conflicts.
        #expect(await mac.coordinator.syncNow(reason: .poll) == .paused(.zoneDeleted))
        await mac.coordinator.recreateZoneAndResume()
        let macRun = try await mac.sync(.manual)
        #expect(macRun.conflicts == 0)
        #expect(try await mac.database.sync.openConflicts().isEmpty)
        #expect(await mac.status().pendingCount == 0)
        let phoneRun = try await phone.sync(.foreground)
        #expect(phoneRun.conflicts == 0)
        #expect(try await phone.database.workItems.fetch(item.uuid) == item)
        #expect(try await mac.database.workItems.fetch(item.uuid) == item)
        #expect(Set(await server.recordNames(in: SyncRecordSchema.zoneID)) == expected)
    }

    @Test("zoneNotFound while sending: paused; on the user's decision all local data is uploaded, not only the change")
    func zoneNotFoundReuploadsEverything() async throws {
        let (mac, phone) = try await devices()
        let (project, item) = try await sharedItem(mac, phone)
        let expected = try await expectedRecordNames(mac, project, item)
        await server.deleteZone(SyncRecordSchema.zoneID, reason: .deleted)

        var renamed = try #require(try await mac.database.projects.fetch(project.id))
        renamed.name = "Umbenannt"
        _ = try await mac.database.projects.update(renamed, expectedRevision: renamed.revision, at: t0.addingTimeInterval(5))
        #expect(await mac.coordinator.sendChanges() == .paused(.zoneDeleted))
        #expect(await server.recordNames(in: SyncRecordSchema.zoneID).isEmpty)

        await mac.coordinator.recreateZoneAndResume()
        let report = try #require(await mac.coordinator.sendChanges().report)
        #expect(report.sent == expected.count)
        #expect(Set(await server.recordNames(in: SyncRecordSchema.zoneID)) == expected)
        #expect(await mac.status().pendingCount == 0)
        // A fresh device restores everything from the recreated zone.
        let fresh = try await SimulatedDevice.make("fresh", role: .mobile, server: server, clock: clock)
        try await fresh.sync(.appLaunch)
        #expect(try await fresh.database.workItems.fetch(item.uuid) == item)
        #expect(try await fresh.database.projects.fetch(project.id)?.name == "Umbenannt")
    }

    @Test("Account switch confirmed with 'upload again': all local data goes to the new account")
    func accountSwitchUploadsAllLocalData() async throws {
        let serverB = FakeCloudDatabase()
        let serverA = server
        let mac = try await SimulatedDevice.make("mac", role: .executionHost(Fixture.host), server: server, clock: clock)
        let phone = try await SimulatedDevice.make("phone", role: .mobile, server: server, clock: clock,
                                                   serverForUser: { $0 == "_user-B" ? serverB : serverA })
        let (project, item) = try await sharedItem(mac, phone)
        let expected = try await expectedRecordNames(phone, project, item)

        phone.connection.userRecordName = "_user-B"
        #expect(await phone.coordinator.syncNow(reason: .foreground) == .paused(.accountSwitched))
        try await phone.coordinator.acknowledgeAccountChange(uploadAllLocalData: true)
        let report = try await phone.sync(.manual)
        #expect(report.sent == expected.count)
        #expect(Set(await serverB.recordNames(in: SyncRecordSchema.zoneID)) == expected)
        #expect(await phone.status().accountState == .available)
        #expect(await phone.status().pendingCount == 0)
        // Old account untouched.
        #expect(Set(await serverA.recordNames(in: SyncRecordSchema.zoneID)) == expected)
    }

    // MARK: Gap 6

    @Test("System fields are never stored for entities that do not sync")
    func noSyncStateForDeviceLocalEntities() async throws {
        let phone = try await SimulatedDevice.make("phone", role: .mobile, server: server, clock: clock)
        let note = AudioNote(localAssetRef: "n.m4a", provider: .appleOnDevice, consent: .notRequired, createdAt: t0)
        try await phone.database.aiRecords.saveAudioNote(note, at: t0)
        try await phone.database.sync.saveSystemFields(Data([1]), entityType: .audioNote, entityId: note.id.rawValue, at: t0)
        #expect(try await phone.database.sync.entityVersion(entityType: .audioNote, entityId: note.id.rawValue) == nil)
        let report = try await phone.sync(.manual)
        #expect(report.sent == 0)
        #expect(await server.recordNames(in: SyncRecordSchema.zoneID).isEmpty)
    }
}

// MARK: - Error texts

@Suite("Sync error texts")
struct SyncErrorTextTests {
    private func partial(_ itemErrors: [CKError.Code], retryAfter: Double? = nil) -> CKError {
        var byItem: [CKRecord.ID: any Error] = [:]
        for (index, code) in itemErrors.enumerated() {
            var info: [String: Any] = [:]
            if let retryAfter { info[CKErrorRetryAfterKey] = retryAfter }
            byItem[CKRecord.ID(recordName: "WorkItem.\(index)")] = CKError(code, userInfo: info)
        }
        return CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: byItem])
    }

    @Test func partialFailureShowsTheCauseInsteadOfCode2() {
        // Production schema missing (TestFlight): every save is rejected, the rest of the batch follows.
        let message = SyncErrorText.message(for: partial([.batchRequestFailed, .serverRejectedRequest, .batchRequestFailed]))
        #expect(message == SyncErrorText.message(for: CKError(.serverRejectedRequest)))
        #expect(message.contains("Datenschema"))
        #expect(!message.contains("Code 2"))
    }

    @Test func partialFailureUsesKnownTextAndRetryHintOfTheItemError() {
        let message = SyncErrorText.message(for: partial([.zoneBusy], retryAfter: 30))
        #expect(message.hasPrefix(SyncErrorText.message(for: CKError(.zoneBusy))))
        #expect(message.contains("30 Sekunden"))
    }

    @Test func primaryErrorIsDeterministicAndFallsBackToBatchFailures() {
        #expect(SyncErrorText.primaryError(of: partial([.quotaExceeded, .serverRejectedRequest]))?.code == .serverRejectedRequest)
        #expect(SyncErrorText.primaryError(of: partial([.batchRequestFailed]))?.code == .batchRequestFailed)
        // Without per-item errors the generic text with the code stays.
        #expect(SyncErrorText.primaryError(of: CKError(.partialFailure)) == nil)
        #expect(SyncErrorText.message(for: CKError(.partialFailure)).contains("Code 2"))
    }
}
