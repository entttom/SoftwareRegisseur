import Foundation
@testable import SoftwareRegisseurDomain

/// Deterministic RNG for jitter tests.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func utc(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: string) else { fatalError("Bad test date \(string)") }
    return date
}

let referenceDate = utc("2026-10-30T12:00:00Z")

enum Fixtures {
    static let host = HostID()
    static let codexModel: ModelID = "gpt-5.5-codex"
    static let codexMini: ModelID = "gpt-5.5-mini"

    static func codexCapability(
        revision: Int = 1,
        version: String = "0.50.0",
        models: [AgentModelCapability]? = nil,
        supportsEffort: Bool = true,
        supportsModel: Bool = true,
        defaultModel: ModelID? = codexModel
    ) -> AgentCapability {
        AgentCapability(
            providerId: .codex,
            displayName: "OpenAI Codex",
            hostId: host,
            version: version,
            supportsModelSelection: supportsModel,
            supportsEffortSelection: supportsEffort,
            modelCatalog: models ?? [
                model(codexModel, efforts: [.low, .medium, .high, .xhigh]),
                model(codexMini, efforts: [.low, .medium]),
            ],
            defaultModelId: defaultModel,
            capabilitySource: .appServer,
            capabilityRevision: revision,
            lastChecked: referenceDate
        )
    }

    static func model(
        _ id: ModelID,
        provider: ProviderID = .codex,
        efforts: [EffortLevel],
        availability: ModelAvailability = .available
    ) -> AgentModelCapability {
        AgentModelCapability(
            providerId: provider,
            modelId: id,
            displayName: id.rawValue,
            supportedEffortIds: efforts,
            availability: availability,
            source: .appServer,
            lastValidatedAt: referenceDate
        )
    }

    static func claudeWithoutEffort() -> AgentCapability {
        AgentCapability(
            providerId: .claudeCode,
            displayName: "Claude Code",
            hostId: host,
            version: "2.1.0",
            supportsRemote: true,
            supportsModelSelection: true,
            supportsEffortSelection: false,
            modelCatalog: [model("sonnet", provider: .claudeCode, efforts: [])],
            defaultModelId: nil,
            capabilitySource: .documentedCLI,
            capabilityRevision: 3,
            lastChecked: referenceDate
        )
    }

    static func global(_ model: ModelSelection? = nil, _ effort: EffortLevel? = nil, provider: ProviderID = .codex) -> AgentModelPreference {
        AgentModelPreference(scope: .global, providerId: provider, model: model, effort: effort, updatedAt: referenceDate)
    }

    static func project(_ model: ModelSelection? = nil, _ effort: EffortLevel? = nil, provider: ProviderID = .codex, inherits: Bool = false) -> AgentModelPreference {
        AgentModelPreference(scope: .project(ProjectID()), providerId: provider, model: model, effort: effort, inheritsDefault: inherits, updatedAt: referenceDate)
    }

    static func job(
        snapshot: ConfigurationSnapshot,
        schedule: JobSchedule = JobSchedule(kind: .immediate),
        before: WorkItemStatus = .open
    ) -> AgentJob {
        AgentJob(
            idempotencyKey: IdempotencyKey(),
            projectId: ProjectID(),
            workItemId: WorkItemID(),
            hostId: host,
            configSnapshot: snapshot,
            schedule: schedule,
            workItemStatusBeforeJob: before,
            createdAt: referenceDate
        )
    }

    static func resolvedSnapshot(
        jobOverride: JobConfigurationOverride? = nil,
        capability: AgentCapability = codexCapability()
    ) throws -> ConfigurationSnapshot {
        let resolution = ModelEffortResolver.resolve(
            jobOverride: jobOverride,
            projectPreference: nil,
            globalPreference: nil,
            capability: capability
        )
        guard let configuration = resolution.configuration else {
            throw FixtureError.unresolved(resolution.issues)
        }
        return configuration.makeSnapshot(createdAt: referenceDate)
    }

    enum FixtureError: Error { case unresolved([ConfigurationIssue]) }
}

func roundTrip<T: Codable>(_ value: T) throws -> T {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(T.self, from: encoder.encode(value))
}

func jsonString<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}
