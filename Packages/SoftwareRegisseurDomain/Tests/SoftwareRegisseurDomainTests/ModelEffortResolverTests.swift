import Foundation
import Testing
@testable import SoftwareRegisseurDomain

@Suite("Model/effort resolution (ADR-0006, A37/A38)")
struct ModelEffortResolverTests {
    let capability = Fixtures.codexCapability()

    private func resolve(
        job: JobConfigurationOverride? = nil,
        project: AgentModelPreference? = nil,
        global: AgentModelPreference? = nil,
        capability: AgentCapability? = nil
    ) -> ModelEffortResolution {
        ModelEffortResolver.resolve(
            jobOverride: job,
            projectPreference: project,
            globalPreference: global,
            capability: capability ?? self.capability
        )
    }

    @Test func providerDefaultWhenNothingIsSet() throws {
        let config = try #require(resolve().configuration)
        #expect(config.resolvedModel == .providerDefault)
        #expect(config.resolvedEffort == .auto)
        #expect(config.profileSource == ProfileSources(model: .providerDefault, effort: .providerDefault))
        #expect(config.requestedModel == nil)
        #expect(config.requestedEffort == nil)
        #expect(config.capabilityRevision == 1)
        #expect(config.agentVersion == "0.50.0")
    }

    @Test func globalLevel() throws {
        let config = try #require(resolve(global: Fixtures.global(.model(Fixtures.codexMini), .low)).configuration)
        #expect(config.resolvedModel == .model(Fixtures.codexMini))
        #expect(config.resolvedEffort == .low)
        #expect(config.profileSource == ProfileSources(model: .global, effort: .global))
    }

    @Test func projectBeatsGlobal() throws {
        let config = try #require(resolve(
            project: Fixtures.project(.model(Fixtures.codexModel), .high),
            global: Fixtures.global(.model(Fixtures.codexMini), .low)
        ).configuration)
        #expect(config.resolvedModel == .model(Fixtures.codexModel))
        #expect(config.resolvedEffort == .high)
        #expect(config.profileSource == ProfileSources(model: .project, effort: .project))
    }

    @Test func jobBeatsProjectAndGlobal() throws {
        let config = try #require(resolve(
            job: JobConfigurationOverride(providerId: .codex, model: .model(Fixtures.codexMini), effort: .medium),
            project: Fixtures.project(.model(Fixtures.codexModel), .high),
            global: Fixtures.global(.model(Fixtures.codexModel), .low)
        ).configuration)
        #expect(config.resolvedModel == .model(Fixtures.codexMini))
        #expect(config.resolvedEffort == .medium)
        #expect(config.profileSource == ProfileSources(model: .job, effort: .job))
        #expect(config.requestedModel == .model(Fixtures.codexMini))
        #expect(config.requestedEffort == .medium)
    }

    @Test func modelAndEffortSourcesAreRecordedSeparately() throws {
        let config = try #require(resolve(
            job: JobConfigurationOverride(providerId: .codex, effort: .xhigh),
            project: Fixtures.project(.model(Fixtures.codexModel)),
            global: Fixtures.global(nil, .low)
        ).configuration)
        #expect(config.resolvedModel == .model(Fixtures.codexModel))
        #expect(config.resolvedEffort == .xhigh)
        #expect(config.profileSource == ProfileSources(model: .project, effort: .job))
        #expect(config.requestedModel == nil)
    }

    @Test func effortFromGlobalModelFromProviderDefault() throws {
        let config = try #require(resolve(global: Fixtures.global(nil, .high)).configuration)
        #expect(config.resolvedModel == .providerDefault)
        #expect(config.resolvedEffort == .high)
        #expect(config.profileSource == ProfileSources(model: .providerDefault, effort: .global))
    }

    @Test func inheritingProjectPreferenceFallsThroughToGlobal() throws {
        let config = try #require(resolve(
            project: Fixtures.project(.model(Fixtures.codexModel), .high, inherits: true),
            global: Fixtures.global(.model(Fixtures.codexMini), .low)
        ).configuration)
        #expect(config.profileSource == ProfileSources(model: .global, effort: .global))
    }

    @Test func explicitProviderDefaultAtProjectOverridesGlobalModel() throws {
        let config = try #require(resolve(
            project: Fixtures.project(.providerDefault, .auto),
            global: Fixtures.global(.model(Fixtures.codexMini), .low)
        ).configuration)
        #expect(config.resolvedModel == .providerDefault)
        #expect(config.resolvedEffort == .auto)
        #expect(config.profileSource == ProfileSources(model: .project, effort: .project))
    }

    @Test func unsupportedEffortForModelNeedsConfiguration() {
        let result = resolve(job: JobConfigurationOverride(providerId: .codex, model: .model(Fixtures.codexMini), effort: .high))
        #expect(result == .needsConfiguration([.effortNotSupportedByModel(effort: .high, model: Fixtures.codexMini)]))
    }

    @Test func inheritedEffortIsNotSilentlyDowngradedForAnotherModel() {
        // Project wants xhigh; the job picks the mini model which only supports low/medium.
        let result = resolve(
            job: JobConfigurationOverride(providerId: .codex, model: .model(Fixtures.codexMini)),
            project: Fixtures.project(nil, .xhigh)
        )
        #expect(result.configuration == nil)
        #expect(result.issues == [.effortNotSupportedByModel(effort: .xhigh, model: Fixtures.codexMini)])
    }

    @Test func unknownEffortIdNeedsConfiguration() {
        let result = resolve(global: Fixtures.global(.model(Fixtures.codexModel), "ultra"))
        #expect(result.issues == [.effortNotSupportedByModel(effort: "ultra", model: Fixtures.codexModel)])
    }

    @Test func unknownModelNeedsConfiguration() {
        let result = resolve(project: Fixtures.project(.model("gpt-unknown"), .high))
        #expect(result.issues == [.unknownModel("gpt-unknown")])
    }

    @Test func modelNotEntitledNeedsConfiguration() {
        let capability = Fixtures.codexCapability(models: [
            Fixtures.model(Fixtures.codexModel, efforts: [.low, .high], availability: .notEntitled),
        ])
        let result = resolve(job: JobConfigurationOverride(providerId: .codex, model: .model(Fixtures.codexModel)), capability: capability)
        #expect(result.issues == [.modelUnavailable(Fixtures.codexModel, .notEntitled)])
    }

    @Test func effortWithProviderDefaultModelValidatesAgainstReportedDefaultModel() {
        #expect(resolve(global: Fixtures.global(nil, .xhigh)).configuration != nil)
        let noDefault = Fixtures.codexCapability(defaultModel: nil)
        #expect(resolve(global: Fixtures.global(nil, .high), capability: noDefault).issues == [.effortRequiresKnownModel(.high)])
        #expect(resolve(global: Fixtures.global(nil, .auto), capability: noDefault).configuration != nil)
    }

    @Test func adapterWithoutModelSelection() {
        let capability = Fixtures.codexCapability(supportsModel: false)
        #expect(resolve(project: Fixtures.project(.model(Fixtures.codexModel))).configuration != nil)
        #expect(resolve(project: Fixtures.project(.model(Fixtures.codexModel)), capability: capability).issues
            == [.modelSelectionNotSupported(Fixtures.codexModel)])
        #expect(resolve(capability: capability).configuration != nil)
    }

    @Test func adapterWithoutEffortSupportOnlyAllowsAuto() throws {
        let claude = Fixtures.claudeWithoutEffort()
        let config = try #require(resolve(
            job: JobConfigurationOverride(providerId: .claudeCode, model: .model("sonnet")),
            capability: claude
        ).configuration)
        #expect(config.resolvedEffort == .auto)
        #expect(config.effortAdjustable == false)
        #expect(config.effortDisplayText == "Anbieterstandard – nicht einstellbar")
        #expect(claude.effortSelectionHint == "Anbieterstandard – nicht einstellbar")
        #expect(claude.selectableEfforts(for: .model("sonnet")) == [.auto])

        let explicit = resolve(
            job: JobConfigurationOverride(providerId: .claudeCode, model: .model("sonnet"), effort: .high),
            capability: claude
        )
        #expect(explicit.issues == [.effortSelectionNotSupported(.high)])
    }

    @Test func adjustableEffortDisplayText() throws {
        let config = try #require(resolve(global: Fixtures.global(.model(Fixtures.codexModel), .xhigh)).configuration)
        #expect(config.effortDisplayText == "Extra hoch")
        #expect(capability.effortSelectionHint == nil)
    }

    @Test func selectableEffortsPerModel() {
        #expect(capability.selectableEfforts(for: .model(Fixtures.codexModel)) == [.auto, .low, .medium, .high, .xhigh])
        #expect(capability.selectableEfforts(for: .model(Fixtures.codexMini)) == [.auto, .low, .medium])
        #expect(capability.selectableEfforts(for: .providerDefault) == [.auto, .low, .medium, .high, .xhigh])
        #expect(capability.selectableEfforts(for: .model("gone")) == [.auto])
        #expect(capability.modelEffortMatrix[Fixtures.codexMini] == [.low, .medium])
    }

    @Test func providerAndScopeMismatchesAreReported() {
        let claudePref = Fixtures.global(.model("sonnet"), nil, provider: .claudeCode)
        #expect(resolve(global: claudePref).issues == [.providerMismatch(expected: .codex, found: .claudeCode)])
        #expect(resolve(job: JobConfigurationOverride(providerId: .claudeCode)).issues == [.providerMismatch(expected: .codex, found: .claudeCode)])
        #expect(resolve(project: Fixtures.global(.model(Fixtures.codexModel))).issues == [.preferenceScopeMismatch(expected: .project)])
    }

    @Test func issuesHaveGermanDescriptions() {
        let issue = ConfigurationIssue.effortNotSupportedByModel(effort: .xhigh, model: Fixtures.codexMini)
        #expect(issue.germanDescription.contains("Extra hoch"))
        #expect(issue.germanDescription.contains("gpt-5.5-mini"))
    }
}

@Suite("Configuration snapshot (A39/A40/A41)")
struct ConfigurationSnapshotTests {
    private func makeJob(state: AgentJobState = .scheduled) throws -> AgentJob {
        let snapshot = try Fixtures.resolvedSnapshot(
            jobOverride: JobConfigurationOverride(providerId: .codex, model: .model(Fixtures.codexModel), effort: .xhigh)
        )
        let local = try ZonedLocalDateTime(year: 2026, month: 10, day: 31, hour: 7, minute: 0, timeZoneIdentifier: "Europe/Vienna")
        var job = Fixtures.job(snapshot: snapshot, schedule: JobSchedule(kind: .at(local)))
        if state == .scheduled { try job.transition(to: .scheduled, at: referenceDate) }
        return job
    }

    @Test func snapshotSurvivesCodableRoundTripUnchanged() throws {
        var job = try makeJob()
        job.retryCount = 2
        let decoded = try roundTrip(job)
        #expect(decoded == job)
        #expect(decoded.configSnapshot == job.configSnapshot)
        #expect(decoded.resolvedModelId == Fixtures.codexModel)
        #expect(decoded.resolvedEffort == .xhigh)
        #expect(decoded.profileSource == ProfileSources(model: .job, effort: .job))
        #expect(decoded.capabilityRevision == 1)
        #expect(decoded.scheduledAt == utc("2026-10-31T06:00:00Z"))
        #expect(try jsonString(decoded) == jsonString(job))
    }

    @Test func snapshotKeepsUnknownProviderValuesLosslessly() throws {
        let snapshot = ConfigurationSnapshot(
            providerId: "gemini-cli",
            requestedModel: .model("gemini-3-pro-preview"),
            requestedEffort: "thinking-budget-32k",
            resolvedModel: .model("gemini-3-pro-preview"),
            resolvedEffort: "thinking-budget-32k",
            profileSource: ProfileSources(model: .job, effort: .job),
            capabilityRevision: 7,
            agentVersion: "1.2.3",
            createdAt: referenceDate
        )
        let decoded = try roundTrip(snapshot)
        #expect(decoded == snapshot)
        #expect(decoded.resolvedEffort.rawValue == "thinking-budget-32k")
        #expect(decoded.resolvedEffort.germanDisplayName == "thinking-budget-32k")
    }

    @Test func laterPreferenceChangesDoNotAlterExistingJob() throws {
        let job = try makeJob()
        let before = job.configSnapshot
        _ = ModelEffortResolver.resolve(
            jobOverride: nil,
            projectPreference: Fixtures.project(.model(Fixtures.codexMini), .low),
            globalPreference: nil,
            capability: Fixtures.codexCapability(revision: 2)
        )
        #expect(job.configSnapshot == before)
    }

    @Test func capabilityUpgradeRemovingModelNeedsConfiguration() throws {
        var job = try makeJob()
        let snapshot = job.configSnapshot
        let upgraded = Fixtures.codexCapability(
            revision: 2,
            version: "0.60.0",
            models: [Fixtures.model("gpt-6-codex", efforts: [.low, .medium, .high])],
            defaultModel: "gpt-6-codex"
        )
        let result = ModelEffortResolver.revalidate(snapshot, against: upgraded)
        #expect(result == .needsConfiguration([.unknownModel(Fixtures.codexModel)]))
        #expect(job.configSnapshot == snapshot)

        let admission = try job.admit(against: upgraded, at: referenceDate)
        #expect(admission == result)
        #expect(job.state == .needsConfiguration)
        #expect(job.derivedWorkItemStatus == .blocked)
        #expect(job.configSnapshot == snapshot)
        #expect(job.capabilityRevision == 1)
    }

    @Test func capabilityUpgradeRemovingEffortNeedsConfiguration() throws {
        let job = try makeJob()
        let upgraded = Fixtures.codexCapability(revision: 2, models: [Fixtures.model(Fixtures.codexModel, efforts: [.low, .medium, .high])])
        #expect(ModelEffortResolver.revalidate(job.configSnapshot, against: upgraded)
            == .needsConfiguration([.effortNotSupportedByModel(effort: .xhigh, model: Fixtures.codexModel)]))
    }

    @Test func compatibleUpgradeAdmitsWithOriginalSnapshot() throws {
        var job = try makeJob()
        let upgraded = Fixtures.codexCapability(revision: 5, version: "0.61.0")
        #expect(try job.admit(against: upgraded, at: referenceDate) == .ok)
        #expect(job.state == .admitted)
        #expect(job.capabilityRevision == 1)
        #expect(job.agentVersion == "0.50.0")
    }

    @Test func explicitReplacementOnlyBeforeStart() throws {
        var job = try makeJob()
        let replacement = try Fixtures.resolvedSnapshot(
            jobOverride: JobConfigurationOverride(providerId: .codex, model: .model(Fixtures.codexMini), effort: .low),
            capability: Fixtures.codexCapability(revision: 2)
        )
        try job.replaceConfiguration(with: replacement, at: referenceDate)
        #expect(job.configSnapshot == replacement)
        #expect(job.resolvedModelId == Fixtures.codexMini)

        try job.transition(to: .admitted, at: referenceDate)
        #expect(throws: AgentJobError.configurationLocked(state: .admitted)) {
            try job.replaceConfiguration(with: replacement, at: referenceDate)
        }
        try job.transition(to: .starting, at: referenceDate)
        try job.transition(to: .running, at: referenceDate)
        try job.transition(to: .waitingQuota, at: referenceDate)
        // Started once: snapshot stays fixed across quota retries (A39).
        #expect(throws: AgentJobError.configurationLocked(state: .waitingQuota)) {
            try job.replaceConfiguration(with: replacement, at: referenceDate)
        }

        var other = try makeJob()
        let claude = try Fixtures.resolvedSnapshot(capability: Fixtures.claudeWithoutEffort())
        #expect(throws: AgentJobError.providerMismatch(expected: .codex, found: .claudeCode)) {
            try other.replaceConfiguration(with: claude, at: referenceDate)
        }
    }

    @Test func effectiveValuesOnlyFromAdapterConfirmation() throws {
        var job = try makeJob()
        #expect(job.effectiveModelId == nil)
        #expect(job.effectiveEffort == nil)
        #expect(job.effectiveModelDisplayText == "nicht bestätigt")
        #expect(job.effectiveEffortDisplayText == "nicht bestätigt")
        job.recordConfirmedEffectiveConfiguration(model: Fixtures.codexModel, effort: nil, at: referenceDate)
        #expect(job.effectiveModelId == Fixtures.codexModel)
        #expect(job.effectiveEffortDisplayText == "nicht bestätigt")
        #expect(job.effectiveConfirmedAt == referenceDate)
    }
}
