import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurProcess

/// One coding-agent adapter (spec J1, ADR-0005, ADR-0021). New agents (Cursor, Gemini CLI, …) add a
/// conforming type and register it in `AgentProviderRegistry`.
public protocol AgentProvider: Sendable {
    var providerId: ProviderID { get }
    var displayName: String { get }
    /// Only adapters with a complete detect/start/stream/approve/cancel path may report `runnable`
    /// (spec J1: „nur vollständig unterstützte … Adapter als einsatzbereit“).
    var isFullyImplemented: Bool { get }

    /// Non-invasive detection plus runtime catalog refresh (spec J1, J2a). Never throws: problems end
    /// up in diagnostics and in `capability.runnable == false`. `previous` keeps the revision stable
    /// when nothing changed (A40).
    func detect(previous: AgentCapability?) async -> AgentDetectionReport

    /// Refreshes the capability and re-validates the job snapshot against it (spec J3). Only a
    /// `.ready` plan can start a session; mismatches are reported, never silently replaced.
    func prepareLaunch(snapshot: ConfigurationSnapshot, previous: AgentCapability?) async -> LaunchPreparation

    /// Starts the agent in the prepared worktree. Events arrive on `AgentSession.events`.
    func startSession(plan: AgentLaunchPlan, request: AgentSessionRequest) async throws -> any AgentSession
}

extension AgentProvider {
    /// Alias used by schedulers: refresh before each job start, on upgrade and account change (J2a).
    public func refreshCatalog(previous: AgentCapability?) async -> AgentDetectionReport {
        await detect(previous: previous)
    }
}

/// A running agent session.
public protocol AgentSession: Sendable {
    var providerId: ProviderID { get }
    var jobId: JobID { get }
    /// Single-consumer stream; `.finished` is always the last element.
    var events: AsyncStream<AgentSessionEvent> { get }
    /// Forwards a user decision. Throws if the request is unknown or already answered.
    func respond(to request: ApprovalRequestID, with decision: AgentApprovalDecision) async throws
    /// Interrupts the turn and stops the process; ends with `.finished(.cancelled)`.
    func cancel() async
    /// PID of the agent process, if the adapter spawned one (crash recovery, lock liveness, spec L1).
    var processIdentifier: Int32? { get async }
    /// Process group of the agent (adapters spawn each agent in its own group, so it equals the PID).
    /// Children such as test runs belong to it; liveness checks use the group instead of a cwd scan.
    var processGroupIdentifier: Int32? { get async }
}

extension AgentSession {
    public var processIdentifier: Int32? { get async { nil } }
    public var processGroupIdentifier: Int32? { get async { await processIdentifier } }
}

public struct AgentSessionRequest: Sendable, Hashable {
    public let jobId: JobID
    /// Worktree created by Software Regisseur (spec L2); never an agent-managed worktree.
    public let workingDirectory: URL
    /// Fully built prompt (see `AgentPromptBuilder`).
    public let prompt: String
    /// Local session UUID (Claude `--session-id`). Defaults to the job UUID (ADR-0021); a retry of the
    /// same job must pass a fresh UUID because Claude rejects reused session IDs.
    public let sessionUUID: UUID

    public init(jobId: JobID, workingDirectory: URL, prompt: String, sessionUUID: UUID? = nil) {
        self.jobId = jobId
        self.workingDirectory = workingDirectory
        self.prompt = prompt
        self.sessionUUID = sessionUUID ?? jobId.rawValue
    }
}

public enum AgentDiagnosticSeverity: String, Hashable, Sendable, Codable {
    case info
    case warning
    /// Prevents `runnable`.
    case blocking
}

public struct AgentDiagnostic: Hashable, Sendable, Codable {
    public let code: String
    public let severity: AgentDiagnosticSeverity
    /// German, user-facing, free of secrets.
    public let message: String

    public init(code: String, severity: AgentDiagnosticSeverity, message: String) {
        self.code = code
        self.severity = severity
        self.message = message
    }
}

/// Resolved executable plus the explicit child environment used for every invocation.
public struct AgentToolchain: Sendable, Hashable {
    public let executableURL: URL
    public let environment: ProcessEnvironment
    public let version: SemanticVersion?

    public init(executableURL: URL, environment: ProcessEnvironment, version: SemanticVersion?) {
        self.executableURL = executableURL
        self.environment = environment
        self.version = version
    }
}

public struct AgentDetectionReport: Sendable, Hashable {
    public let capability: AgentCapability
    public let diagnostics: [AgentDiagnostic]
    /// Present when an executable was found (even if not runnable).
    public let toolchain: AgentToolchain?
    /// Alias → provider-resolved model name (Claude `models[].resolvedModel`). `AgentModelCapability`
    /// has no field for it.
    public let modelResolutions: [ModelID: String]

    public init(capability: AgentCapability, diagnostics: [AgentDiagnostic], toolchain: AgentToolchain?,
                modelResolutions: [ModelID: String] = [:]) {
        self.capability = capability
        self.diagnostics = diagnostics
        self.toolchain = toolchain
        self.modelResolutions = modelResolutions
    }
}

/// Validated, concrete start parameters. Adapters create it after `LaunchValidator` passed; the
/// initializer is public so adapters in other modules (and test doubles) can return `.ready` plans.
public struct AgentLaunchPlan: Sendable, Hashable {
    public let providerId: ProviderID
    public let snapshot: ConfigurationSnapshot
    /// Freshly refreshed capability the snapshot was validated against.
    public let capability: AgentCapability
    /// Model passed to the agent; `nil` = flag omitted (provider default).
    public let modelArgument: ModelID?
    /// Effort passed to the agent; `nil` = omitted (provider/model default).
    public let effortArgument: EffortLevel?
    /// Provider-resolved name of `modelArgument` if it is an alias (Claude `models[].resolvedModel`),
    /// used to compare the effective model reported by the agent.
    public let resolvedModelName: String?
    public let toolchain: AgentToolchain

    public init(
        providerId: ProviderID, snapshot: ConfigurationSnapshot, capability: AgentCapability,
        modelArgument: ModelID?, effortArgument: EffortLevel?, resolvedModelName: String? = nil,
        toolchain: AgentToolchain
    ) {
        self.providerId = providerId
        self.snapshot = snapshot
        self.capability = capability
        self.modelArgument = modelArgument
        self.effortArgument = effortArgument
        self.resolvedModelName = resolvedModelName
        self.toolchain = toolchain
    }
}

public enum LaunchPreparation: Sendable, Hashable {
    case ready(AgentLaunchPlan)
    /// Snapshot no longer valid → job `needs_configuration` (ADR-0006, ADR-0012).
    case needsConfiguration([ConfigurationIssue], capability: AgentCapability)
    /// Agent not installed/authenticated/supported → job stays queued or fails; nothing started.
    case notRunnable(reason: String, capability: AgentCapability)

    public var plan: AgentLaunchPlan? {
        if case let .ready(plan) = self { return plan }
        return nil
    }

    public var suggestedJobState: AgentJobState? {
        switch self {
        case .ready: nil
        case .needsConfiguration: .needsConfiguration
        case .notRunnable: nil
        }
    }
}

public enum AgentSessionError: Error, Hashable, Sendable, CustomStringConvertible {
    case unknownApprovalRequest(ApprovalRequestID)
    case decisionNotSupported(AgentApprovalDecision)
    case sessionFinished
    case invalidWorkingDirectory(String)
    case providerMismatch(expected: ProviderID, found: ProviderID)
    case startFailed(String)

    public var description: String {
        switch self {
        case let .unknownApprovalRequest(id): String(localized: "Unbekannte oder bereits beantwortete Freigabe \(id)", bundle: .module)
        case let .decisionNotSupported(decision): String(localized: "Entscheidung \(decision) wird von diesem Agenten nicht unterstützt", bundle: .module)
        case .sessionFinished: String(localized: "Sitzung ist bereits beendet", bundle: .module)
        case let .invalidWorkingDirectory(path): String(localized: "Ungültiges Arbeitsverzeichnis: \(path)", bundle: .module)
        case let .providerMismatch(expected, found): String(localized: "Startplan für \(found), erwartet \(expected)", bundle: .module)
        case let .startFailed(message): String(localized: "Start fehlgeschlagen: \(message)", bundle: .module)
        }
    }
}

/// Pure pre-start validation (spec J3, ADR-0006): the snapshot is re-checked with the Domain
/// resolver against the freshly refreshed capability; any issue blocks the start.
public enum LaunchValidator {
    public enum Result: Hashable, Sendable {
        case ok
        case needsConfiguration([ConfigurationIssue])
        case notRunnable(String)
    }

    public static func validate(snapshot: ConfigurationSnapshot, capability: AgentCapability) -> Result {
        guard snapshot.providerId == capability.providerId else {
            return .needsConfiguration([.providerMismatch(expected: snapshot.providerId, found: capability.providerId)])
        }
        guard capability.isReady else {
            return .notRunnable(capability.diagnostic ?? String(localized: "Agent ist nicht einsatzbereit.", bundle: .module))
        }
        switch ModelEffortResolver.revalidate(snapshot, against: capability) {
        case .ok: return .ok
        case let .needsConfiguration(issues): return .needsConfiguration(issues)
        }
    }
}

/// Capability revision bookkeeping (ADR-0006, A40): unchanged version + catalog keeps the revision.
enum CapabilityRevision {
    static func next(previous: AgentCapability?, version: String, catalog: [AgentModelCapability], flags: [Bool]) -> Int {
        guard let previous else { return 1 }
        let same = previous.version == version
            && normalized(previous.modelCatalog) == normalized(catalog)
            && [previous.supportsModelSelection, previous.supportsEffortSelection, previous.runnable] == flags
        return same ? previous.capabilityRevision : previous.capabilityRevision + 1
    }

    private static func normalized(_ catalog: [AgentModelCapability]) -> [String] {
        catalog.map { model in
            [model.modelId.rawValue, model.displayName, model.availability.rawValue,
             model.defaultEffortId?.rawValue ?? "-", model.supportedEffortIds.map(\.rawValue).joined(separator: ",")]
                .joined(separator: "|")
        }
    }
}

extension Array where Element == AgentDiagnostic {
    var hasBlocking: Bool { contains { $0.severity == .blocking } }
    var joinedMessage: String? {
        isEmpty ? nil : map(\.message).joined(separator: " ")
    }
}
