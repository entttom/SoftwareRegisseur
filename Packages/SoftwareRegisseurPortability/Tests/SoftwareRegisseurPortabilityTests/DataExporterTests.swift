import CryptoKit
import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence
import Synchronization
import Testing
@testable import SoftwareRegisseurPortability

@Suite("Data export (A34)")
struct DataExporterTests {
    let device = ExportDeviceInfo(name: "Test-Mac", platform: "macOS", osVersion: "26")

    func options(pageSize: Int = 7, zip: Bool = false, audio: URL? = nil, markdown: Bool = true) -> ExportOptions {
        ExportOptions(pageSize: pageSize, includeMarkdown: markdown, createZipArchive: zip, audioDirectory: audio,
                      appVersion: "1.0 (1)", device: device, timeZone: TimeZone(identifier: "Europe/Vienna")!)
    }

    /// Every stored entity of every kind appears exactly once and byte-identical to the canonical payload.
    @Test func exportRoundTripsEveryEntityType() async throws {
        let database = try AppDatabase.onDiskForTests()
        let seeded = try await database.seedAllEntityTypes()
        let temp = try TemporaryDirectory()
        let result = try await DataExporter(database: database.value, options: options()).export(into: temp.url, at: t0)
        let folder = result.folderURL

        // Expected: canonical payloads straight from Persistence.
        var expected: [SyncEntityType: [Data: UUID]] = [:]
        var cursor: SyncEntityCursor?
        repeat {
            let page = try await database.value.sync.syncableEntities(after: cursor, limit: 1_000)
            for entity in page.entities { expected[entity.entityType, default: [:]][entity.payload] = entity.entityId }
            cursor = page.next
        } while cursor != nil
        for id in [seeded.deviceProfile.id.rawValue] {
            var profile = try SyncPayloadCodec.decode(ProviderProfile.self, from: try #require(
                try await database.value.sync.currentPayload(entityType: .providerProfile, entityId: id)))
            profile.settings = profile.settings.filter { $0.key == "language" } // sanitized in the export
            expected[.providerProfile, default: [:]][try SyncPayloadCodec.encode(profile)] = id
        }
        let audioPayload = try #require(try await database.value.sync.currentPayload(entityType: .audioNote, entityId: seeded.audioNote.id.rawValue))
        expected[.audioNote, default: [:]][audioPayload] = seeded.audioNote.id.rawValue

        var changes: [RemoteChange] = []
        for type in SyncEntityType.allCases {
            let exported = try ExportReader.payloads(of: type, inExportFolder: folder)
            #expect(!exported.isEmpty, "no \(type.rawValue) exported")
            #expect(result.manifest.count(of: type) == exported.count)
            #expect(Set(exported) == Set(expected[type, default: [:]].keys), "\(type.rawValue) differs")
            #expect(exported.count == expected[type, default: [:]].count)
            if !type.isDeviceLocal {
                for payload in exported {
                    let id = try #require(expected[type]?[payload])
                    changes.append(RemoteChange(operationId: SyncOperationID(), entityType: type, entityId: id, kind: .create,
                                                version: 1, baseVersion: nil, payload: payload))
                }
            }
        }
        // Decoded domain values equal the repository values.
        let items = try ExportReader.entities(WorkItem.self, of: .workItem, inExportFolder: folder)
        #expect(Set(items) == [try #require(try await database.value.workItems.fetch(seeded.item.uuid)), seeded.inboxItem])
        #expect(try ExportReader.entities(ADR.self, of: .adr, inExportFolder: folder) == [seeded.adr])
        let jobs = try ExportReader.entities(AgentJob.self, of: .agentJob, inExportFolder: folder)
        #expect(jobs.first?.configSnapshot == seeded.job.configSnapshot)
        #expect(try ExportReader.entities(AudioNote.self, of: .audioNote, inExportFolder: folder) == [seeded.audioNote])
        let drafts = try ExportReader.entities(DraftVersion.self, of: .draftVersion, inExportFolder: folder)
        #expect(drafts.map(\.source).sorted { $0.rawValue < $1.rawValue } == [.ai, .original])
        let profiles = try ExportReader.entities(ProviderProfile.self, of: .providerProfile, inExportFolder: folder)
        #expect(Set(profiles.map(\.id)) == [seeded.deviceProfile.id, seeded.syncedProfile.id])

        // Exported payloads can be applied to an empty database (same codec as sync).
        let target = try AppDatabase.inMemory()
        let outcomes = try await target.sync.applyRemoteChanges(changes, engineState: nil, at: at(50))
        #expect(outcomes.allSatisfy { $0 == .applied })
        #expect(try await target.workItems.fetch(seeded.item.uuid) == database.value.workItems.fetch(seeded.item.uuid))

        // Sync conflict with both versions.
        let conflicts = try ExportReader.syncConflicts(inExportFolder: folder)
        #expect(conflicts.count == 1)
        #expect(conflicts.first?.entityId == seeded.inboxItem.uuid.rawValue)
        #expect(conflicts.first?.localPayload != nil && conflicts.first?.remotePayload != nil)
        #expect(result.manifest.syncConflicts == 1)
    }

    @Test func manifestCountsAndChecksumsMatchFiles() async throws {
        let database = try AppDatabase.onDiskForTests()
        _ = try await database.seedAllEntityTypes()
        let temp = try TemporaryDirectory()
        let result = try await DataExporter(database: database.value, options: options()).export(into: temp.url, at: t0)
        let manifest = try ExportManifest.load(fromExportFolder: result.folderURL)

        #expect(manifest.format == "software-regisseur-export")
        #expect(manifest.formatVersion == 1)
        #expect(manifest.device == device)
        #expect(manifest.appVersion == "1.0 (1)")
        #expect(abs(manifest.createdAt.timeIntervalSince(t0)) < 1)
        #expect(manifest.databaseSchema == (try database.value.appliedMigrations()))
        #expect(manifest.entities.count == SyncEntityType.allCases.count)
        #expect(manifest.count(of: .workItem) == 2)
        #expect(manifest.count(of: .adr) == 1)
        #expect(manifest.count(of: .providerProfile) == 2)
        #expect(manifest.count(of: .globalSettings) == 1)
        #expect(manifest.markdown == ExportManifest.MarkdownSummary(requests: 2, adrs: 1))

        let files = try allFiles(in: result.folderURL)
        #expect(Set(manifest.files.map(\.path)) == Set(files.keys).subtracting(["manifest.json"]))
        for entry in manifest.files {
            let data = try #require(files[entry.path])
            #expect(Int64(data.count) == entry.bytes, "\(entry.path)")
            #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == entry.sha256, "\(entry.path)")
        }
        for entity in manifest.entities {
            let array = try JSONSerialization.jsonObject(with: try #require(files[entity.path])) as? [Any]
            #expect(array?.count == entity.count)
        }
        // Human-readable Markdown with original note, transcript and drafts.
        let requestFile = try #require(files.first { $0.key.hasPrefix("markdown/requests/regie-u-") && $0.key.contains("export-bauen") })
        let markdown = String(decoding: requestFile.value, as: UTF8.self)
        #expect(markdown.contains("## Originalnotiz"))
        #expect(markdown.contains("## Transkript"))
        #expect(markdown.contains("## Entwurfsversionen"))
        #expect(markdown.contains("Datenexport"))
        #expect(files.keys.contains { $0.hasPrefix("markdown/requests/Eingang/") })
        let adrFile = try #require(files.first { $0.key.hasPrefix("markdown/adrs/") })
        #expect(adrFile.key.hasSuffix(".md") && adrFile.key.contains("ADR-0019-grdb"))
        #expect(String(decoding: adrFile.value, as: UTF8.self).contains("status: accepted"))
        #expect(files["LIESMICH.md"] != nil)
    }

    /// Provider key material never leaves the device; the user's own text is kept but flagged.
    @Test func secretsAreNeverExported() async throws {
        let database = try AppDatabase.onDiskForTests()
        let seeded = try await database.seedAllEntityTypes()
        let temp = try TemporaryDirectory()
        let result = try await DataExporter(database: database.value, options: options(zip: true)).export(into: temp.url, at: t0)
        let files = try allFiles(in: result.folderURL)

        for (path, data) in files {
            #expect(!data.contains(FakeSecrets.openAIKey), "provider key in \(path)")
        }
        let profileFile = try #require(files[DataExporter.entityFilePath(.providerProfile)])
        #expect(ExportSecretScanner.findings(inJSON: profileFile).isEmpty)
        #expect(!profileFile.contains("apiKey"))
        let removed = result.manifest.secretScan.removedProviderSettings
        #expect(removed.contains("\(seeded.deviceProfile.id.uuidString.lowercased()).settings.apiKey"))
        #expect(removed.contains("\(seeded.deviceProfile.id.uuidString.lowercased()).settings.baseNote"))

        // User-written text stays as-is (own content), but every occurrence is reported.
        let itemFile = try #require(files[DataExporter.entityFilePath(.workItem)])
        #expect(itemFile.contains(FakeSecrets.anthropicKey))
        let findings = result.manifest.secretScan.userContentFindings
        #expect(findings.contains { $0.path == DataExporter.entityFilePath(.workItem) && $0.location.hasSuffix(".originalNote") })
        #expect(findings.contains { $0.path.hasPrefix("markdown/requests/") })
        #expect(!findings.contains { $0.path == DataExporter.entityFilePath(.providerProfile) })
        // The manifest itself is clean and contains no values.
        let manifestData = try #require(files["manifest.json"])
        #expect(ExportSecretScanner.findings(inJSON: manifestData).isEmpty)
        #expect(!manifestData.contains(FakeSecrets.anthropicKey))

        // ZIP archive exists and is a real zip (local file header "PK\u{3}\u{4}").
        let archive = try #require(result.archiveURL)
        let zipData = try Data(contentsOf: archive)
        #expect(zipData.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]))
        #expect(zipData.count > 1000)
    }

    @Test func scannerRulesMatchSyncAndRedactorFormats() {
        #expect(ExportSecretScanner.looksLikeSecret(FakeSecrets.openAIKey))
        #expect(ExportSecretScanner.looksLikeSecret(FakeSecrets.anthropicKey))
        #expect(ExportSecretScanner.looksLikeSecret("AIza" + String(repeating: "x", count: 35)))
        #expect(ExportSecretScanner.looksLikeSecret("ghp_" + String(repeating: "a", count: 36)))
        #expect(ExportSecretScanner.looksLikeSecret("-----BEGIN RSA PRIVATE KEY-----"))
        #expect(ExportSecretScanner.looksLikeSecret("Authorization: Bearer abcdefghijklmnopqrstuvwxyz"))
        #expect(ExportSecretScanner.looksLikeSecret("https://user:hunter2@example.com/repo.git"))
        #expect(!ExportSecretScanner.looksLikeSecret("Bitte den Export bauen"))
        #expect(!ExportSecretScanner.looksLikeSecret("git@github.com:example/regie.git"))
        #expect(ExportSecretScanner.isForbiddenKeyName("openAIApiKey"))
        #expect(ExportSecretScanner.isForbiddenKeyName("refresh_token"))
        #expect(!ExportSecretScanner.isForbiddenKeyName("idempotencyKey"))
        #expect(!ExportSecretScanner.isForbiddenKeyName("keychainReference"))
        let json = Data(#"{"a":[{"token":"x"}],"b":"sk-0123456789abcdefghij"}"#.utf8)
        #expect(ExportSecretScanner.findings(inJSON: json) == ["$.a[0].token", "$.b"])
    }

    /// Many entities are read in pages; progress is reported per page; every entity arrives once.
    @Test func largeDatasetIsExportedInPages() async throws {
        let database = try AppDatabase.onDiskForTests()
        let project = Project(name: "Groß", repositoryKind: .gitRepository, settingsId: ProjectSettingsID(), createdAt: t0)
        try await database.value.projects.create(project, settings: ProjectSettings(id: project.settingsId, updatedAt: t0), at: t0)
        let count = 1_200
        let body = String(repeating: "Lorem ipsum dolor sit amet. ", count: 40)
        for index in 0..<count {
            let item = WorkItem(projectId: project.id, type: .todo, title: "Aufgabe \(index)", originalNote: body, createdAt: at(Double(index)))
            try await database.value.workItems.insert(item, actor: .external, at: at(Double(index)))
        }
        let temp = try TemporaryDirectory()
        let reports = Mutex<[ExportProgress]>([])
        let result = try await DataExporter(database: database.value, options: options(pageSize: 100, markdown: false))
            .export(into: temp.url, at: t0) { progress in reports.withLock { $0.append(progress) } }

        #expect(result.manifest.count(of: .workItem) == count)
        // Inserting work items also writes events: everything is enumerated, nothing twice.
        let ids = try ExportReader.entities(WorkItem.self, of: .workItem, inExportFolder: result.folderURL).map(\.uuid)
        #expect(Set(ids).count == count)
        let progress = reports.withLock { $0 }
        let entityPages = progress.filter { $0.phase == .entities }
        #expect(entityPages.count >= (count + result.manifest.count(of: .taskEvent)) / 100)
        #expect(entityPages.map(\.exportedEntities) == entityPages.map(\.exportedEntities).sorted())
        #expect(entityPages.map(\.fractionCompleted) == entityPages.map(\.fractionCompleted).sorted())
        #expect(progress.last?.phase == .finished)
        #expect(progress.last?.fractionCompleted == 1)
    }

    @Test func cancellationRemovesPartialExport() async throws {
        let database = try AppDatabase.onDiskForTests()
        for index in 0..<300 {
            try await database.value.workItems.insert(WorkItem(type: .note, title: "N\(index)", createdAt: t0), actor: .external, at: t0)
        }
        let temp = try TemporaryDirectory()
        let exporter = DataExporter(database: database.value, options: options(pageSize: 10))
        let task = Task {
            try await exporter.export(into: temp.url, at: t0) { progress in
                if progress.pagesRead == 3 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.url.path).isEmpty)
    }

    @Test func audioRecordingsAreCopiedWhenRequested() async throws {
        let database = try AppDatabase.onDiskForTests()
        let seeded = try await database.seedAllEntityTypes()
        let audio = try TemporaryDirectory()
        try Data("RIFF-audio".utf8).write(to: audio.url.appendingPathComponent(seeded.audioNote.localAssetRef))
        let temp = try TemporaryDirectory()
        let result = try await DataExporter(database: database.value, options: options(audio: audio.url)).export(into: temp.url, at: t0)
        #expect(result.manifest.audioFiles == 1)
        let path = "audio/\(seeded.audioNote.id.uuidString.lowercased())-Diktat-1.m4a"
        #expect(result.manifest.files.contains { $0.path == path && $0.bytes == 10 })
        #expect(try Data(contentsOf: result.folderURL.appendingPathComponent(path)) == Data("RIFF-audio".utf8))
    }

    /// macOS UI process: export from a read-only connection while the Agent Service owns the writer (ADR-0019).
    @Test func exportWorksOnAReadOnlyDatabaseIncludingDeviceLocalValues() async throws {
        let database = try AppDatabase.onDiskForTests()
        let seeded = try await database.seedAllEntityTypes()
        let reader = try AppDatabase.openReadOnly(at: database.directory.url.appendingPathComponent("db.sqlite"))
        let temp = try TemporaryDirectory()
        let result = try await DataExporter(database: reader, options: options(pageSize: 3)).export(into: temp.url, at: t0)
        #expect(try ExportReader.entities(AudioNote.self, of: .audioNote, inExportFolder: result.folderURL) == [seeded.audioNote])
        let profiles = try ExportReader.entities(ProviderProfile.self, of: .providerProfile, inExportFolder: result.folderURL)
        #expect(Set(profiles.map(\.id)) == [seeded.deviceProfile.id, seeded.syncedProfile.id])
    }
}

/// On-disk database (WAL) to exercise the real pool, removed with the wrapper.
final class TestDatabase: @unchecked Sendable {
    let directory: TemporaryDirectory
    let value: AppDatabase

    init() throws {
        directory = try TemporaryDirectory()
        value = try AppDatabase.openWriter(at: directory.url.appendingPathComponent("db.sqlite"))
    }

    func seedAllEntityTypes() async throws -> Seeded { try await value.seedAllEntityTypes() }
}

extension AppDatabase {
    static func onDiskForTests() throws -> TestDatabase { try TestDatabase() }
}
