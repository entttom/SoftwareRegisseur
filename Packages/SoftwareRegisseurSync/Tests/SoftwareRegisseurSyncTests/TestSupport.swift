import CloudKit
import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence
import SoftwareRegisseurSync
import SoftwareRegisseurSyncTesting
import Synchronization
import Testing

let t0 = Date(timeIntervalSinceReferenceDate: 815_000_000)

/// Shared, manually advanced clock for coordinators (retry-after tests).
final class TestClock: Sendable {
    private let current = Mutex(t0)

    var now: Date { current.withLock { $0 } }

    func advance(by seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

final class EngineBox: Sendable {
    private let engine = Mutex<FakeSyncEngine?>(nil)
    var value: FakeSyncEngine? { engine.withLock { $0 } }
    func set(_ value: FakeSyncEngine) { engine.withLock { $0 = value } }
}

/// One simulated device: its own in-memory `AppDatabase`, network/account and coordinator.
struct SimulatedDevice {
    let name: String
    let deviceId: DeviceID
    let database: AppDatabase
    let connection: FakeDeviceConnection
    let coordinator: SyncCoordinator
    let engine: EngineBox

    var actor: EventActor { .user(deviceId) }

    static func make(
        _ name: String, role: DeviceRole, server: FakeCloudDatabase, clock: TestClock = TestClock(),
        user: String = "_user-A", batchSize: Int = SyncRecordSchema.maxRecordsPerBatch,
        outboxScanLimit: Int = 5_000,
        wrapStore: (@Sendable (GRDBSyncStore) -> any SyncStore)? = nil,
        serverForUser: (@Sendable (String?) -> FakeCloudDatabase)? = nil
    ) async throws -> SimulatedDevice {
        let deviceId = DeviceID()
        let database = try AppDatabase.inMemory()
        let connection = FakeDeviceConnection(userRecordName: user)
        let box = EngineBox()
        let coordinator = SyncCoordinator(
            store: wrapStore?(database.sync) ?? database.sync,
            configuration: SyncConfiguration(
                deviceId: deviceId, role: role, batchSize: batchSize, outboxScanLimit: outboxScanLimit,
                assetDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("SyncTests-\(name)-\(UUID().uuidString)")
            ),
            now: { clock.now },
            engineFactory: { setup in
                let target = serverForUser?(connection.userRecordName) ?? server
                let engine = try FakeSyncEngine(setup: setup, server: target, connection: connection)
                box.set(engine)
                return engine
            }
        )
        try await coordinator.start()
        return SimulatedDevice(name: name, deviceId: deviceId, database: database, connection: connection,
                               coordinator: coordinator, engine: box)
    }

    @discardableResult
    func sync(_ reason: SyncReason = .manual, sourceLocation: SourceLocation = #_sourceLocation) async throws -> SyncRunReport {
        let result = await coordinator.syncNow(reason: reason)
        guard let report = result.report else {
            Issue.record("\(name): sync did not complete: \(result)", sourceLocation: sourceLocation)
            throw TestFailure()
        }
        return report
    }

    func status() async -> SyncStatus { await coordinator.status }
}

struct TestFailure: Error {}

enum Fixture {
    static let host = HostID()

    static func project(name: String = "Regie") -> (Project, ProjectSettings) {
        let settings = ProjectSettings(updatedAt: t0)
        let project = Project(
            name: name, repositoryIdentity: RepositoryIdentity(rawValue: "git:\(UUID().uuidString)"), repositoryKind: .gitRepository,
            remote: "git@github.com:example/regie.git", hostId: host, settingsId: settings.id, createdAt: t0
        )
        return (project, settings)
    }

    static func workItem(projectId: ProjectID?, title: String = "Neue Funktion", body: String? = nil) -> WorkItem {
        WorkItem(
            projectId: projectId, type: .feature, title: title, originalNote: "Notiz: \(title)",
            structuredBody: body ?? "## Ziel\n\(title)", status: .open, priority: .medium, labels: [], createdAt: t0
        )
    }

    static func snapshot() -> ConfigurationSnapshot {
        ConfigurationSnapshot(
            providerId: .codex,
            requestedModel: .model("gpt-5.5-codex"),
            requestedEffort: .high,
            resolvedModel: .model("gpt-5.5-codex"),
            resolvedEffort: .high,
            profileSource: ProfileSources(model: .job, effort: .project),
            capabilityRevision: 3,
            agentVersion: "0.50.0",
            createdAt: t0
        )
    }

    static func job(for item: WorkItem) -> AgentJob {
        AgentJob(
            idempotencyKey: IdempotencyKey(), projectId: item.projectId!, workItemId: item.uuid, hostId: host,
            configSnapshot: snapshot(), schedule: JobSchedule(kind: .immediate), priority: .high,
            workItemStatusBeforeJob: item.status, createdAt: t0.addingTimeInterval(1)
        )
    }
}

/// Payloads in the canonical format owned by Persistence.
func payload<T: Encodable>(_ value: T) throws -> Data {
    try SyncPayloadCodec.encode(value)
}

func decode<T: Decodable>(_ type: T.Type, _ data: Data?) throws -> T {
    try SyncPayloadCodec.decode(type, from: try #require(data))
}
