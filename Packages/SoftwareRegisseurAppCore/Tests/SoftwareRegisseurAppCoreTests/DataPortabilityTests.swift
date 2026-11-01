import Foundation
import Synchronization
import SoftwareRegisseurAppCore
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence
import SoftwareRegisseurPortability
import SoftwareRegisseurSecrets
import Testing

/// Temporary app container with database, audio and settings files.
private final class Container: Sendable {
    let root: URL
    let locations: LocalDataLocations
    let keychain = InMemoryKeychainStore()
    let date = Mutex(now)
    let shutdowns = Mutex(0)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AppCoreA34-\(UUID().uuidString)", isDirectory: true)
        let data = root.appendingPathComponent("SoftwareRegisseur", isDirectory: true)
        let audio = data.appendingPathComponent("Audio", isDirectory: true)
        let cache = root.appendingPathComponent("SyncAssets", isDirectory: true)
        for folder in [data, audio, cache] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("RIFF".utf8).write(to: audio.appendingPathComponent("Diktat-1.m4a"))
        try Data("RIFF2".utf8).write(to: audio.appendingPathComponent("Diktat-2.m4a"))
        try Data("{}".utf8).write(to: data.appendingPathComponent("settings.json"))
        try Data("asset".utf8).write(to: cache.appendingPathComponent("payload.bin"))
        locations = LocalDataLocations(
            appDataRoot: data, databaseFile: data.appendingPathComponent("SoftwareRegisseur.sqlite"), audioDirectory: audio,
            cacheDirectories: [cache], additionalFiles: [data.appendingPathComponent("settings.json")]
        )
        try keychain.save(SecretValue("value-1"), account: "openai.text", mode: .deviceOnly)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var clock: @Sendable () -> Date { { [self] in self.date.withLock { $0 } } }

    func eraser(database: AppDatabase? = nil) -> LocalDataEraser {
        LocalDataEraser(locations: locations, keychain: keychain, database: database,
                        databaseShutdown: Shutdown(counter: self), protectedPaths: [], clock: clock)
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    var audioFiles: [URL] {
        ["Diktat-1.m4a", "Diktat-2.m4a"].map { locations.audioDirectory.appendingPathComponent($0) }
    }

    struct Shutdown: LocalDatabaseShutdown {
        let counter: Container
        func closeDatabaseForDeletion() async throws { counter.shutdowns.withLock { $0 += 1 } }
    }
}

/// Records every request; optionally fails with a German message.
private final class CloudSpy: CloudDataDeleting {
    let requests = Mutex<[CloudDataDeletionRequest]>([])
    let failure: CloudDataDeletionFailure?

    init(failure: CloudDataDeletionFailure? = nil) { self.failure = failure }

    func deleteCloudData(_ request: CloudDataDeletionRequest) async throws {
        requests.withLock { $0.append(request) }
        if let failure { throw failure }
    }
}

@MainActor
@Suite("Data export and deletion view models (A34)")
struct DataPortabilityTests {
    // MARK: Deletion

    @Test func previewIsShownBeforeAnythingIsDeleted() async throws {
        let container = try Container()
        var hooks: [LocalDeletionChoice] = []
        let model = DataDeletionModel(eraser: container.eraser(), cloud: CloudSpy(), clock: container.clock) { choice, _ in
            hooks.append(choice)
        }
        await model.prepare(.audioRecordings)
        guard case let .preview(.local(choice, plan)) = model.step else {
            Issue.record("expected a preview, got \(model.step)")
            return
        }
        #expect(choice == .audioRecordings)
        #expect(Set(plan.items.compactMap(\.url?.lastPathComponent)) == ["Diktat-1.m4a", "Diktat-2.m4a"])
        #expect(container.audioFiles.allSatisfy(container.exists), "preview deletes nothing")

        // No execution without the explicit acknowledgement.
        #expect(!model.canConfirm)
        await model.confirm()
        #expect(model.preview != nil)
        #expect(container.audioFiles.allSatisfy(container.exists))
        #expect(hooks.isEmpty)

        model.isAcknowledged = true
        #expect(model.canConfirm)
        await model.confirm()
        guard case let .completed(.local(.audioRecordings, report)) = model.step else {
            Issue.record("expected completion, got \(model.step)")
            return
        }
        #expect(report.deleted.count == 2)
        #expect(!container.audioFiles.contains(where: container.exists))
        #expect(container.exists(container.locations.appDataRoot.appendingPathComponent("settings.json")))
        #expect(hooks == [.audioRecordings])
        #expect(!model.isAcknowledged)
    }

    @Test func nothingExecutesWithoutAValidPreviewAndToken() async throws {
        let container = try Container()
        let eraser = container.eraser()
        let model = DataDeletionModel(eraser: eraser, cloud: nil, clock: container.clock)
        // No preview: confirm is a no-op.
        model.isAcknowledged = true
        await model.confirm()
        #expect(model.step == .idle)
        #expect(container.audioFiles.allSatisfy(container.exists))

        // The eraser itself refuses a plan without its token (the model never calls it that way).
        let plan = try await eraser.preparePlan(.audioRecordings)
        await #expect(throws: DeletionError.confirmationRequired) { _ = try await eraser.execute(plan, confirmation: nil) }
        await #expect(throws: DeletionError.confirmationRequired) {
            _ = try await eraser.execute(plan, confirmation: DeletionConfirmationToken(value: "geraten"))
        }

        // An expired preview cannot be confirmed; executing it anyway is refused by the token check.
        await model.prepare(.audioRecordings)
        model.isAcknowledged = true
        container.date.withLock { $0 = $0.addingTimeInterval(LocalDataEraser.defaultValidity + 1) }
        #expect(model.isPreviewExpired)
        #expect(!model.canConfirm)
        await model.confirm()
        #expect(model.step == .failed(.deletion(.planExpired)))
        #expect(container.audioFiles.allSatisfy(container.exists))

        // Cancelling a preview deletes nothing.
        await model.prepare(.everythingLocal)
        model.cancel()
        #expect(model.step == .idle)
        #expect(container.audioFiles.allSatisfy(container.exists))
        #expect(try container.keychain.listAccounts() == ["openai.text"])
    }

    @Test func iCloudDataIsDeletedOnlyThroughTheCoordinator() async throws {
        let container = try Container()
        let spy = CloudSpy()
        let model = DataDeletionModel(eraser: container.eraser(), cloud: spy, clock: container.clock)
        #expect(model.isCloudDeletionAvailable)

        // Local plans never reach iCloud.
        await model.prepare(.audioRecordings)
        model.isAcknowledged = true
        await model.confirm()
        #expect(spy.requests.withLock { $0.isEmpty })

        // The separate iCloud plan: preview first, nothing sent until confirmed.
        await model.prepareCloudDeletion()
        guard case let .preview(.cloud(plan)) = model.step else {
            Issue.record("expected the iCloud preview, got \(model.step)")
            return
        }
        #expect(plan.zoneName == CloudSyncZone.name)
        #expect(!plan.consequences.isEmpty)
        await model.confirm()
        #expect(spy.requests.withLock { $0.isEmpty })
        model.isAcknowledged = true
        await model.confirm()
        let requests = spy.requests.withLock { $0 }
        #expect(requests.count == 1)
        #expect(requests.first?.zoneName == CloudSyncZone.name)
        #expect(requests.first?.suppressAutomaticReupload == true)
        #expect(model.step == .completed(.cloud(try #require(requests.first))))
        // The cloud plan touches no local file and no key.
        #expect(container.exists(container.locations.appDataRoot.appendingPathComponent("settings.json")))
        #expect(try container.keychain.listAccounts() == ["openai.text"])
        #expect(container.shutdowns.withLock { $0 } == 0)
    }

    @Test func iCloudPlanWithoutSyncOrWithAFailureIsReported() async throws {
        let container = try Container()
        let local = DataDeletionModel(eraser: container.eraser(), cloud: nil, clock: container.clock)
        #expect(!local.isCloudDeletionAvailable)
        await local.prepareCloudDeletion()
        #expect(local.step == .failed(.cloudUnavailable))

        let failing = CloudSpy(failure: CloudDataDeletionFailure(message: "Keine Verbindung zu iCloud."))
        let model = DataDeletionModel(eraser: container.eraser(), cloud: failing, clock: container.clock)
        await model.prepareCloudDeletion()
        model.isAcknowledged = true
        await model.confirm()
        #expect(model.step == .failed(.cloud("Keine Verbindung zu iCloud.")))
        #expect(failing.requests.withLock { $0.count } == 1)
    }

    @Test func databasePlanClosesTheDatabaseAndRestoresTheAppState() async throws {
        let container = try Container()
        let database = try AppDatabase.openWriter(at: container.locations.databaseFile)
        var reopened = 0
        let model = DataDeletionModel(eraser: container.eraser(database: database), cloud: CloudSpy(), clock: container.clock) { choice, _ in
            if choice.resetsDatabase { reopened += 1 }
        }
        await model.prepare(.localDatabase)
        guard case let .preview(.local(_, plan)) = model.step else {
            Issue.record("expected a preview, got \(model.step)")
            return
        }
        #expect(plan.items.contains { $0.url?.lastPathComponent == "SoftwareRegisseur.sqlite" })
        #expect(plan.items.contains { $0.url?.lastPathComponent == "payload.bin" })
        try database.close()
        model.isAcknowledged = true
        await model.confirm()
        #expect(container.shutdowns.withLock { $0 } == 1)
        #expect(!container.exists(container.locations.databaseFile))
        #expect(reopened == 1)
        #expect(container.audioFiles.allSatisfy(container.exists), "audio stays with the database plan")
        #expect(LocalDeletionChoice.allCases.map(\.resetsDatabase) == [false, false, true, true])
    }

    // MARK: Export

    @Test func exportReportsProgressAndOffersTheArchive() async throws {
        let container = try Container()
        let (database, _, _) = try await Fixture.makeDatabase()
        let destination = container.root.appendingPathComponent("Exports", isDirectory: true)
        let model = DataExportModel.live(database: database, audioDirectory: container.locations.audioDirectory, destination: destination)
        model.start()
        #expect(model.isRunning)
        await model.waitUntilFinished()
        let outcome = try #require(model.outcome)
        #expect(outcome.archiveURL != nil)
        #expect(outcome.shareURL == outcome.archiveURL)
        #expect(container.exists(outcome.shareURL))
        #expect(outcome.entityCount >= 3)
        #expect(outcome.audioFiles == 0)

        // A second export replaces the first; discarding removes the files.
        model.start()
        await model.waitUntilFinished()
        let second = try #require(model.outcome)
        #expect(!container.exists(outcome.folderURL) || outcome.folderURL == second.folderURL)
        model.discard()
        #expect(model.state == .idle)
        #expect(!container.exists(second.shareURL))
    }

    @Test func exportCanBeCancelledAndReportsFailures() async throws {
        let container = try Container()
        let destination = container.root.appendingPathComponent("Exports", isDirectory: true)
        let started = Mutex(false)
        let cancellable = DataExportModel(destination: destination) { _, _, progress in
            progress(ExportProgress(phase: .entities, exportedEntities: 10, pagesRead: 1, fractionCompleted: 0.3))
            started.withLock { $0 = true }
            while true {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        cancellable.start()
        while !started.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        cancellable.cancel()
        await cancellable.waitUntilFinished()
        #expect(cancellable.state == .cancelled)

        let failing = DataExportModel(destination: destination) { _, _, _ in throw ExportError.secretDetected(["$[0].settings.apiKey"]) }
        failing.start()
        await failing.waitUntilFinished()
        #expect(failing.state == .failed(.export(.secretDetected(["$[0].settings.apiKey"]))))

        let includeAudio = Mutex<Bool?>(nil)
        let audio = DataExportModel(destination: destination) { flag, _, _ in
            includeAudio.withLock { $0 = flag }
            throw CancellationError()
        }
        audio.includeAudio = true
        audio.start()
        await audio.waitUntilFinished()
        #expect(includeAudio.withLock { $0 } == true)
    }
}
