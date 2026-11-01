import CloudKit
import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence
@testable import SoftwareRegisseurSync
import SoftwareRegisseurSyncTesting
import Testing

/// iPhone and Mac, each with its own in-memory database, synchronising through `FakeCloudDatabase`
/// with the same `SyncCoordinator` logic that drives `CKSyncEngine` in the apps.
@Suite("Two-device sync")
struct TwoDeviceSyncTests {
    let server = FakeCloudDatabase()
    let clock = TestClock()

    func devices() async throws -> (mac: SimulatedDevice, phone: SimulatedDevice) {
        let mac = try await SimulatedDevice.make("mac", role: .executionHost(Fixture.host), server: server, clock: clock)
        let phone = try await SimulatedDevice.make("phone", role: .mobile, server: server, clock: clock)
        return (mac, phone)
    }

    /// Project created on the Mac and known on both devices.
    func sharedProject(_ mac: SimulatedDevice, _ phone: SimulatedDevice) async throws -> Project {
        let (project, settings) = Fixture.project()
        try await mac.database.projects.create(project, settings: settings, at: t0)
        try await mac.sync(.appLaunch)
        try await phone.sync(.appLaunch)
        #expect(try await phone.database.projects.fetch(project.id) != nil)
        return project
    }

    /// Work item created on the phone and known on both devices.
    func sharedItem(_ mac: SimulatedDevice, _ phone: SimulatedDevice) async throws -> WorkItem {
        let project = try await sharedProject(mac, phone)
        let item = Fixture.workItem(projectId: project.id, body: "Ursprünglicher Text")
        try await phone.database.workItems.insert(item, actor: phone.actor, at: t0)
        try await phone.sync(.localChange)
        try await mac.sync(.poll)
        #expect(try await mac.database.workItems.fetch(item.uuid) == item)
        return item
    }

    // MARK: A10

    @Test("A10: offline iPhone request reaches the Mac exactly once")
    func offlinePhoneRequestReachesMacExactlyOnce() async throws {
        let (mac, phone) = try await devices()
        let project = try await sharedProject(mac, phone)

        // iPhone offline: work item + job request are persisted locally and queued.
        phone.connection.isOnline = false
        let item = Fixture.workItem(projectId: project.id, title: "Idee unterwegs")
        try await phone.database.workItems.insert(item, actor: phone.actor, at: t0)
        let job = Fixture.job(for: item)
        let created = try await phone.database.jobs.create(job, actor: phone.actor, at: t0.addingTimeInterval(1))
        #expect(created.wasCreated)
        let offline = await phone.coordinator.syncNow(reason: .localChange)
        guard case let .failed(failure) = offline else { Issue.record("expected failure, got \(offline)"); return }
        #expect(failure.message.contains("Keine Verbindung zu iCloud"))
        let offlineStatus = await phone.status()
        #expect(offlineStatus.pendingCount >= 2)
        #expect(offlineStatus.lastError?.contains("lokal gespeichert") == true)
        #expect(try await phone.database.workItems.fetch(item.uuid) != nil)

        // Mac is offline as well while the phone comes back and uploads.
        mac.connection.isOnline = false
        phone.connection.isOnline = true
        let upload = try await phone.sync(.foreground)
        #expect(upload.sent >= 2)
        #expect(await phone.status().pendingCount == 0)
        #expect(await phone.status().lastError == nil)

        // Mac comes online and fetches the request exactly once.
        mac.connection.isOnline = true
        let fetched = try await mac.sync(.poll)
        #expect(fetched.duplicates == 0)
        #expect(fetched.conflicts == 0)
        let macJobs = try await mac.database.jobs.jobs(forWorkItem: item.uuid)
        #expect(macJobs.map(\.jobId) == [job.jobId])
        #expect(macJobs.first?.configSnapshot == job.configSnapshot)
        #expect(try await mac.database.workItems.fetch(item.uuid)?.title == "Idee unterwegs")
        let events = try await mac.database.events.events(forWorkItem: item.uuid)

        // Duplicate delivery (state update lost, e.g. crash): replay protection ignores it.
        mac.engine.value!.rewindChangeToken(to: 0)
        let replay = try await mac.sync(.poll)
        #expect(replay.applied == 0)
        #expect(replay.duplicates >= 2)
        #expect(try await mac.database.jobs.jobs(forWorkItem: item.uuid).count == 1)
        #expect(try await mac.database.events.events(forWorkItem: item.uuid) == events)
        // The Mac's own project record came back as echo and was skipped.
        #expect(replay.ownEchoes >= 1)
        #expect(await mac.status().lastSuccessfulFetch == clock.now)
    }

    // MARK: A24

    @Test("A24: concurrent offline edits become a visible conflict without losing text")
    func concurrentEditsCreateConflict() async throws {
        let (mac, phone) = try await devices()
        let item = try await sharedItem(mac, phone)

        mac.connection.isOnline = false
        let macVersion = try await mac.database.workItems.update(item.uuid, expectedRevision: item.revision, actor: mac.actor, at: t0.addingTimeInterval(10)) {
            $0.structuredBody = "Mac-Text"
        }
        let phoneVersion = try await phone.database.workItems.update(item.uuid, expectedRevision: item.revision, actor: phone.actor, at: t0.addingTimeInterval(11)) {
            $0.structuredBody = "iPhone-Text"
        }
        try await phone.sync(.foreground)

        mac.connection.isOnline = true
        let report = try await mac.sync(.poll)
        #expect(report.conflicts == 1)
        // No silent overwrite on the Mac, and the Mac's edit is not pushed over the phone's either.
        #expect(try await mac.database.workItems.fetch(item.uuid) == macVersion)
        let serverRecord = try #require(await server.record(SyncRecordSchema.recordID(.workItem, item.uuid.rawValue)))
        let serverItem = try decode(WorkItem.self, try SyncRecordMapper(deviceId: DeviceID()).decode(serverRecord).change.payload)
        #expect(serverItem.structuredBody == "iPhone-Text")

        let status = await mac.status()
        #expect(status.openConflictCount == 1)
        #expect(status.attention.contains(.openConflicts(1)))
        #expect(status.needsAttention)
        let conflict = try #require(try await mac.database.sync.openConflicts().first)
        #expect(try decode(WorkItem.self, conflict.localPayload).structuredBody == "Mac-Text")
        #expect(try decode(WorkItem.self, conflict.remotePayload).structuredBody == "iPhone-Text")

        // Further syncs keep the entity blocked instead of looping.
        let again = try await mac.sync(.poll)
        #expect(again.sendFailures == 0)

        // The user merges both texts; both devices converge on the merged version.
        var merged = macVersion
        merged.structuredBody = "Mac-Text\n\niPhone-Text"
        merged.touch(at: t0.addingTimeInterval(20))
        try await mac.coordinator.resolveConflict(conflict.id, resolution: .merged(try payload(merged)))
        let resend = try await mac.sync(.manual)
        #expect(resend.sendFailures == 0)
        try await phone.sync(.pullToRefresh)
        #expect(try await phone.database.workItems.fetch(item.uuid)?.structuredBody == "Mac-Text\n\niPhone-Text")
        #expect(try await mac.database.sync.openConflicts().isEmpty)
        _ = phoneVersion
    }

    @Test("serverRecordChanged on send: user content becomes a conflict, nothing is overwritten")
    func serverRecordChangedForUserContentCreatesConflict() async throws {
        let (mac, phone) = try await devices()
        let item = try await sharedItem(mac, phone)

        _ = try await phone.database.workItems.update(item.uuid, expectedRevision: item.revision, actor: phone.actor, at: t0.addingTimeInterval(10)) {
            $0.title = "Vom iPhone"
        }
        try await phone.sync(.localChange)
        let macVersion = try await mac.database.workItems.update(item.uuid, expectedRevision: item.revision, actor: mac.actor, at: t0.addingTimeInterval(11)) {
            $0.title = "Vom Mac"
        }

        // Send without fetching first: CloudKit rejects the stale change tag.
        let result = await mac.coordinator.sendChanges()
        let report = try #require(result.report)
        #expect(report.conflicts == 1)
        #expect(try await mac.database.workItems.fetch(item.uuid) == macVersion)
        let conflict = try #require(try await mac.database.sync.openConflicts().first)
        #expect(try decode(WorkItem.self, conflict.remotePayload).title == "Vom iPhone")
        let serverRecord = try #require(await server.record(SyncRecordSchema.recordID(.workItem, item.uuid.rawValue)))
        #expect(try decode(WorkItem.self, try SyncRecordMapper(deviceId: DeviceID()).decode(serverRecord).change.payload).title == "Vom iPhone")
    }

    @Test("serverRecordChanged merge: execution-host data — Mac re-sends on top, iPhone adopts")
    func serverRecordChangedMergeForHostOwnedData() async throws {
        let (mac, phone) = try await devices()
        let host = AgentHost(hostId: Fixture.host, name: "Mac Studio", lastSeen: t0, ready: true, serviceVersion: "1.0")
        try await mac.database.capabilities.saveHost(host, at: t0)
        try await mac.sync(.poll)
        try await phone.sync(.foreground)
        #expect(try await phone.database.capabilities.host(Fixture.host)?.name == "Mac Studio")

        // Phone writes first (stale view), then the Mac sends its own update without fetching.
        var phoneHost = host
        phoneHost.ready = false
        phoneHost.name = "Veraltet"
        try await phone.database.capabilities.saveHost(phoneHost, at: t0.addingTimeInterval(5))
        try await phone.sync(.localChange)
        var macHost = host
        macHost.lastSeen = t0.addingTimeInterval(6)
        macHost.serviceVersion = "1.1"
        try await mac.database.capabilities.saveHost(macHost, at: t0.addingTimeInterval(6))
        let macRun = try #require(await mac.coordinator.sendChanges().report)
        // ADR-0026: the phone's write to host-owned data is rejected by ownership (kept as a resolved
        // `rejectedOwnership` record) before any merge; the Mac re-sends its value on top.
        #expect(macRun.mergedOnServerChange == 0)
        #expect(try await mac.database.sync.resolvedConflicts(limit: 10).map(\.resolution) == [RemoteOwnershipPolicy.rejectedResolution])
        #expect(macRun.sent >= 1)
        #expect(try await mac.database.sync.openConflicts().isEmpty)
        #expect(try await mac.database.capabilities.host(Fixture.host) == macHost)

        // Phone edits again from its stale state; on send it adopts the host's version.
        var phoneAgain = phoneHost
        phoneAgain.name = "Noch älter"
        try await phone.database.capabilities.saveHost(phoneAgain, at: t0.addingTimeInterval(7))
        let phoneRun = try #require(await phone.coordinator.sendChanges().report)
        #expect(phoneRun.mergedOnServerChange == 1)
        #expect(try await phone.database.capabilities.host(Fixture.host)?.name == "Mac Studio")
        #expect(try await phone.database.capabilities.host(Fixture.host)?.serviceVersion == "1.1")
        #expect(try await phone.database.sync.openConflicts().isEmpty)
        #expect(await phone.status().pendingCount == 0)

        // Server holds the host's version; a later fetch on the phone is a no-op.
        let serverRecord = try #require(await server.record(SyncRecordSchema.recordID(.agentHost, Fixture.host.rawValue)))
        #expect(try decode(AgentHost.self, try SyncRecordMapper(deviceId: DeviceID()).decode(serverRecord).change.payload).serviceVersion == "1.1")
        let fetch = try await phone.sync(.foreground)
        #expect(fetch.conflicts == 0)
    }

    // MARK: Deletion

    @Test("Deletion propagates as tombstone; hard deletions from outside are applied too")
    func deletionPropagatesAsTombstone() async throws {
        let (mac, phone) = try await devices()
        let item = try await sharedItem(mac, phone)

        try await mac.database.workItems.delete(item.uuid, expectedRevision: item.revision, at: t0.addingTimeInterval(10))
        try await mac.sync(.manual)
        // CloudKit keeps a tombstone record without user data.
        let record = try #require(await server.record(SyncRecordSchema.recordID(.workItem, item.uuid.rawValue)))
        #expect(record[SyncRecordSchema.Field.isDeleted] as? Int == 1)
        #expect(record.encryptedValues[SyncRecordSchema.Field.payload] == nil)

        let report = try await phone.sync(.foreground)
        #expect(report.deleted == 1)
        #expect(try await phone.database.workItems.fetch(item.uuid) == nil)
        let tombstone = try #require(try await phone.database.sync.tombstone(entityType: .workItem, entityId: item.uuid.rawValue))
        #expect(tombstone.origin == .remote)

        // Replayed old records cannot resurrect it.
        phone.engine.value!.rewindChangeToken(to: 0)
        try await phone.sync(.foreground)
        #expect(try await phone.database.workItems.fetch(item.uuid) == nil)

        // Hard deletion (e.g. CloudKit Console) of another item.
        let other = Fixture.workItem(projectId: item.projectId, title: "Zweite")
        try await phone.database.workItems.insert(other, actor: phone.actor, at: t0.addingTimeInterval(20))
        try await phone.sync(.localChange)
        try await mac.sync(.poll)
        #expect(try await mac.database.workItems.fetch(other.uuid) != nil)
        await server.deleteRecord(SyncRecordSchema.recordID(.workItem, other.uuid.rawValue))
        let hard = try await mac.sync(.poll)
        #expect(hard.deleted == 1)
        #expect(try await mac.database.workItems.fetch(other.uuid) == nil)
    }

    // MARK: Zones

    @Test("zoneNotFound on send for a zone this device knew: paused, not re-created until the user decides")
    func zoneNotFoundRecovery() async throws {
        let (mac, phone) = try await devices()
        let project = try await sharedProject(mac, phone)
        await server.deleteZone(SyncRecordSchema.zoneID, reason: .deleted)
        #expect(await !server.hasZone(SyncRecordSchema.zoneID))

        var renamed = try #require(try await mac.database.projects.fetch(project.id))
        renamed.name = "Umbenannt"
        _ = try await mac.database.projects.update(renamed, expectedRevision: renamed.revision, at: t0.addingTimeInterval(5))
        // Send-only run (no fetch that would have reported the deletion first).
        #expect(await mac.coordinator.sendChanges() == .paused(.zoneDeleted))
        #expect(await !server.hasZone(SyncRecordSchema.zoneID))
        #expect(await mac.status().attention.contains(.zoneDeleted(.deleted)))
        #expect(await mac.status().pendingCount >= 1) // the change is kept, not lost

        // The user decides to upload again: zone re-created and the record sent.
        await mac.coordinator.recreateZoneAndResume()
        let report = try await mac.sync(.manual)
        #expect(report.sent >= 1)
        #expect(await server.hasZone(SyncRecordSchema.zoneID))
        #expect(await server.recordNames(in: SyncRecordSchema.zoneID).contains(SyncRecordSchema.recordName(.project, project.id.rawValue)))
        #expect(await mac.status().pendingCount == 0)
    }

    @Test("Zone deleted on the server: surfaced, sync paused, local data kept until the user decides")
    func zoneDeletionIsSurfacedNotWiped() async throws {
        let (mac, phone) = try await devices()
        let item = try await sharedItem(mac, phone)
        await server.deleteZone(SyncRecordSchema.zoneID, reason: .purged)

        let result = await phone.coordinator.syncNow(reason: .foreground)
        #expect(result == .paused(.zoneDeleted))
        let status = await phone.status()
        #expect(status.attention.contains(.zoneDeleted(.purged)))
        #expect(status.isPaused)
        #expect(try await phone.database.workItems.fetch(item.uuid) == item)
        #expect(await phone.coordinator.syncNow(reason: .poll) == .paused(.zoneDeleted))

        // The user chooses to upload again: zone is recreated, pending changes are sent.
        _ = try await phone.database.workItems.update(item.uuid, expectedRevision: item.revision, actor: phone.actor, at: t0.addingTimeInterval(30)) {
            $0.title = "Nach Zonenverlust"
        }
        await phone.coordinator.recreateZoneAndResume()
        let report = try await phone.sync(.manual)
        #expect(report.sent >= 1)
        #expect(await server.hasZone(SyncRecordSchema.zoneID))
        #expect(await phone.status().attention.isEmpty)
    }

    // MARK: Errors and account

    @Test("Transient error honours retry-after before contacting CloudKit again")
    func transientErrorHonoursRetryAfter() async throws {
        let (mac, _) = try await devices()
        let (project, settings) = Fixture.project()
        try await mac.database.projects.create(project, settings: settings, at: t0)
        await server.failNextRequests(code: .requestRateLimited, retryAfter: 30)

        let first = await mac.coordinator.syncNow(reason: .poll)
        guard case let .failed(failure) = first else { Issue.record("expected failure, got \(first)"); return }
        #expect(failure.retryAfter == 30)
        #expect(failure.code == .requestRateLimited)
        let status = await mac.status()
        #expect(status.lastError == "iCloud drosselt Anfragen. Nächster Versuch in 30 Sekunden.")
        #expect(status.retryNotBefore == clock.now.addingTimeInterval(30))
        let requests = await server.requestCount

        clock.advance(by: 10)
        #expect(await mac.coordinator.syncNow(reason: .manual) == .deferred(until: t0.addingTimeInterval(30)))
        #expect(await server.requestCount == requests)

        clock.advance(by: 21)
        let report = try await mac.sync(.manual)
        #expect(report.sent >= 1)
        #expect(await mac.status().retryNotBefore == nil)
        #expect(await mac.status().lastError == nil)
    }

    @Test("Account signed out: sync pauses, nothing local is deleted, resumes after sign-in")
    func signedOutAccountPausesWithoutDeletingLocalData() async throws {
        let (mac, phone) = try await devices()
        let item = try await sharedItem(mac, phone)

        phone.connection.userRecordName = nil
        let draft = Fixture.workItem(projectId: item.projectId, title: "Entwurf ohne iCloud")
        try await phone.database.workItems.insert(draft, actor: phone.actor, at: t0.addingTimeInterval(5))
        let result = await phone.coordinator.syncNow(reason: .foreground)
        guard case let .failed(failure) = result else { Issue.record("expected failure, got \(result)"); return }
        #expect(failure.code == .notAuthenticated)
        var status = await phone.status()
        #expect(status.accountState == .signedOut)
        #expect(status.attention.contains(.accountSignedOut))
        #expect(status.isPaused)
        #expect(status.pendingCount >= 1)
        #expect(await phone.coordinator.syncNow(reason: .poll) == .paused(.accountUnavailable))
        #expect(try await phone.database.workItems.fetch(item.uuid) == item)
        #expect(try await phone.database.workItems.fetch(draft.uuid) == draft)

        // Same account signs in again: sync resumes and uploads the draft.
        phone.connection.userRecordName = "_user-A"
        let report = try await phone.sync(.foreground)
        #expect(report.sent >= 1)
        status = await phone.status()
        #expect(status.accountState == .available)
        #expect(!status.isPaused)
        try await mac.sync(.poll)
        #expect(try await mac.database.workItems.fetch(draft.uuid) != nil)
    }

    @Test("Account switched: paused until the user confirms; local data kept")
    func switchedAccountNeedsConfirmation() async throws {
        let (mac, phone) = try await devices()
        let item = try await sharedItem(mac, phone)

        phone.connection.userRecordName = "_user-B"
        let result = await phone.coordinator.syncNow(reason: .foreground)
        #expect(result == .paused(.accountSwitched))
        let status = await phone.status()
        #expect(status.accountState == .switched)
        #expect(status.attention.contains(.accountSwitched))
        #expect(try await phone.database.workItems.fetch(item.uuid) == item)

        // Pause survives a restart (metadata persisted through the sync store).
        let restarted = SyncCoordinator(store: phone.database.sync, configuration: phone.coordinator.configuration,
                                        engineFactory: FakeSyncEngine.factory(server: server, connection: phone.connection))
        try await restarted.start()
        #expect(await restarted.syncNow(reason: .manual) == .paused(.accountSwitched))
        try await restarted.acknowledgeAccountChange()
        #expect(await restarted.syncNow(reason: .manual).report != nil)
        #expect(await restarted.status.accountState == .available)
    }

    // MARK: Limits and secrets

    @Test("Send batches never exceed 250 records")
    func batchesRespectCloudKitLimit() async throws {
        let (mac, phone) = try await devices()
        let project = try await sharedProject(mac, phone)
        for index in 0..<160 {
            try await phone.database.workItems.insert(Fixture.workItem(projectId: project.id, title: "Aufgabe \(index)"),
                                                      actor: phone.actor, at: t0.addingTimeInterval(Double(index)))
        }
        let report = try await phone.sync(.localChange)
        #expect(report.sent == 320) // work item + creation event each
        let sizes = await server.modifyBatchSizes
        #expect(sizes.allSatisfy { $0 <= SyncRecordSchema.maxRecordsPerBatch })
        #expect(sizes.contains(SyncRecordSchema.maxRecordsPerBatch))
        let fetched = try await mac.sync(.poll)
        #expect(fetched.applied == 320)
        #expect(try await mac.database.workItems.list(WorkItemFilter(project: .project(project.id))).count == 160)
    }

    @Test("A provider profile with key material never reaches CloudKit")
    func secretsAreBlockedBeforeUpload() async throws {
        let (_, phone) = try await devices()
        var profile = ProviderProfile(
            providerId: .openAI, purpose: .textDrafting,
            keychainReference: KeychainReference(service: "de.softwareregisseur.ai", account: "openai"),
            deviceScope: .iCloudKeychain
        )
        profile.settings["apiKey"] = "sk-proj-" + String(repeating: "Z", count: 40)
        try await phone.database.providerProfiles.save(profile, at: t0)
        let report = try await phone.sync(.localChange)
        #expect(report.sent == 0)
        #expect(await server.record(SyncRecordSchema.recordID(.providerProfile, profile.id.rawValue)) == nil)
        let status = await phone.status()
        #expect(status.attention.contains(.secretsBlocked(1)))
        #expect(status.lastError?.contains("Zugangsdaten") == true)
        #expect(status.pendingCount == 1)

        // After removing the key from the settings the clean profile syncs.
        profile.settings["apiKey"] = nil
        try await phone.database.providerProfiles.save(profile, at: t0.addingTimeInterval(1))
        let clean = try await phone.sync(.localChange)
        #expect(clean.sent == 1)
        #expect(await phone.status().attention.isEmpty)
    }
}

@Suite("Crash and edge recovery")
struct RecoveryTests {
    let server = FakeCloudDatabase()

    @Test("Lost send response: the retry is confirmed idempotently, later edits still go out (A21)")
    func lostResponseIsConfirmedIdempotently() async throws {
        let phone = try await SimulatedDevice.make("phone", role: .mobile, server: server)
        let mac = try await SimulatedDevice.make("mac", role: .executionHost(Fixture.host), server: server)
        let item = Fixture.workItem(projectId: nil, title: "Einmal")
        try await phone.database.workItems.insert(item, actor: phone.actor, at: t0)
        await server.loseNextModifyResponse()
        let lost = await phone.coordinator.syncNow(reason: .localChange)
        guard case .failed = lost else { Issue.record("expected failure, got \(lost)"); return }
        #expect(await phone.status().pendingCount == 2)
        #expect(await server.recordNames(in: SyncRecordSchema.zoneID).count == 2)

        // Edited again before the retry: the newer version must still reach the server.
        _ = try await phone.database.workItems.update(item.uuid, expectedRevision: item.revision, actor: phone.actor, at: t0.addingTimeInterval(1)) {
            $0.title = "Zweimal"
        }
        let retry = try await phone.sync(.foreground)
        #expect(retry.conflicts == 0)
        #expect(retry.mergedOnServerChange >= 1)
        #expect(await phone.status().pendingCount == 0)
        #expect(try await phone.database.sync.openConflicts().isEmpty)

        let fetched = try await mac.sync(.poll)
        #expect(fetched.conflicts == 0)
        #expect(try await mac.database.workItems.fetch(item.uuid)?.title == "Zweimal")
    }

    @Test("Provider profile switched to device-only: removed from CloudKit, kept locally (N1)")
    func deviceOnlyProfileIsRemovedRemotely() async throws {
        let phone = try await SimulatedDevice.make("phone", role: .mobile, server: server)
        let mac = try await SimulatedDevice.make("mac", role: .executionHost(Fixture.host), server: server)
        var profile = ProviderProfile(
            providerId: .openAI, purpose: .textDrafting,
            keychainReference: KeychainReference(service: "de.softwareregisseur.ai", account: "openai"),
            deviceScope: .iCloudKeychain
        )
        try await phone.database.providerProfiles.save(profile, at: t0)
        try await phone.sync(.localChange)
        try await mac.sync(.poll)
        #expect(try await mac.database.providerProfiles.fetch(profile.id) == profile)

        profile.deviceScope = .thisDeviceOnly
        try await phone.database.providerProfiles.save(profile, at: t0.addingTimeInterval(1))
        let report = try await phone.sync(.localChange)
        #expect(report.sent == 1)
        #expect(try await phone.database.providerProfiles.fetch(profile.id) == profile)
        let record = try #require(await server.record(SyncRecordSchema.recordID(.providerProfile, profile.id.rawValue)))
        #expect(record[SyncRecordSchema.Field.isDeleted] as? Int == 1)

        // Own tombstone echo does not delete the local profile; the Mac drops its copy.
        phone.engine.value!.rewindChangeToken(to: 0)
        try await phone.sync(.foreground)
        #expect(try await phone.database.providerProfiles.fetch(profile.id) == profile)
        try await mac.sync(.poll)
        #expect(try await mac.database.providerProfiles.fetch(profile.id) == nil)
    }

    @Test("Status stream reports sync time for the UI (A26)")
    func statusStreamReportsSyncTime() async throws {
        let clock = TestClock()
        let mac = try await SimulatedDevice.make("mac", role: .executionHost(Fixture.host), server: server, clock: clock)
        let stream = await mac.coordinator.statusUpdates()
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        #expect(initial?.lastSuccessfulFetch == nil)
        try await mac.sync(.manual)
        var latest = await mac.status()
        #expect(latest.lastSuccessfulFetch == clock.now)
        #expect(latest.lastSuccessfulSend == clock.now)
        #expect(latest.accountState == .available)
        latest = try #require(await iterator.next())
        #expect(latest.lastSuccessfulFetch == clock.now)
    }
}
