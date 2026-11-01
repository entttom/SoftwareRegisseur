import CloudKit
import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence
@testable import SoftwareRegisseurSync
import SoftwareRegisseurSyncTesting
import Testing

extension SimulatedDevice {
    /// Same database and device ID with a new coordinator (app relaunch).
    func restarted(server: FakeCloudDatabase, clock: TestClock) async throws -> SimulatedDevice {
        let box = EngineBox()
        let connection = self.connection
        let coordinator = SyncCoordinator(
            store: database.sync,
            configuration: SyncConfiguration(
                deviceId: deviceId, role: coordinator.configuration.role,
                assetDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("SyncTests-\(name)-\(UUID().uuidString)")
            ),
            now: { clock.now },
            engineFactory: { setup in
                let engine = try FakeSyncEngine(setup: setup, server: server, connection: connection)
                box.set(engine)
                return engine
            }
        )
        try await coordinator.start()
        return SimulatedDevice(name: name, deviceId: deviceId, database: database, connection: connection,
                               coordinator: coordinator, engine: box)
    }
}

/// „iCloud-Daten löschen“ (spec Q1, A34): zone deletion through the coordinator, then no silent re-upload.
@Suite("Cloud data deletion")
struct CloudDataDeletionTests {
    let server = FakeCloudDatabase()
    let clock = TestClock()

    func devices() async throws -> (mac: SimulatedDevice, phone: SimulatedDevice) {
        let mac = try await SimulatedDevice.make("mac", role: .executionHost(Fixture.host), server: server, clock: clock)
        let phone = try await SimulatedDevice.make("phone", role: .mobile, server: server, clock: clock)
        return (mac, phone)
    }

    func request(zoneName: String = SyncRecordSchema.zoneName) -> CloudDataDeletionRequest {
        CloudDataDeletionRequest(id: UUID(), zoneName: zoneName, scope: .entireZone, requestedAt: t0, suppressAutomaticReupload: true)
    }

    /// Project from the Mac and a work item from the phone, known on both devices.
    func sharedItem(_ mac: SimulatedDevice, _ phone: SimulatedDevice) async throws -> (Project, WorkItem) {
        let (project, settings) = Fixture.project()
        try await mac.database.projects.create(project, settings: settings, at: t0)
        try await mac.sync(.appLaunch)
        try await phone.sync(.appLaunch)
        let item = Fixture.workItem(projectId: project.id)
        try await phone.database.workItems.insert(item, actor: phone.actor, at: t0)
        try await phone.sync(.localChange)
        try await mac.sync(.poll)
        #expect(try await mac.database.workItems.fetch(item.uuid) == item)
        return (project, item)
    }

    @Test func zoneNameIsTheSharedConstant() {
        // `LocalDataEraser.cloudZoneName` (Portability) reads the same constant; its tests check that side.
        #expect(SyncRecordSchema.zoneName == CloudSyncZone.name)
        #expect(SyncConfiguration(deviceId: DeviceID(), role: .mobile).zoneID.zoneName == CloudSyncZone.name)
    }

    @Test("Deleting the iCloud data removes the zone, pauses sync and never re-uploads on its own")
    func deletionPausesAndNeverReuploadsAutomatically() async throws {
        let (mac, phone) = try await devices()
        let (project, item) = try await sharedItem(mac, phone)
        #expect(await server.hasZone(SyncRecordSchema.zoneID))

        try await phone.coordinator.deleteCloudData(request())
        #expect(await !server.hasZone(SyncRecordSchema.zoneID))
        #expect(await server.zoneDeletionRequests == 1)
        var status = await phone.status()
        #expect(status.attention == [.cloudDataDeletedByUser])
        #expect(status.isPaused)
        #expect(status.isCloudDataDeletedByUser)
        #expect(await phone.coordinator.isCloudDataDeletedByUser)
        // Local data is untouched.
        #expect(try await phone.database.workItems.fetch(item.uuid) == item)
        #expect(try await phone.database.projects.fetch(project.id) != nil)

        // Every trigger stays paused, also with new local changes; nothing re-creates the zone.
        _ = try await phone.database.workItems.update(item.uuid, expectedRevision: item.revision, actor: phone.actor, at: t0.addingTimeInterval(20)) {
            $0.title = "Nach dem Löschen"
        }
        for reason in SyncReason.allCases {
            #expect(await phone.coordinator.syncNow(reason: reason) == .paused(.zoneDeleted))
        }
        #expect(await phone.coordinator.sendChanges() == .paused(.zoneDeleted))
        #expect(await !server.hasZone(SyncRecordSchema.zoneID))
        status = await phone.status()
        #expect(status.pendingCount >= 1) // the edit is kept for later

        // Persistent: an app relaunch keeps the pause.
        let relaunched = try await phone.restarted(server: server, clock: clock)
        #expect(await relaunched.status().attention == [.cloudDataDeletedByUser])
        #expect(await relaunched.coordinator.syncNow(reason: .appLaunch) == .paused(.zoneDeleted))
        #expect(await !server.hasZone(SyncRecordSchema.zoneID))

        // Only the explicit „Wieder mit iCloud synchronisieren“ uploads everything again.
        await relaunched.coordinator.recreateZoneAndResume()
        let upload = try await relaunched.sync(.manual)
        #expect(upload.sent >= 3)
        #expect(await server.hasZone(SyncRecordSchema.zoneID))
        let names = await server.recordNames(in: SyncRecordSchema.zoneID)
        #expect(names.contains(SyncRecordSchema.recordName(.workItem, item.uuid.rawValue)))
        #expect(names.contains(SyncRecordSchema.recordName(.project, project.id.rawValue)))
        #expect(await relaunched.status().attention.isEmpty)
        #expect(await relaunched.status().pendingCount == 0)
        // The change token was reset with the engine: the own deletion is not reported again.
        #expect(try await relaunched.sync(.foreground).conflicts == 0)
        #expect(await relaunched.status().attention.isEmpty)
    }

    @Test("A second device sees the zone deletion and does not re-upload automatically")
    func secondDeviceDoesNotReuploadAutomatically() async throws {
        let (mac, phone) = try await devices()
        let (project, item) = try await sharedItem(mac, phone)

        // The Mac has an unsent change when the phone deletes the iCloud data.
        var renamed = try #require(try await mac.database.projects.fetch(project.id))
        renamed.name = "Auf dem Mac geändert"
        _ = try await mac.database.projects.update(renamed, expectedRevision: renamed.revision, at: t0.addingTimeInterval(5))
        try await phone.coordinator.deleteCloudData(request())
        #expect(await !server.hasZone(SyncRecordSchema.zoneID))

        // Send without a fetch first (race): zoneNotFound for a known zone pauses instead of re-creating.
        #expect(await mac.coordinator.sendChanges() == .paused(.zoneDeleted))
        #expect(await !server.hasZone(SyncRecordSchema.zoneID))
        // Polling: the fetch reports the deletion; still paused, still no zone.
        #expect(await mac.coordinator.syncNow(reason: .poll) == .paused(.zoneDeleted))
        #expect(await mac.coordinator.syncNow(reason: .manual) == .paused(.zoneDeleted))
        #expect(await !server.hasZone(SyncRecordSchema.zoneID))
        let macStatus = await mac.status()
        #expect(macStatus.attention.contains(.zoneDeleted(.deleted)))
        #expect(macStatus.isPaused)
        #expect(macStatus.pendingCount >= 1)
        // Local data on the Mac is kept.
        #expect(try await mac.database.projects.fetch(project.id)?.name == "Auf dem Mac geändert")
        #expect(try await mac.database.workItems.fetch(item.uuid) == item)

        // A fresh third device sees no data, and its own first sync creates an empty zone only.
        let fresh = try await SimulatedDevice.make("fresh", role: .mobile, server: server, clock: clock)
        try await fresh.sync(.appLaunch)
        #expect(try await fresh.database.workItems.fetch(item.uuid) == nil)
        #expect(await server.recordNames(in: SyncRecordSchema.zoneID).isEmpty)

        // The Mac's user decides to upload again: then (and only then) its data goes up.
        await mac.coordinator.recreateZoneAndResume()
        try await mac.sync(.manual)
        #expect(await server.recordNames(in: SyncRecordSchema.zoneID).contains(SyncRecordSchema.recordName(.project, project.id.rawValue)))
        // The deleting phone stays paused regardless.
        #expect(await phone.coordinator.syncNow(reason: .foreground) == .paused(.zoneDeleted))
    }

    @Test("Offline deletion stays pending and paused, nothing is uploaded; a retry completes it")
    func offlineDeletionIsPendingAndRetried() async throws {
        let (mac, phone) = try await devices()
        let (_, item) = try await sharedItem(mac, phone)
        let recordsBefore = await server.recordNames(in: SyncRecordSchema.zoneID)
        phone.connection.isOnline = false

        let deletion = request()
        do {
            try await phone.coordinator.deleteCloudData(deletion)
            Issue.record("offline deletion must not report success")
        } catch let error as CloudDataDeletionError {
            guard case let .failed(failure) = error else { Issue.record("unexpected \(error)"); return }
            #expect(failure.code == .networkUnavailable)
            #expect(error.userMessage.contains("Synchronisierung bleibt pausiert"))
        }
        #expect(await server.hasZone(SyncRecordSchema.zoneID))
        #expect(await phone.status().attention == [.cloudDataDeletionPending])
        #expect(await phone.status().isCloudDataDeletedByUser)

        // Back online: a normal sync does not upload anything (and does not delete either).
        phone.connection.isOnline = true
        _ = try await phone.database.workItems.update(item.uuid, expectedRevision: item.revision, actor: phone.actor, at: t0.addingTimeInterval(9)) {
            $0.title = "Lokal"
        }
        #expect(await phone.coordinator.syncNow(reason: .foreground) == .paused(.zoneDeleted))
        #expect(await server.recordNames(in: SyncRecordSchema.zoneID) == recordsBefore)

        // Pending state survives a relaunch; the retry deletes the zone.
        let relaunched = try await phone.restarted(server: server, clock: clock)
        #expect(await relaunched.status().attention == [.cloudDataDeletionPending])
        try await relaunched.coordinator.retryCloudDataDeletion()
        #expect(await !server.hasZone(SyncRecordSchema.zoneID))
        #expect(await relaunched.status().attention == [.cloudDataDeletedByUser])
        // Repeating the completed request is a no-op.
        try await relaunched.coordinator.deleteCloudData(deletion)
        #expect(await server.zoneDeletionRequests == 1)
    }

    @Test("A request for another zone or without a started coordinator deletes nothing")
    func invalidRequestsAreRefused() async throws {
        let (mac, phone) = try await devices()
        _ = try await sharedItem(mac, phone)
        await #expect(throws: CloudDataDeletionError.zoneMismatch(expected: SyncRecordSchema.zoneName, requested: "Fremd")) {
            try await phone.coordinator.deleteCloudData(request(zoneName: "Fremd"))
        }
        #expect(await server.hasZone(SyncRecordSchema.zoneID))
        #expect(await phone.status().attention.isEmpty)

        let unstarted = SyncCoordinator(
            store: phone.database.sync, configuration: SyncConfiguration(deviceId: phone.deviceId, role: .mobile),
            engineFactory: FakeSyncEngine.factory(server: server, connection: phone.connection)
        )
        await #expect(throws: CloudDataDeletionError.notStarted) { try await unstarted.deleteCloudData(request()) }
        #expect(await server.hasZone(SyncRecordSchema.zoneID))
        #expect(CloudDataDeletionError.notStarted.userMessage.contains("nicht aktiv"))
    }

    @Test("A zone that is already gone counts as deleted")
    func alreadyMissingZoneCompletes() async throws {
        let (mac, phone) = try await devices()
        _ = try await sharedItem(mac, phone)
        await server.deleteZone(SyncRecordSchema.zoneID, reason: .purged)
        try await phone.coordinator.deleteCloudData(request())
        #expect(await phone.status().attention == [.cloudDataDeletedByUser])
        #expect(await !server.hasZone(SyncRecordSchema.zoneID))
    }
}
