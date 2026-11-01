import Foundation
import Testing
import SoftwareRegisseurAppCore
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

@Suite("Job requests (J2/J2a, ADR-0006)")
struct JobRequestTests {
    func context(item: WorkItem? = nil, project: Project? = nil, capability: AgentCapability = Fixture.codex(),
                 global: AgentModelPreference? = nil, projectPreference: AgentModelPreference? = nil,
                 activeJob: Bool = false) -> JobRequestContext {
        let (defaultProject, _) = Fixture.project()
        let project = project ?? defaultProject
        let item = item ?? Fixture.item(projectId: project.id)
        return JobRequestContext(
            workItem: item, project: project, capabilities: [capability],
            globalPreferences: global.map { [.codex: $0] } ?? [:],
            projectPreferences: projectPreference.map { [.codex: $0] } ?? [:],
            hasActiveJob: activeJob
        )
    }

    @Test func resolvesJobOverProjectOverGlobal() throws {
        let (project, _) = Fixture.project()
        let global = AgentModelPreference(scope: .global, providerId: .codex, model: .model("gpt-5.5-mini"), effort: .low, updatedAt: now)
        let projectPreference = AgentModelPreference(scope: .project(project.id), providerId: .codex, effort: .medium, updatedAt: now)
        let ctx = context(project: project, global: global, projectPreference: projectPreference)

        let inherited = JobRequestPlanner.evaluate(JobRequestInput(providerId: .codex), context: ctx, now: now)
        #expect(inherited.canSubmit)
        #expect(inherited.resolution?.resolvedModel == .model("gpt-5.5-mini"))
        #expect(inherited.resolution?.resolvedEffort == .medium)
        #expect(inherited.resolution?.profileSource == ProfileSources(model: .global, effort: .project))
        #expect(inherited.effectiveModel == .model("gpt-5.5-mini"))

        let overridden = JobRequestPlanner.evaluate(
            JobRequestInput(providerId: .codex, modelOverride: .model("gpt-5.5-codex"), effortOverride: .xhigh), context: ctx, now: now)
        #expect(overridden.canSubmit)
        #expect(overridden.resolution?.profileSource == ProfileSources(model: .job, effort: .job))
        #expect(overridden.resolution?.requestedEffort == .xhigh)
    }

    @Test func blocksEffortTheModelDoesNotSupport() {
        let input = JobRequestInput(providerId: .codex, modelOverride: .model("gpt-5.5-mini"), effortOverride: .xhigh)
        let evaluation = JobRequestPlanner.evaluate(input, context: context(), now: now)
        #expect(!evaluation.canSubmit)
        #expect(evaluation.blockers.contains(.configuration([.effortNotSupportedByModel(effort: .xhigh, model: "gpt-5.5-mini")])))
        #expect(throws: JobRequestError.self) {
            try JobRequestPlanner.makeJob(input, context: context(), idempotencyKey: IdempotencyKey(), now: now)
        }
    }

    @Test func blocksInheritedPreferenceThatBecameInvalid() {
        // Global default asks for `high`, the selected model supports only low/medium: no silent fallback.
        let global = AgentModelPreference(scope: .global, providerId: .codex, model: .model("gpt-5.5-mini"), effort: .high, updatedAt: now)
        let evaluation = JobRequestPlanner.evaluate(JobRequestInput(providerId: .codex), context: context(global: global), now: now)
        #expect(!evaluation.canSubmit)
        #expect(evaluation.resolution == nil)
    }

    @Test func effortNotAdjustableOnlyOffersAuto() {
        let capability = Fixture.codex(effortAdjustable: false)
        #expect(JobRequestPlanner.effortChoices(for: capability, model: .model("gpt-5.5-codex")) == [.auto])
        #expect(capability.effortSelectionHint == AgentCapability.effortNotAdjustableText)
        let blocked = JobRequestPlanner.evaluate(JobRequestInput(providerId: .codex, effortOverride: .high),
                                                 context: context(capability: capability), now: now)
        #expect(!blocked.canSubmit)
        let auto = JobRequestPlanner.evaluate(JobRequestInput(providerId: .codex), context: context(capability: capability), now: now)
        #expect(auto.canSubmit)
        #expect(auto.resolution?.effortAdjustable == false)
    }

    @Test func deprecatedModelIsListedButNotSelectable() {
        let choices = JobRequestPlanner.modelChoices(for: Fixture.codex())
        #expect(choices.first?.selection == .providerDefault)
        #expect(choices.first { $0.selection == .model("gpt-old") }?.isSelectable == false)
        let evaluation = JobRequestPlanner.evaluate(JobRequestInput(providerId: .codex, modelOverride: .model("gpt-old")),
                                                    context: context(), now: now)
        #expect(!evaluation.canSubmit)
    }

    @Test func blocksAgentNotReadyItemWithoutProjectAndActiveJob() {
        let notReady = JobRequestPlanner.evaluate(JobRequestInput(providerId: .codex),
                                                  context: context(capability: Fixture.codex(ready: false)), now: now)
        #expect(notReady.blockers.contains(.agentNotReady(.codex)))

        let inbox = Fixture.item(projectId: nil, status: .inbox)
        let withoutProject = JobRequestPlanner.evaluate(JobRequestInput(providerId: .codex), context: context(item: inbox), now: now)
        #expect(withoutProject.blockers.contains(.workItemWithoutProject))

        let active = JobRequestPlanner.evaluate(JobRequestInput(providerId: .codex), context: context(activeJob: true), now: now)
        #expect(active.blockers.contains(.activeJobExists))

        let unknown = JobRequestPlanner.evaluate(JobRequestInput(providerId: .claudeCode), context: context(), now: now)
        #expect(unknown.blockers.contains(.agentNotReported(.claudeCode)))
        #expect(!context().selectableProviders.contains(.claudeCode))
    }

    @Test func launchOptionsMapToSchedules() throws {
        let later = try ZonedLocalDateTime(year: 2026, month: 11, day: 2, hour: 7, minute: 30, timeZoneIdentifier: "Europe/Vienna")
        #expect(JobLaunchOption.saveOnly.schedule.kind == .manualPause)
        #expect(JobLaunchOption.startNow.schedule.kind == .immediate)
        #expect(JobLaunchOption.scheduleAt(later).schedule.kind == .at(later))
        let reset = now.addingTimeInterval(3600)
        // Stored as the Domain quota schedule (user-requested), not as a plain `notBefore` (gap 5).
        let quota = JobLaunchOption.retryWhenQuotaAvailable(expectedReset: reset).schedule(requestedAt: now)
        #expect(quota.kind == .whenQuotaAvailable(expectedReset: reset, requestedAt: now))
        #expect(try quota.plannedStart() == reset)

        let past = try ZonedLocalDateTime(year: 2026, month: 10, day: 29, hour: 7, minute: 30, timeZoneIdentifier: "Europe/Vienna")
        let blocked = JobRequestPlanner.evaluate(JobRequestInput(providerId: .codex, launchOption: .scheduleAt(past)),
                                                 context: context(), now: now)
        #expect(blocked.blockers.contains(.scheduleInPast))
    }

    @Test func jobCarriesResolvedSnapshot() throws {
        let key = IdempotencyKey()
        let input = JobRequestInput(providerId: .codex, modelOverride: .model("gpt-5.5-codex"), effortOverride: .high,
                                    launchOption: .saveOnly, priority: .urgent)
        let ctx = context()
        let job = try JobRequestPlanner.makeJob(input, context: ctx, idempotencyKey: key, now: now)
        #expect(job.idempotencyKey == key)
        #expect(job.state == .requested)
        #expect(job.requestedModelId == "gpt-5.5-codex")
        #expect(job.resolvedEffort == .high)
        #expect(job.capabilityRevision == 4)
        #expect(job.agentVersion == "0.60.0")
        #expect(job.hostId == hostID)
        #expect(job.priority == .urgent)
        #expect(job.schedule.kind == .manualPause)
        #expect(job.effectiveModelDisplayText == AgentJob.unconfirmedText)
    }

    @Test func submittingTwiceWithSameKeyCreatesOneJob() async throws {
        let (database, project, item) = try await Fixture.makeDatabase()
        let ctx = JobRequestContext(workItem: item, project: project, capabilities: [Fixture.codex()])
        let submitter = JobRequestSubmitter(jobs: database.jobs)
        let input = JobRequestInput(providerId: .codex, effortOverride: .medium)

        let first = try await submitter.submit(input, context: ctx, actor: actor, now: now)
        let second = try await submitter.submit(input, context: ctx, actor: actor, now: now)
        #expect(first.wasCreated)
        #expect(!second.wasCreated)
        #expect(first.job.jobId == second.job.jobId)
        #expect(try await database.jobs.jobs(forWorkItem: item.uuid).count == 1)
        #expect(try await database.workItems.fetch(item.uuid)?.status == .queued)
    }

    @Test func preferenceEditorRejectsUnsupportedDefault() {
        let issues = AgentPreferenceEditor.issues(model: .model("gpt-5.5-mini"), effort: .xhigh, capability: Fixture.codex())
        #expect(!issues.isEmpty)
        let inherit = AgentPreferenceEditor.makePreference(scope: .global, provider: .codex, model: nil, effort: nil, now: now)
        #expect(inherit.inheritsDefault)
    }
}
