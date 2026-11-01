import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence
import SoftwareRegisseurSecrets
import Synchronization
import Testing
@testable import SoftwareRegisseurPortability

@Suite("Local data deletion (A27, A34)")
struct LocalDataEraserTests {
    /// App container layout like the iOS `AppDirectories`, plus a Git repository next to it.
    final class Fixture: @unchecked Sendable {
        let temp: TemporaryDirectory
        let root: URL
        let locations: LocalDataLocations
        let repository: URL
        let keychain = InMemoryKeychainStore()
        let shutdownCalls = Mutex(0)

        init() throws {
            temp = try TemporaryDirectory()
            root = temp.url.appendingPathComponent("AppData", isDirectory: true)
            let audio = root.appendingPathComponent("Audio", isDirectory: true)
            let cache = temp.url.appendingPathComponent("Caches/SyncAssets", isDirectory: true)
            repository = temp.url.appendingPathComponent("Code/Regie", isDirectory: true)
            let fileManager = FileManager.default
            for directory in [root, audio, cache, repository.appendingPathComponent(".git")] {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try Data("a1".utf8).write(to: audio.appendingPathComponent("Diktat-1.m4a"))
            try Data("a22".utf8).write(to: audio.appendingPathComponent("Diktat-2.m4a"))
            for suffix in ["", "-wal", "-shm"] {
                try Data("db".utf8).write(to: root.appendingPathComponent("SoftwareRegisseur.sqlite" + suffix))
            }
            try Data("{}".utf8).write(to: root.appendingPathComponent("settings.json"))
            try Data("asset".utf8).write(to: cache.appendingPathComponent("asset-1"))
            try Data("code".utf8).write(to: repository.appendingPathComponent("main.swift"))
            locations = LocalDataLocations(
                appDataRoot: root, databaseFile: root.appendingPathComponent("SoftwareRegisseur.sqlite"), audioDirectory: audio,
                cacheDirectories: [cache], additionalFiles: [root.appendingPathComponent("settings.json")]
            )
            try keychain.save(SecretValue(FakeSecrets.openAIKey), account: "openai-device")
            try keychain.save(SecretValue(FakeSecrets.anthropicKey), account: "anthropic", mode: .synchronizableRequested)
        }

        func eraser(database: AppDatabase? = nil, clock: @escaping @Sendable () -> Date = { t0 }) -> LocalDataEraser {
            LocalDataEraser(locations: locations, keychain: keychain, database: database, databaseShutdown: Shutdown(calls: self),
                            protectedPaths: [repository], clock: clock)
        }

        func exists(_ relative: String) -> Bool {
            FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path)
        }
    }

    struct Shutdown: LocalDatabaseShutdown {
        let calls: Fixture
        func closeDatabaseForDeletion() async throws { calls.shutdownCalls.withLock { $0 += 1 } }
    }

    @Test func audioPlanPreviewsExactFilesAndRequiresToken() async throws {
        let fixture = try Fixture()
        let eraser = fixture.eraser()
        let plan = try await eraser.preparePlan(.audioRecordings)
        #expect(plan.items.compactMap(\.url?.lastPathComponent) == ["Diktat-1.m4a", "Diktat-2.m4a"])
        #expect(plan.items.map(\.byteCount) == [2, 3])
        #expect(plan.totalBytes == 5)
        #expect(plan.items.allSatisfy { $0.label.hasPrefix("Audioaufnahme „") })
        #expect(!plan.affectsCloudData)
        #expect(plan.retained.contains { $0.contains("iCloud-Daten bleiben erhalten") })

        await #expect(throws: DeletionError.confirmationRequired) { _ = try await eraser.execute(plan, confirmation: nil) }
        await #expect(throws: DeletionError.confirmationRequired) {
            _ = try await eraser.execute(plan, confirmation: DeletionConfirmationToken(value: "falsch"))
        }
        #expect(fixture.exists("Audio/Diktat-1.m4a"))

        // A file created after the preview is not deleted.
        try Data("neu".utf8).write(to: fixture.locations.audioDirectory.appendingPathComponent("Diktat-3.m4a"))
        let report = try await eraser.execute(plan, confirmation: plan.confirmationToken)
        #expect(report.deleted.count == 2 && report.isComplete)
        #expect(!fixture.exists("Audio/Diktat-1.m4a") && !fixture.exists("Audio/Diktat-2.m4a"))
        #expect(fixture.exists("Audio/Diktat-3.m4a"))
        #expect(fixture.exists("SoftwareRegisseur.sqlite"))
        #expect(try fixture.keychain.listAccounts().count == 2)

        await #expect(throws: DeletionError.planAlreadyUsed) { _ = try await eraser.execute(plan, confirmation: plan.confirmationToken) }
    }

    @Test func expiredPlanAndForeignTokenAreRefused() async throws {
        let fixture = try Fixture()
        let now = Mutex(t0)
        let eraser = fixture.eraser { now.withLock { $0 } }
        let first = try await eraser.preparePlan(.audioRecordings)
        let second = try await eraser.preparePlan(.audioRecordings)
        await #expect(throws: DeletionError.confirmationRequired) {
            _ = try await eraser.execute(first, confirmation: second.confirmationToken)
        }
        now.withLock { $0 = t0.addingTimeInterval(LocalDataEraser.defaultValidity + 1) }
        await #expect(throws: DeletionError.planExpired) { _ = try await eraser.execute(first, confirmation: first.confirmationToken) }
        #expect(fixture.exists("Audio/Diktat-1.m4a"))
        // A plan from another eraser instance is unknown here.
        let other = fixture.eraser()
        await #expect(throws: DeletionError.confirmationRequired) { _ = try await other.execute(second, confirmation: second.confirmationToken) }
    }

    @Test func apiKeysForSelectedProviderOrAll() async throws {
        let fixture = try Fixture()
        let database = try AppDatabase.inMemory()
        let profile = ProviderProfile(providerId: .openAI, purpose: .transcription,
                                      keychainReference: KeychainReference(service: "regie", account: "openai-device"))
        try await database.providerProfiles.save(profile, at: t0)
        let eraser = fixture.eraser(database: database)

        let selected = try await eraser.preparePlan(.apiKeys(.profiles([profile.id])))
        #expect(selected.items.map(\.kind) == [.keychainItem(account: "openai-device")])
        #expect(selected.items.first?.label == "API-Schlüssel für openai (transcription)")
        #expect(!selected.affectsOtherDevices)
        let report = try await eraser.execute(selected, confirmation: selected.confirmationToken)
        #expect(report.deleted.count == 1)
        #expect(try fixture.keychain.listAccounts() == ["anthropic"])
        #expect(try await database.providerProfiles.fetch(profile.id) == profile) // profile kept

        let all = try await eraser.preparePlan(.apiKeys(.all))
        #expect(all.items.map(\.kind) == [.keychainItem(account: "anthropic")])
        #expect(all.affectsOtherDevices) // iCloud Keychain item: flagged in the preview
        _ = try await eraser.execute(all, confirmation: all.confirmationToken)
        #expect(try fixture.keychain.listAccounts().isEmpty)
    }

    @Test func databasePlanClosesDatabaseFirstAndKeepsAudioAndKeys() async throws {
        let fixture = try Fixture()
        let eraser = fixture.eraser()
        let plan = try await eraser.preparePlan(.localDatabase)
        #expect(plan.items.compactMap(\.url?.lastPathComponent) == [
            "SoftwareRegisseur.sqlite", "SoftwareRegisseur.sqlite-wal", "SoftwareRegisseur.sqlite-shm", "asset-1",
        ])
        #expect(fixture.shutdownCalls.withLock { $0 } == 0) // planning never closes anything
        let report = try await eraser.execute(plan, confirmation: plan.confirmationToken)
        #expect(report.deleted.count == 4)
        #expect(fixture.shutdownCalls.withLock { $0 } == 1)
        #expect(!fixture.exists("SoftwareRegisseur.sqlite") && !fixture.exists("SoftwareRegisseur.sqlite-wal"))
        #expect(fixture.exists("Audio/Diktat-1.m4a") && fixture.exists("settings.json"))
        #expect(try fixture.keychain.listAccounts().count == 2)

        let withoutShutdown = LocalDataEraser(locations: fixture.locations, keychain: fixture.keychain, clock: { t0 })
        try Data("db".utf8).write(to: fixture.locations.databaseFile)
        let again = try await withoutShutdown.preparePlan(.localDatabase)
        await #expect(throws: DeletionError.databaseShutdownUnavailable) {
            _ = try await withoutShutdown.execute(again, confirmation: again.confirmationToken)
        }
        #expect(fixture.exists("SoftwareRegisseur.sqlite"))
    }

    @Test func everythingLocalNeverTouchesGitOrCloudAndKeepsSyncedKeys() async throws {
        let fixture = try Fixture()
        // A Git repository that ended up inside the app folder and a symlink to the user's repository.
        let nested = fixture.root.appendingPathComponent("Imported/Repo", isDirectory: true)
        try FileManager.default.createDirectory(at: nested.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: nested.appendingPathComponent("file.txt"))
        let link = fixture.root.appendingPathComponent("RepoLink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.repository)

        let eraser = fixture.eraser()
        let plan = try await eraser.preparePlan(.everythingLocal)
        let names = plan.items.compactMap(\.url?.lastPathComponent)
        #expect(names.contains("Audio") && names.contains("SoftwareRegisseur.sqlite") && names.contains("settings.json"))
        #expect(names.contains("asset-1") && names.contains("RepoLink"))
        #expect(!names.contains("Imported") && !names.contains("Repo"))
        #expect(!names.contains("Diktat-1.m4a")) // covered by the Audio directory item
        #expect(plan.items.contains { $0.kind == .keychainItem(account: "openai-device") })
        #expect(!plan.items.contains { $0.kind == .keychainItem(account: "anthropic") })
        #expect(plan.retained.contains { $0.contains("iCloud-Schlüsselbund") })
        #expect(plan.retained.contains { $0.contains("„Imported“ enthält ein Git-Repository") })
        #expect(!plan.affectsCloudData && !plan.affectsOtherDevices)

        let report = try await eraser.execute(plan, confirmation: plan.confirmationToken)
        #expect(report.isComplete)
        #expect(fixture.shutdownCalls.withLock { $0 } == 1)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        #expect(remaining == ["Imported"])
        #expect(FileManager.default.fileExists(atPath: nested.appendingPathComponent("file.txt").path))
        // The symlink was removed, never its target.
        #expect(FileManager.default.fileExists(atPath: fixture.repository.appendingPathComponent("main.swift").path))
        #expect(FileManager.default.fileExists(atPath: fixture.repository.appendingPathComponent(".git").path))
        #expect(try fixture.keychain.listAccounts() == ["anthropic"])
    }

    @Test func pathsOutsideAppFoldersOrInsideRepositoriesAreRefused() async throws {
        let fixture = try Fixture()
        // Misconfigured locations: audio "directory" is the user's repository.
        let bad = LocalDataLocations(appDataRoot: fixture.root, databaseFile: fixture.locations.databaseFile,
                                     audioDirectory: fixture.repository)
        let eraser = LocalDataEraser(locations: bad, keychain: fixture.keychain, protectedPaths: [fixture.repository], clock: { t0 })
        await #expect(throws: DeletionError.self) { _ = try await eraser.preparePlan(.audioRecordings) }
        #expect(FileManager.default.fileExists(atPath: fixture.repository.appendingPathComponent("main.swift").path))

        // App root inside a Git work tree: nothing is planned there.
        let repoRoot = fixture.repository.appendingPathComponent("AppData", isDirectory: true)
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: repoRoot.appendingPathComponent("settings.json"))
        let insideRepo = LocalDataLocations(appDataRoot: repoRoot, databaseFile: repoRoot.appendingPathComponent("db.sqlite"),
                                            audioDirectory: repoRoot.appendingPathComponent("Audio"))
        let repoEraser = LocalDataEraser(locations: insideRepo, keychain: InMemoryKeychainStore(), clock: { t0 })
        await #expect(throws: DeletionError.self) { _ = try await repoEraser.preparePlan(.everythingLocal) }
        #expect(FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("settings.json").path))
    }

    @Test func cloudDeletionOnlyProducesARequest() async throws {
        let fixture = try Fixture()
        let eraser = fixture.eraser()
        let plan = await eraser.prepareCloudDeletion()
        #expect(plan.zoneName == "SoftwareRegisseur")
        // One shared constant with the sync layer (`SyncRecordSchema.zoneName` reads it as well).
        #expect(LocalDataEraser.cloudZoneName == CloudSyncZone.name)
        #expect(plan.consequences.count == 3)
        await #expect(throws: DeletionError.confirmationRequired) { _ = try await eraser.confirmCloudDeletion(plan, confirmation: nil) }
        let before = try allFiles(in: fixture.temp.url)
        let request = try await eraser.confirmCloudDeletion(plan, confirmation: plan.confirmationToken)
        #expect(request.zoneName == "SoftwareRegisseur")
        #expect(request.scope == .entireZone)
        #expect(request.suppressAutomaticReupload)
        #expect(request.id == plan.id)
        // Nothing local changed: files and keys are untouched.
        #expect(try allFiles(in: fixture.temp.url) == before)
        #expect(try fixture.keychain.listAccounts().count == 2)
        #expect(fixture.shutdownCalls.withLock { $0 } == 0)
        await #expect(throws: DeletionError.planAlreadyUsed) { _ = try await eraser.confirmCloudDeletion(plan, confirmation: plan.confirmationToken) }
        // Codable, so the app can persist it until the coordinator has performed it.
        let decoded = try JSONDecoder().decode(CloudDataDeletionRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded == request)
    }

    @Test func germanUserMessages() async throws {
        #expect(DeletionError.confirmationRequired.userMessage == "Bitte bestätigen Sie die Löschung ausdrücklich.")
        // String Catalog plural variants (formal „Sie“ texts live in the package catalog).
        let fixture = try Fixture()
        try FileManager.default.removeItem(at: fixture.locations.audioDirectory.appendingPathComponent("Diktat-2.m4a"))
        let single = try await fixture.eraser().preparePlan(.audioRecordings)
        #expect(single.summary.hasPrefix("1 Eintrag ("))
        #expect(single.summary.hasSuffix(") wird auf diesem Gerät endgültig gelöscht."))
        let plural = try await fixture.eraser().preparePlan(.localDatabase)
        #expect(plural.summary.hasPrefix("4 Einträge ("))
        #expect(ExportProgress(phase: .entities, exportedEntities: 1, pagesRead: 1, fractionCompleted: 0).localizedDescription
                == "1 Eintrag exportiert …")
        #expect(ExportError.secretDetected([]).userMessage.contains("Zugangsdaten"))
    }
}
