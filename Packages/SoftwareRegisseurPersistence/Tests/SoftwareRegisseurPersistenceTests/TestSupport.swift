import Foundation
import GRDB
import SoftwareRegisseurDomain
@testable import SoftwareRegisseurPersistence

/// Fractional seconds on purpose: dates must round-trip exactly.
let t0 = Date(timeIntervalSinceReferenceDate: 815_000_000.123_456_789)

func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

let deviceActor = EventActor.user(DeviceID())

struct TestFailure: Error {}

/// Temporary on-disk database location, removed on deinit.
final class TemporaryDirectory: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoftwareRegisseurPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var databaseURL: URL { url.appendingPathComponent("db.sqlite") }

    deinit { try? FileManager.default.removeItem(at: url) }
}

enum Fixture {
    static let host = HostID()

    static func project(name: String = "Regie", projectWideLock: Bool = false) -> (Project, ProjectSettings) {
        let settings = ProjectSettings(projectWideLock: projectWideLock, updatedAt: t0)
        let project = Project(
            name: name, repositoryIdentity: RepositoryIdentity(rawValue: "git:\(UUID().uuidString)"), repositoryKind: .gitRepository,
            remote: "git@github.com:example/regie.git", hostId: host, settingsId: settings.id, createdAt: t0
        )
        return (project, settings)
    }

    static func workItem(
        projectId: ProjectID?, type: WorkItemType = .feature, title: String = "Neue Funktion",
        status: WorkItemStatus = .open, priority: Priority = .medium, labels: [String] = []
    ) -> WorkItem {
        WorkItem(
            projectId: projectId, type: type, title: title, originalNote: "Notiz: \(title)",
            structuredBody: "## Ziel\n\(title)", status: status, priority: priority, labels: labels, createdAt: t0
        )
    }

    static func snapshot(provider: ProviderID = .codex) -> ConfigurationSnapshot {
        ConfigurationSnapshot(
            providerId: provider,
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

    static func job(for item: WorkItem, key: IdempotencyKey = IdempotencyKey(), schedule: JobSchedule = JobSchedule(kind: .immediate)) -> AgentJob {
        AgentJob(
            idempotencyKey: key, projectId: item.projectId!, workItemId: item.uuid, hostId: host,
            configSnapshot: snapshot(), schedule: schedule, priority: .high,
            workItemStatusBeforeJob: item.status, createdAt: at(1)
        )
    }

    static func capability(hostId: HostID = host, revision: Int = 1, efforts: [EffortLevel] = [.low, .medium, .high, "ultra"]) -> AgentCapability {
        AgentCapability(
            providerId: .codex, displayName: "OpenAI Codex", hostId: hostId, executablePath: "/opt/homebrew/bin/codex",
            version: "0.50.0", supportsRemote: true, supportsResume: true, supportsModelSelection: true,
            supportsEffortSelection: true,
            modelCatalog: [
                AgentModelCapability(providerId: .codex, modelId: "gpt-5.5-codex", displayName: "GPT-5.5 Codex",
                                     supportedEffortIds: efforts, defaultEffortId: .medium, source: .appServer, lastValidatedAt: t0),
                AgentModelCapability(providerId: .codex, modelId: "Modell mit Ümlaut / spaces", displayName: "Exotic",
                                     supportedEffortIds: [], availability: .notEntitled, source: .documentedCLI, lastValidatedAt: at(5)),
            ],
            defaultModelId: "gpt-5.5-codex", capabilitySource: .appServer, capabilityRevision: revision,
            lastChecked: t0, detectionTimestamp: at(-10), sessionLinkFormat: "codex://session/{id}", diagnostic: "ok"
        )
    }
}

extension AppDatabase {
    /// Creates a project plus a work item and returns both.
    func seedItem(
        type: WorkItemType = .feature, status: WorkItemStatus = .open, projectWideLock: Bool = false
    ) async throws -> (Project, WorkItem) {
        let (project, settings) = Fixture.project(projectWideLock: projectWideLock)
        try await projects.create(project, settings: settings, at: t0)
        let item = Fixture.workItem(projectId: project.id, type: type, status: status)
        try await workItems.insert(item, actor: deviceActor, at: t0)
        return (project, item)
    }

    func count(_ table: String, _ condition: String = "1") throws -> Int {
        try reader.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table) WHERE \(condition)") ?? 0 }
    }

    func outbox() throws -> [(type: String, id: String, kind: String, version: Int)] {
        try reader.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM sync_outbox ORDER BY created_at, rowid").map {
                ($0["entity_type"], $0["entity_id"], $0["change_kind"], $0["version"])
            }
        }
    }
}
