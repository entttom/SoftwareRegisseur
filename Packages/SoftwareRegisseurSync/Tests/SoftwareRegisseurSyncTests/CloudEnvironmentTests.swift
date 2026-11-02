import CloudKit
import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence
@testable import SoftwareRegisseurSync
import SoftwareRegisseurSyncTesting
import Testing

/// ADR-0027: engine state and server change tags belong to one CloudKit environment. A build talking to
/// another environment on the same local database (Xcode Debug → Development, release → Production before
/// ADR-0027) must upload everything again instead of considering it sent.
@Suite("CloudKit environment switch")
struct CloudEnvironmentTests {
    let development = FakeCloudDatabase()
    let production = FakeCloudDatabase()
    let clock = TestClock()

    /// The device's coordinator restarted on the same database, now talking to `server` in `environment`.
    func restart(_ device: SimulatedDevice, environment: String?, server: FakeCloudDatabase) async throws -> SyncCoordinator {
        var configuration = device.coordinator.configuration
        configuration.cloudEnvironment = environment
        let coordinator = SyncCoordinator(store: device.database.sync, configuration: configuration, now: { clock.now },
                                          engineFactory: FakeSyncEngine.factory(server: server, connection: device.connection))
        try await coordinator.start()
        return coordinator
    }

    /// Mac data synced to Development: project, settings, a work item and its events.
    func macSyncedToDevelopment() async throws -> (mac: SimulatedDevice, expected: Set<String>, item: WorkItem) {
        let mac = try await SimulatedDevice.make("mac", role: .executionHost(Fixture.host), server: development, clock: clock)
        let (project, settings) = Fixture.project()
        try await mac.database.projects.create(project, settings: settings, at: t0)
        let item = Fixture.workItem(projectId: project.id)
        try await mac.database.workItems.insert(item, actor: mac.actor, at: t0)
        try await mac.sync(.appLaunch)
        var expected: Set<String> = [
            SyncRecordSchema.recordName(.project, project.id.rawValue),
            SyncRecordSchema.recordName(.projectSettings, project.settingsId.rawValue),
            SyncRecordSchema.recordName(.workItem, item.uuid.rawValue),
        ]
        for event in try await mac.database.events.events(forWorkItem: item.uuid) {
            expected.insert(SyncRecordSchema.recordName(.taskEvent, event.eventId.rawValue))
        }
        #expect(Set(await development.recordNames(in: SyncRecordSchema.zoneID)) == expected)
        #expect(await mac.status().pendingCount == 0)
        return (mac, expected, item)
    }

    @Test("State from before ADR-0027 (environment unknown): everything is uploaded to Production")
    func unknownEnvironmentUploadsEverything() async throws {
        let (mac, expected, item) = try await macSyncedToDevelopment()
        let restarted = try await restart(mac, environment: "Production", server: production)
        let report = try #require(await restarted.syncNow(reason: .appLaunch).report)
        #expect(report.sent == expected.count)
        #expect(Set(await production.recordNames(in: SyncRecordSchema.zoneID)) == expected)
        #expect(await restarted.status.pendingCount == 0)
        // Local data untouched, Development copy untouched.
        #expect(try await mac.database.workItems.fetch(item.uuid) == item)
        #expect(Set(await development.recordNames(in: SyncRecordSchema.zoneID)) == expected)

        // A device that only knows Production now receives the Mac's data.
        let phone = try await SimulatedDevice.make("phone", role: .mobile, server: production, clock: clock)
        try await phone.sync(.appLaunch)
        #expect(try await phone.database.workItems.fetch(item.uuid) == item)
    }

    @Test("Explicit Development → Production switch uploads everything; the same environment later does not")
    func switchUploadsOnceThenStaysStable() async throws {
        let (mac, expected, _) = try await macSyncedToDevelopment()
        // Unknown → Development counts as a switch too (one re-upload that converges with the server copy) …
        let adopted = try await restart(mac, environment: "Development", server: development)
        _ = try #require(await adopted.syncNow(reason: .appLaunch).report)
        // … after that, Development is stable.
        let marked = try await restart(mac, environment: "Development", server: development)
        let unchanged = try #require(await marked.syncNow(reason: .appLaunch).report)
        #expect(unchanged.requeuedForUpload == 0)
        #expect(unchanged.sent == 0)
        #expect(Set(await development.recordNames(in: SyncRecordSchema.zoneID)) == expected)

        let switched = try await restart(mac, environment: "Production", server: production)
        let report = try #require(await switched.syncNow(reason: .appLaunch).report)
        #expect(report.sent == expected.count)
        #expect(report.requeuedForUpload == expected.count)

        let again = try await restart(mac, environment: "Production", server: production)
        let later = try #require(await again.syncNow(reason: .poll).report)
        #expect(later.requeuedForUpload == 0)
        #expect(later.sent == 0)
        #expect(Set(await production.recordNames(in: SyncRecordSchema.zoneID)) == expected)
    }

    @Test("Never synced: only the environment is recorded, no full upload")
    func neverSyncedOnlyRecordsEnvironment() async throws {
        let phone = try await SimulatedDevice.make("phone", role: .mobile, server: production, clock: clock)
        let (project, settings) = Fixture.project()
        try await phone.database.projects.create(project, settings: settings, at: t0)
        let restarted = try await restart(phone, environment: "Production", server: production)
        let report = try #require(await restarted.syncNow(reason: .appLaunch).report)
        #expect(report.requeuedForUpload == 0)
        #expect(report.sent == 2)
    }

    @Test("The other environment's user record name does not pause sync as an account switch")
    func otherEnvironmentUserIsNoAccountSwitch() async throws {
        let (mac, expected, _) = try await macSyncedToDevelopment()
        // CloudKit user record names may differ between environments of the same container.
        mac.connection.userRecordName = "_user-A-production"
        let restarted = try await restart(mac, environment: "Production", server: production)
        let result = await restarted.syncNow(reason: .appLaunch)
        #expect(result.report?.sent == expected.count)
        #expect(await restarted.status.accountState == .available)
        #expect(!(await restarted.status.isPaused))
    }

    @Test("A user's deletion of the iCloud data stays in force across an environment switch (A34)")
    func cloudDeletionSurvivesSwitch() async throws {
        let (mac, _, _) = try await macSyncedToDevelopment()
        let request = CloudDataDeletionRequest(id: UUID(), zoneName: SyncRecordSchema.zoneName, scope: .entireZone,
                                               requestedAt: t0, suppressAutomaticReupload: true)
        try await mac.coordinator.deleteCloudData(request)
        let restarted = try await restart(mac, environment: "Production", server: production)
        #expect(await restarted.syncNow(reason: .appLaunch) == .paused(.zoneDeleted))
        #expect(await production.recordNames(in: SyncRecordSchema.zoneID).isEmpty)
    }
}
