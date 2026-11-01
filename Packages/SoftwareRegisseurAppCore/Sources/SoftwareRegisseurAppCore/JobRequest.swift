import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

/// The four start options of „Mit Agent umsetzen“ (spec J2, K1).
public enum JobLaunchOption: Hashable, Sendable {
    /// „Nur speichern“: the job and its configuration snapshot are stored, the Mac waits for a manual release.
    case saveOnly
    /// „Jetzt starten“.
    case startNow
    /// „Für später einplanen“: wall-clock time in an IANA zone (K1).
    case scheduleAt(ZonedLocalDateTime)
    /// „Bei Kontingent verfügbar erneut versuchen“: start no earlier than the user's expected quota reset
    /// (K2: reset times are user input, never read from the provider). Stored as the Domain quota schedule
    /// (`ScheduleKind.retryAfterQuota`, user-requested), so Mac and iPhone show it as a quota wait; quota
    /// errors after the start are retried by the Mac with bounded backoff (`QuotaRetryPlanner`).
    case retryWhenQuotaAvailable(expectedReset: Date)

    /// Schedule stored with the job; `requestedAt` is when the user chose the option.
    public func schedule(requestedAt: Date) -> JobSchedule {
        switch self {
        case .saveOnly: JobSchedule(kind: .manualPause)
        case .startNow: JobSchedule(kind: .immediate)
        case let .scheduleAt(local): JobSchedule(kind: .at(local))
        case let .retryWhenQuotaAvailable(reset): JobSchedule(kind: .whenQuotaAvailable(expectedReset: reset, requestedAt: requestedAt))
        }
    }

    /// Convenience with the current time as request time.
    public var schedule: JobSchedule { schedule(requestedAt: Date()) }
}

/// What the user picked in the job sheet. `nil` model/effort means „Projekt-/Globalstandard übernehmen“.
public struct JobRequestInput: Hashable, Sendable {
    public var providerId: ProviderID?
    public var modelOverride: ModelSelection?
    public var effortOverride: EffortLevel?
    public var launchOption: JobLaunchOption
    public var priority: Priority

    public init(
        providerId: ProviderID? = nil,
        modelOverride: ModelSelection? = nil,
        effortOverride: EffortLevel? = nil,
        launchOption: JobLaunchOption = .startNow,
        priority: Priority = .medium
    ) {
        self.providerId = providerId
        self.modelOverride = modelOverride
        self.effortOverride = effortOverride
        self.launchOption = launchOption
        self.priority = priority
    }
}

/// Everything the planner needs; loaded from the synced catalog.
public struct JobRequestContext: Sendable {
    public var workItem: WorkItem
    public var project: Project?
    /// Capabilities reported by Mac hosts (possibly several hosts per agent).
    public var capabilities: [AgentCapability]
    public var hosts: [AgentHost]
    public var globalPreferences: [ProviderID: AgentModelPreference]
    public var projectPreferences: [ProviderID: AgentModelPreference]
    public var hasActiveJob: Bool

    public init(
        workItem: WorkItem,
        project: Project?,
        capabilities: [AgentCapability],
        hosts: [AgentHost] = [],
        globalPreferences: [ProviderID: AgentModelPreference] = [:],
        projectPreferences: [ProviderID: AgentModelPreference] = [:],
        hasActiveJob: Bool = false
    ) {
        self.workItem = workItem
        self.project = project
        self.capabilities = capabilities
        self.hosts = hosts
        self.globalPreferences = globalPreferences
        self.projectPreferences = projectPreferences
        self.hasActiveJob = hasActiveJob
    }

    /// The capability used for validation: the project's host if known, otherwise the most recent report.
    public func capability(for provider: ProviderID) -> AgentCapability? {
        let candidates = capabilities.filter { $0.providerId == provider }
        if let hostId = project?.hostId, let onHost = candidates.first(where: { $0.hostId == hostId }) {
            return onHost
        }
        return candidates.max { $0.lastChecked < $1.lastChecked }
    }

    /// Agents the sheet may offer (spec J2: no agent that is not installed shown as available).
    public var selectableProviders: [ProviderID] {
        Array(Set(capabilities.filter(\.isReady).map(\.providerId))).sorted()
    }

    public func host(for capability: AgentCapability) -> AgentHost? {
        hosts.first { $0.hostId == capability.hostId }
    }
}

/// Why a job request cannot be submitted. Blocked combinations are never sent (ADR-0006).
public enum JobRequestBlocker: Hashable, Sendable {
    case noAgentSelected
    case workItemWithoutProject
    case agentNotReported(ProviderID)
    case agentNotReady(ProviderID)
    case workItemNotStartable(WorkItemStatus)
    case activeJobExists
    case configuration([ConfigurationIssue])
    case scheduleInvalid
    case scheduleInPast
}

public struct JobRequestEvaluation: Hashable, Sendable {
    public let capability: AgentCapability?
    public let resolution: ResolvedAgentConfiguration?
    public let blockers: [JobRequestBlocker]
    /// Model the effort picker refers to (job override or inherited value).
    public let effectiveModel: ModelSelection

    public var canSubmit: Bool { blockers.isEmpty && resolution != nil }
}

/// One selectable model row; unavailable models are listed but disabled with their availability.
public struct ModelChoice: Hashable, Sendable, Identifiable {
    public let selection: ModelSelection
    public let displayName: String
    public let availability: ModelAvailability
    public let supportedEfforts: [EffortLevel]

    public var id: String {
        switch selection {
        case .providerDefault: "\u{0}providerDefault"
        case let .model(id): id.rawValue
        }
    }

    public var isSelectable: Bool { availability == .available }
}

public enum JobRequestError: Error, Hashable, Sendable {
    case blocked([JobRequestBlocker])
}

/// Builds and validates agent job requests on the iPhone (spec J2/J2a, K1, ADR-0006/0012).
/// The configuration is resolved with `ModelEffortResolver` (Job > Projekt > Global > Anbieterstandard) and
/// frozen into the job's `ConfigurationSnapshot`; nothing falls back silently.
public enum JobRequestPlanner {
    public static func evaluate(_ input: JobRequestInput, context: JobRequestContext, now: Date) -> JobRequestEvaluation {
        var blockers: [JobRequestBlocker] = []
        if context.workItem.projectId == nil { blockers.append(.workItemWithoutProject) }
        if context.hasActiveJob { blockers.append(.activeJobExists) }
        if !context.workItem.status.canStartAgentJob {
            blockers.append(.workItemNotStartable(context.workItem.status))
        }
        blockers.append(contentsOf: scheduleBlockers(input.launchOption, now: now))

        guard let provider = input.providerId else {
            return JobRequestEvaluation(capability: nil, resolution: nil, blockers: [.noAgentSelected] + blockers,
                                        effectiveModel: input.modelOverride ?? .providerDefault)
        }
        guard let capability = context.capability(for: provider) else {
            return JobRequestEvaluation(capability: nil, resolution: nil, blockers: [.agentNotReported(provider)] + blockers,
                                        effectiveModel: input.modelOverride ?? .providerDefault)
        }
        if !capability.isReady { blockers.append(.agentNotReady(provider)) }

        let project = context.projectPreferences[provider]
        let global = context.globalPreferences[provider]
        let effectiveModel = inheritedModel(override: input.modelOverride, project: project, global: global)
        let override = JobConfigurationOverride(providerId: provider, model: input.modelOverride, effort: input.effortOverride)
        let resolution = ModelEffortResolver.resolve(
            jobOverride: override, projectPreference: project, globalPreference: global, capability: capability
        )
        switch resolution {
        case let .resolved(configuration):
            return JobRequestEvaluation(capability: capability, resolution: configuration, blockers: blockers, effectiveModel: effectiveModel)
        case let .needsConfiguration(issues):
            return JobRequestEvaluation(capability: capability, resolution: nil, blockers: blockers + [.configuration(issues)],
                                        effectiveModel: effectiveModel)
        }
    }

    /// Creates the job with the resolved snapshot. Throws instead of submitting a blocked combination.
    public static func makeJob(
        _ input: JobRequestInput, context: JobRequestContext, idempotencyKey: IdempotencyKey, now: Date
    ) throws(JobRequestError) -> AgentJob {
        let evaluation = evaluate(input, context: context, now: now)
        guard evaluation.canSubmit, let resolution = evaluation.resolution, let capability = evaluation.capability,
              let projectId = context.workItem.projectId
        else { throw .blocked(evaluation.blockers) }
        return AgentJob(
            idempotencyKey: idempotencyKey,
            projectId: projectId,
            workItemId: context.workItem.uuid,
            hostId: context.project?.hostId ?? capability.hostId,
            configSnapshot: resolution.makeSnapshot(createdAt: now),
            schedule: input.launchOption.schedule(requestedAt: now),
            priority: input.priority,
            workItemStatusBeforeJob: context.workItem.status,
            createdAt: now
        )
    }

    /// Model rows for the picker: provider default first, then the reported catalog.
    public static func modelChoices(for capability: AgentCapability) -> [ModelChoice] {
        let defaultEfforts = capability.selectableEfforts(for: .providerDefault)
        var choices = [ModelChoice(selection: .providerDefault, displayName: "", availability: .available, supportedEfforts: defaultEfforts)]
        guard capability.supportsModelSelection else { return choices }
        choices += capability.modelCatalog.map { model in
            ModelChoice(
                selection: .model(model.modelId),
                displayName: model.displayName.isEmpty ? model.modelId.rawValue : model.displayName,
                availability: model.availability,
                supportedEfforts: capability.selectableEfforts(for: .model(model.modelId))
            )
        }
        return choices
    }

    /// Effort levels the picker may enable for the effective model (A37). Only `auto` when not adjustable.
    public static func effortChoices(for capability: AgentCapability, model: ModelSelection) -> [EffortLevel] {
        capability.selectableEfforts(for: model)
    }

    static func inheritedModel(override: ModelSelection?, project: AgentModelPreference?, global: AgentModelPreference?) -> ModelSelection {
        if let override { return override }
        if let project, !project.inheritsDefault, let model = project.model { return model }
        if let global, !global.inheritsDefault, let model = global.model { return model }
        return .providerDefault
    }

    static func scheduleBlockers(_ option: JobLaunchOption, now: Date) -> [JobRequestBlocker] {
        switch option {
        case .saveOnly, .startNow:
            return []
        case let .scheduleAt(local):
            guard let planned = try? local.resolve().date else { return [.scheduleInvalid] }
            return planned <= now ? [.scheduleInPast] : []
        case let .retryWhenQuotaAvailable(reset):
            return reset <= now ? [.scheduleInPast] : []
        }
    }
}

/// Holds one idempotency key per opened job sheet, so a repeated tap or a retry after a failed write
/// returns the already created job instead of a duplicate (spec J3, A15).
public struct JobRequestSubmitter: Sendable {
    public let jobs: any AgentJobRepository
    public let idempotencyKey: IdempotencyKey

    public init(jobs: any AgentJobRepository, idempotencyKey: IdempotencyKey = IdempotencyKey()) {
        self.jobs = jobs
        self.idempotencyKey = idempotencyKey
    }

    public func submit(
        _ input: JobRequestInput, context: JobRequestContext, actor: EventActor, now: Date
    ) async throws -> JobCreationResult {
        let job = try JobRequestPlanner.makeJob(input, context: context, idempotencyKey: idempotencyKey, now: now)
        return try await jobs.create(job, actor: actor, at: now)
    }
}

/// Global and project defaults per agent (J2a). Saving never touches existing jobs (A38/A39).
public enum AgentPreferenceEditor {
    /// Validates a preference before it is stored, so a default cannot name an unsupported combination.
    public static func issues(model: ModelSelection?, effort: EffortLevel?, capability: AgentCapability) -> [ConfigurationIssue] {
        ModelEffortResolver.validate(model: model ?? .providerDefault, effort: effort ?? .auto, against: capability)
    }

    public static func makePreference(
        scope: PreferenceScope, provider: ProviderID, model: ModelSelection?, effort: EffortLevel?, now: Date
    ) -> AgentModelPreference {
        AgentModelPreference(scope: scope, providerId: provider, model: model, effort: effort,
                             inheritsDefault: model == nil && effort == nil, updatedAt: now)
    }
}
