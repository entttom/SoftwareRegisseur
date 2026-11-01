import Foundation

public enum PreferenceScope: Hashable, Sendable, Codable {
    case global
    case project(ProjectID)
}

/// Stored model/effort preference for one agent at global or project scope (ADR-0006, spec O).
///
/// A `nil` field inherits from the next lower-precedence level; `inheritsDefault == true` ignores the
/// whole preference. To pin the provider default explicitly use `.providerDefault` / `.auto`.
public struct AgentModelPreference: Hashable, Sendable, Codable {
    public var scope: PreferenceScope
    public let providerId: ProviderID
    public var model: ModelSelection?
    public var effort: EffortLevel?
    public var inheritsDefault: Bool
    public var updatedAt: Date

    public init(
        scope: PreferenceScope,
        providerId: ProviderID,
        model: ModelSelection? = nil,
        effort: EffortLevel? = nil,
        inheritsDefault: Bool = false,
        updatedAt: Date
    ) {
        self.scope = scope
        self.providerId = providerId
        self.model = model
        self.effort = effort
        self.inheritsDefault = inheritsDefault
        self.updatedAt = updatedAt
    }

    public var modelId: ModelID? { model?.modelID }
    public var effortId: EffortLevel? { effort }
}

/// Per-job override chosen when starting/scheduling a request; never changes stored preferences.
public struct JobConfigurationOverride: Hashable, Sendable, Codable {
    public let providerId: ProviderID
    public var model: ModelSelection?
    public var effort: EffortLevel?

    public init(providerId: ProviderID, model: ModelSelection? = nil, effort: EffortLevel? = nil) {
        self.providerId = providerId
        self.model = model
        self.effort = effort
    }
}

public enum ProfileSource: String, Hashable, Sendable, Codable, CaseIterable {
    case job
    case project
    case global
    case providerDefault
}

/// Which level supplied the model and which supplied the effort (recorded separately).
public struct ProfileSources: Hashable, Sendable, Codable {
    public let model: ProfileSource
    public let effort: ProfileSource

    public init(model: ProfileSource, effort: ProfileSource) {
        self.model = model
        self.effort = effort
    }
}

/// Why a configuration cannot run as requested. Never resolved by a silent fallback (ADR-0006).
public enum ConfigurationIssue: Hashable, Sendable, Codable {
    case providerMismatch(expected: ProviderID, found: ProviderID)
    case preferenceScopeMismatch(expected: ProfileSource)
    case modelSelectionNotSupported(ModelID)
    case unknownModel(ModelID)
    case modelUnavailable(ModelID, ModelAvailability)
    case effortSelectionNotSupported(EffortLevel)
    case effortNotSupportedByModel(effort: EffortLevel, model: ModelID)
    /// Explicit effort with provider-default model whose identity the adapter cannot report.
    case effortRequiresKnownModel(EffortLevel)

    public var germanDescription: String {
        switch self {
        case let .providerMismatch(expected, found):
            String(localized: "Einstellung gehört zu Agent „\(found)“, erwartet „\(expected)“.", bundle: .module)
        case let .preferenceScopeMismatch(expected):
            String(localized: "Voreinstellung hat nicht den erwarteten Geltungsbereich (\(expected.rawValue)).", bundle: .module)
        case let .modelSelectionNotSupported(model):
            String(localized: "Der Agent erlaubt keine Modellwahl; „\(model)“ kann nicht gesetzt werden.", bundle: .module)
        case let .unknownModel(model):
            String(localized: "Modell „\(model)“ ist in der installierten Agentenversion nicht verfügbar.", bundle: .module)
        case let .modelUnavailable(model, availability):
            String(localized: "Modell „\(model)“ ist derzeit nicht nutzbar (\(availability.rawValue)).", bundle: .module)
        case let .effortSelectionNotSupported(effort):
            String(localized: "Stufe „\(effort.germanDisplayName)“ nicht einstellbar: \(AgentCapability.effortNotAdjustableText).", bundle: .module)
        case let .effortNotSupportedByModel(effort, model):
            String(localized: "Modell „\(model)“ unterstützt die Stufe „\(effort.germanDisplayName)“ nicht.", bundle: .module)
        case let .effortRequiresKnownModel(effort):
            String(localized: "Stufe „\(effort.germanDisplayName)“ erfordert ein ausdrücklich gewähltes Modell.", bundle: .module)
        }
    }
}

/// Result of resolving the precedence chain against the current capability.
public struct ResolvedAgentConfiguration: Hashable, Sendable, Codable {
    public let providerId: ProviderID
    /// Job-level request; nil = not overridden for this job.
    public let requestedModel: ModelSelection?
    public let requestedEffort: EffortLevel?
    public let resolvedModel: ModelSelection
    public let resolvedEffort: EffortLevel
    public let profileSource: ProfileSources
    public let capabilityRevision: Int
    public let agentVersion: String
    public let effortAdjustable: Bool

    public var effortDisplayText: String {
        effortAdjustable ? resolvedEffort.germanDisplayName : AgentCapability.effortNotAdjustableText
    }

    public func makeSnapshot(createdAt: Date) -> ConfigurationSnapshot {
        ConfigurationSnapshot(
            providerId: providerId,
            requestedModel: requestedModel,
            requestedEffort: requestedEffort,
            resolvedModel: resolvedModel,
            resolvedEffort: resolvedEffort,
            profileSource: profileSource,
            capabilityRevision: capabilityRevision,
            agentVersion: agentVersion,
            createdAt: createdAt
        )
    }
}

public enum ModelEffortResolution: Hashable, Sendable {
    case resolved(ResolvedAgentConfiguration)
    case needsConfiguration([ConfigurationIssue])

    public var configuration: ResolvedAgentConfiguration? {
        if case let .resolved(configuration) = self { return configuration }
        return nil
    }

    public var issues: [ConfigurationIssue] {
        if case let .needsConfiguration(issues) = self { return issues }
        return []
    }
}

/// Immutable model/effort snapshot bound to a job at creation (spec J2a, A39). Later preference changes
/// never alter it; only an explicit `AgentJob.replaceConfiguration` swaps it before start.
public struct ConfigurationSnapshot: Hashable, Sendable, Codable {
    public let providerId: ProviderID
    public let requestedModel: ModelSelection?
    public let requestedEffort: EffortLevel?
    public let resolvedModel: ModelSelection
    public let resolvedEffort: EffortLevel
    public let profileSource: ProfileSources
    public let capabilityRevision: Int
    public let agentVersion: String
    public let createdAt: Date

    public init(
        providerId: ProviderID,
        requestedModel: ModelSelection?,
        requestedEffort: EffortLevel?,
        resolvedModel: ModelSelection,
        resolvedEffort: EffortLevel,
        profileSource: ProfileSources,
        capabilityRevision: Int,
        agentVersion: String,
        createdAt: Date
    ) {
        self.providerId = providerId
        self.requestedModel = requestedModel
        self.requestedEffort = requestedEffort
        self.resolvedModel = resolvedModel
        self.resolvedEffort = resolvedEffort
        self.profileSource = profileSource
        self.capabilityRevision = capabilityRevision
        self.agentVersion = agentVersion
        self.createdAt = createdAt
    }
}

public enum SnapshotRevalidation: Hashable, Sendable {
    case ok
    case needsConfiguration([ConfigurationIssue])

    public var isOK: Bool { self == .ok }
}

/// Resolves Job > Project > Global > provider default (`auto`) separately for model and effort and
/// validates the result against the agent capability (ADR-0006). Invalid values are reported, never
/// replaced.
public enum ModelEffortResolver {
    public static func resolve(
        jobOverride: JobConfigurationOverride?,
        projectPreference: AgentModelPreference?,
        globalPreference: AgentModelPreference?,
        capability: AgentCapability
    ) -> ModelEffortResolution {
        let provider = capability.providerId
        var issues: [ConfigurationIssue] = []

        if let jobOverride, jobOverride.providerId != provider {
            issues.append(.providerMismatch(expected: provider, found: jobOverride.providerId))
        }
        for (preference, expected) in [(projectPreference, ProfileSource.project), (globalPreference, .global)] {
            guard let preference else { continue }
            if preference.providerId != provider {
                issues.append(.providerMismatch(expected: provider, found: preference.providerId))
            }
            switch (preference.scope, expected) {
            case (.project, .project), (.global, .global): break
            default: issues.append(.preferenceScopeMismatch(expected: expected))
            }
        }
        guard issues.isEmpty else { return .needsConfiguration(issues) }

        let project = projectPreference.flatMap { $0.inheritsDefault ? nil : $0 }
        let global = globalPreference.flatMap { $0.inheritsDefault ? nil : $0 }

        let (model, modelSource): (ModelSelection, ProfileSource) =
            if let value = jobOverride?.model { (value, .job) }
            else if let value = project?.model { (value, .project) }
            else if let value = global?.model { (value, .global) }
            else { (.providerDefault, .providerDefault) }

        let (effort, effortSource): (EffortLevel, ProfileSource) =
            if let value = jobOverride?.effort { (value, .job) }
            else if let value = project?.effort { (value, .project) }
            else if let value = global?.effort { (value, .global) }
            else { (.auto, .providerDefault) }

        issues = validate(model: model, effort: effort, against: capability)
        guard issues.isEmpty else { return .needsConfiguration(issues) }

        return .resolved(ResolvedAgentConfiguration(
            providerId: provider,
            requestedModel: jobOverride?.model,
            requestedEffort: jobOverride?.effort,
            resolvedModel: model,
            resolvedEffort: effort,
            profileSource: ProfileSources(model: modelSource, effort: effortSource),
            capabilityRevision: capability.capabilityRevision,
            agentVersion: capability.version,
            effortAdjustable: capability.supportsEffortSelection
        ))
    }

    /// Checks one concrete model/effort pair. `auto` effort and provider-default model are always valid.
    public static func validate(model: ModelSelection, effort: EffortLevel, against capability: AgentCapability) -> [ConfigurationIssue] {
        var issues: [ConfigurationIssue] = []
        var modelCapability: AgentModelCapability?

        if let modelID = model.modelID {
            modelCapability = capability.model(modelID)
            if !capability.supportsModelSelection {
                issues.append(.modelSelectionNotSupported(modelID))
            } else if let modelCapability {
                if modelCapability.availability != .available {
                    issues.append(.modelUnavailable(modelID, modelCapability.availability))
                }
            } else {
                issues.append(.unknownModel(modelID))
            }
        } else if let defaultModel = capability.defaultModelId {
            modelCapability = capability.model(defaultModel)
        }

        if !effort.isAuto {
            if !capability.supportsEffortSelection {
                issues.append(.effortSelectionNotSupported(effort))
            } else if let modelCapability {
                if !modelCapability.supports(effort) {
                    issues.append(.effortNotSupportedByModel(effort: effort, model: modelCapability.modelId))
                }
            } else if model.modelID == nil {
                issues.append(.effortRequiresKnownModel(effort))
            }
            // Unknown explicit model: already reported, effort cannot be judged.
        }
        return issues
    }

    /// Re-checks a stored snapshot before start (spec J3, A39/A40). Never mutates or replaces it.
    public static func revalidate(_ snapshot: ConfigurationSnapshot, against capability: AgentCapability) -> SnapshotRevalidation {
        guard snapshot.providerId == capability.providerId else {
            return .needsConfiguration([.providerMismatch(expected: snapshot.providerId, found: capability.providerId)])
        }
        let issues = validate(model: snapshot.resolvedModel, effort: snapshot.resolvedEffort, against: capability)
        return issues.isEmpty ? .ok : .needsConfiguration(issues)
    }
}
