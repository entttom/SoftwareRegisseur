import Foundation
import Synchronization
import SoftwareRegisseurAI
import SoftwareRegisseurAppCore
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

let now = Date(timeIntervalSince1970: 1_793_354_400) // 2026-10-30 10:00 UTC
let actor = EventActor.user(DeviceID())
let hostID = HostID()

enum Fixture {
    static func project(hostId: HostID? = hostID) -> (Project, ProjectSettings) {
        let settings = ProjectSettings(updatedAt: now)
        let project = Project(name: "Regie", repositoryKind: .gitRepository, hostId: hostId, status: .ready,
                              settingsId: settings.id, createdAt: now)
        return (project, settings)
    }

    static func item(projectId: ProjectID?, title: String = "Export als PDF", status: WorkItemStatus = .open,
                     type: WorkItemType = .feature, priority: Priority = .medium, labels: [String] = []) -> WorkItem {
        WorkItem(projectId: projectId, type: type, title: title, originalNote: "Notiz: \(title)",
                 structuredBody: "Ziel: \(title)", status: status, priority: priority, labels: labels, createdAt: now)
    }

    /// Codex-like agent: model choice and effort choice supported; one model without `xhigh`.
    static func codex(ready: Bool = true, effortAdjustable: Bool = true, revision: Int = 4) -> AgentCapability {
        AgentCapability(
            providerId: .codex, displayName: "Codex", hostId: hostID, version: "0.60.0",
            installed: true, authenticated: ready, runnable: ready,
            supportsModelSelection: true, supportsEffortSelection: effortAdjustable,
            modelCatalog: [
                AgentModelCapability(providerId: .codex, modelId: "gpt-5.5-codex", displayName: "GPT-5.5 Codex",
                                     supportedEffortIds: [.low, .medium, .high, .xhigh], source: .appServer, lastValidatedAt: now),
                AgentModelCapability(providerId: .codex, modelId: "gpt-5.5-mini", displayName: "GPT-5.5 mini",
                                     supportedEffortIds: [.low, .medium], source: .appServer, lastValidatedAt: now),
                AgentModelCapability(providerId: .codex, modelId: "gpt-old", displayName: "Alt",
                                     supportedEffortIds: [.low], availability: .deprecated, source: .appServer, lastValidatedAt: now),
            ],
            defaultModelId: "gpt-5.5-codex",
            capabilitySource: .appServer, capabilityRevision: revision, lastChecked: now
        )
    }

    static func makeDatabase() async throws -> (AppDatabase, Project, WorkItem) {
        let database = try AppDatabase.inMemory()
        let (project, settings) = project()
        try await database.projects.create(project, settings: settings, at: now)
        let item = item(projectId: project.id)
        try await database.workItems.insert(item, actor: actor, at: now)
        return (database, project, item)
    }
}

/// Permission authorizer whose answers are scripted; counts system prompts.
final class FakeAuthorizer: PermissionAuthorizing {
    private let state: Mutex<(statuses: [PermissionKind: PermissionStatus], answers: [PermissionKind: PermissionStatus], requests: [PermissionKind])>

    init(statuses: [PermissionKind: PermissionStatus], answers: [PermissionKind: PermissionStatus] = [:]) {
        state = Mutex((statuses, answers, []))
    }

    var requests: [PermissionKind] { state.withLock { $0.requests } }

    func status(of kind: PermissionKind) -> PermissionStatus {
        state.withLock { $0.statuses[kind] ?? .notDetermined }
    }

    func request(_ kind: PermissionKind) async -> PermissionStatus {
        state.withLock { state in
            state.requests.append(kind)
            let answer = state.answers[kind] ?? .denied
            state.statuses[kind] = answer
            return answer
        }
    }
}

/// Text provider returning canned JSON; never touches the network.
final class StubTextProvider: TextAIProvider {
    let providerID: SoftwareRegisseurAI.AIProviderID = .anthropic
    private let outputs: Mutex<[String]>
    private let count = Mutex(0)

    init(outputs: [String]) {
        self.outputs = Mutex(outputs)
    }

    var requestCount: Int { count.withLock { $0 } }

    func listModels() async throws -> [AIModelInfo] { [] }
    func validateAPIKey() async throws -> KeyValidationResult { .valid }

    func generate(_ request: TextGenerationRequest) async throws -> TextGenerationResult {
        count.withLock { $0 += 1 }
        let text = outputs.withLock { $0.isEmpty ? "" : $0.removeFirst() }
        return TextGenerationResult(provider: providerID, model: request.model, text: text, finishReason: .completed,
                                    usage: AIUsage(inputTokens: 120, outputTokens: 40))
    }
}

/// Transcription provider that records calls.
final class StubTranscriptionProvider: TranscriptionProvider {
    let providerID: SoftwareRegisseurAI.AIProviderID = .openai
    let maxUploadBytes = 25_000_000
    let supportedFormats: Set<AudioFormat> = Set(AudioFormat.allCases)
    private let calls = Mutex(0)

    var callCount: Int { calls.withLock { $0 } }

    func listModels() async throws -> [AIModelInfo] { [] }
    func validateAPIKey() async throws -> KeyValidationResult { .valid }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        calls.withLock { $0 += 1 }
        return TranscriptionResult(provider: providerID, model: request.model, text: "Hallo Welt", detectedLanguages: ["de"],
                                   usage: AIUsage(audioSeconds: 3))
    }
}

struct NoSegmenter: AudioSegmenter {
    func split(_ audio: URL, plan: TranscriptionChunkPlan) async throws -> [AudioPayload] { [] }
}

let headings = DraftBodyHeadings(goal: "Ziel", context: "Kontext", acceptanceCriteria: "Akzeptanzkriterien",
                                 technicalNotes: "Technische Hinweise", testCases: "Testfälle",
                                 dependencies: "Abhängigkeiten", openQuestions: "Offene Fragen")
