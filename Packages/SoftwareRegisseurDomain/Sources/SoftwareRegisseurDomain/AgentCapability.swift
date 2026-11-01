import Foundation

/// Where a capability fact came from (spec J1, J2a: documented or verified, never guessed).
public enum CapabilitySource: String, Hashable, Sendable, Codable, CaseIterable {
    case documentedCLI
    case appServer
    case sdk
    case verifiedSpike
    case cachedFromHost
}

public enum ModelAvailability: String, Hashable, Sendable, Codable, CaseIterable {
    case available
    /// Known to the installed version but not usable with the current account.
    case notEntitled
    case deprecated
    case unavailable
}

/// One model of one coding agent with the effort levels it supports (ADR-0006).
public struct AgentModelCapability: Hashable, Sendable, Codable {
    public let providerId: ProviderID
    public let modelId: ModelID
    public var displayName: String
    /// Explicit levels supported by this model. `auto` is always valid and need not be listed.
    public var supportedEffortIds: [EffortLevel]
    public var defaultEffortId: EffortLevel?
    public var availability: ModelAvailability
    public var source: CapabilitySource
    public var lastValidatedAt: Date

    public init(
        providerId: ProviderID,
        modelId: ModelID,
        displayName: String,
        supportedEffortIds: [EffortLevel],
        defaultEffortId: EffortLevel? = nil,
        availability: ModelAvailability = .available,
        source: CapabilitySource,
        lastValidatedAt: Date
    ) {
        self.providerId = providerId
        self.modelId = modelId
        self.displayName = displayName
        self.supportedEffortIds = supportedEffortIds
        self.defaultEffortId = defaultEffortId
        self.availability = availability
        self.source = source
        self.lastValidatedAt = lastValidatedAt
    }

    public func supports(_ effort: EffortLevel) -> Bool {
        effort.isAuto || supportedEffortIds.contains(effort)
    }
}

/// Capabilities of one installed coding agent on one host (spec J1, O).
public struct AgentCapability: Hashable, Sendable, Codable {
    /// UI text when the adapter cannot set effort reliably (spec J2a). Not a simulated selection.
    public static let effortNotAdjustableText = String(localized: "Anbieterstandard – nicht einstellbar", bundle: .module)

    public let providerId: ProviderID
    public var displayName: String
    public var hostId: HostID
    public var executablePath: String?
    public var appBundleId: String?
    public var version: String
    public var installed: Bool
    public var authenticated: Bool
    public var runnable: Bool
    /// Official remote/mobile control available (spec J5/J6).
    public var supportsRemote: Bool
    public var supportsAutomaticStart: Bool
    public var supportsResume: Bool
    public var supportsApprovals: Bool
    public var supportsModelSelection: Bool
    public var supportsEffortSelection: Bool
    public var modelCatalog: [AgentModelCapability]
    /// Model the agent uses when none is passed, if the adapter can determine it.
    public var defaultModelId: ModelID?
    public var capabilitySource: CapabilitySource
    /// Incremented by the host whenever the catalog/matrix changes (ADR-0006, A40).
    public var capabilityRevision: Int
    public var lastChecked: Date
    public var detectionTimestamp: Date
    public var sessionLinkFormat: String?
    public var diagnostic: String?

    public init(
        providerId: ProviderID,
        displayName: String,
        hostId: HostID,
        executablePath: String? = nil,
        appBundleId: String? = nil,
        version: String,
        installed: Bool = true,
        authenticated: Bool = true,
        runnable: Bool = true,
        supportsRemote: Bool = false,
        supportsAutomaticStart: Bool = true,
        supportsResume: Bool = false,
        supportsApprovals: Bool = false,
        supportsModelSelection: Bool,
        supportsEffortSelection: Bool,
        modelCatalog: [AgentModelCapability],
        defaultModelId: ModelID? = nil,
        capabilitySource: CapabilitySource,
        capabilityRevision: Int,
        lastChecked: Date,
        detectionTimestamp: Date? = nil,
        sessionLinkFormat: String? = nil,
        diagnostic: String? = nil
    ) {
        self.providerId = providerId
        self.displayName = displayName
        self.hostId = hostId
        self.executablePath = executablePath
        self.appBundleId = appBundleId
        self.version = version
        self.installed = installed
        self.authenticated = authenticated
        self.runnable = runnable
        self.supportsRemote = supportsRemote
        self.supportsAutomaticStart = supportsAutomaticStart
        self.supportsResume = supportsResume
        self.supportsApprovals = supportsApprovals
        self.supportsModelSelection = supportsModelSelection
        self.supportsEffortSelection = supportsEffortSelection
        self.modelCatalog = modelCatalog
        self.defaultModelId = defaultModelId
        self.capabilitySource = capabilitySource
        self.capabilityRevision = capabilityRevision
        self.lastChecked = lastChecked
        self.detectionTimestamp = detectionTimestamp ?? lastChecked
        self.sessionLinkFormat = sessionLinkFormat
        self.diagnostic = diagnostic
    }

    /// Only ready agents are selectable (spec J1, J2).
    public var isReady: Bool { installed && authenticated && runnable }

    public func model(_ id: ModelID) -> AgentModelCapability? {
        modelCatalog.first { $0.modelId == id }
    }

    /// Derived model × effort matrix (spec J1 `modelEffortMatrix`).
    public var modelEffortMatrix: [ModelID: [EffortLevel]] {
        Dictionary(modelCatalog.map { ($0.modelId, $0.supportedEffortIds) }, uniquingKeysWith: { first, _ in first })
    }

    /// Effort options the UI may enable for a model choice (A37). Always starts with `auto`.
    /// Without adapter support only `auto` is offered.
    public func selectableEfforts(for selection: ModelSelection) -> [EffortLevel] {
        guard supportsEffortSelection else { return [.auto] }
        let target = selection.modelID ?? defaultModelId
        guard let target, let model = model(target), model.availability == .available else { return [.auto] }
        return [.auto] + model.supportedEffortIds.filter { !$0.isAuto }
    }

    /// Hint shown next to the effort picker; nil when effort is adjustable.
    public var effortSelectionHint: String? {
        supportsEffortSelection ? nil : Self.effortNotAdjustableText
    }
}

/// Mac execution host with its last reported capabilities (spec N4, O).
public struct AgentHost: Hashable, Sendable, Codable, Identifiable {
    public let hostId: HostID
    public var name: String
    public var lastSeen: Date
    public var ready: Bool
    public var agentCapabilities: [AgentCapability]
    public var serviceVersion: String

    public var id: HostID { hostId }

    public init(hostId: HostID = HostID(), name: String, lastSeen: Date, ready: Bool, agentCapabilities: [AgentCapability] = [], serviceVersion: String) {
        self.hostId = hostId
        self.name = name
        self.lastSeen = lastSeen
        self.ready = ready
        self.agentCapabilities = agentCapabilities
        self.serviceVersion = serviceVersion
    }

    /// True if the last heartbeat is older than `threshold`; capabilities are then shown as
    /// „zuletzt erkannt – Mac derzeit offline“ (spec J1).
    public func isOffline(at now: Date, threshold: TimeInterval) -> Bool {
        now.timeIntervalSince(lastSeen) > threshold
    }

    public func capability(for provider: ProviderID) -> AgentCapability? {
        agentCapabilities.first { $0.providerId == provider }
    }
}
