import Foundation
import Testing
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC

@Suite("Jobanfrage: Agent → Modell → Stufe, Zeitplan, Befehlsbau")
struct JobRequestTests {
    let item = Fixture.item("Aufgabe")

    private func form(_ provider: ProviderID? = .codex, model: ModelSelection? = nil, effort: EffortLevel? = nil,
                      schedule: ScheduleForm = ScheduleForm(date: Fixture.now)) -> JobRequestForm {
        var form = JobRequestForm(providerId: provider, schedule: schedule)
        form.model = model
        form.effort = effort
        return form
    }

    @Test func validSelectionBuildsCommandWithOverridesAndStableIdempotencyKey() throws {
        let request = form(model: .model("modell-a"), effort: .high)
        let validation = JobRequestValidation.evaluate(form: request, workItem: item, snapshot: Fixture.library(items: [item]),
                                                       hostId: Fixture.hostId, now: Fixture.now)
        let command = try #require(validation.command)
        #expect(validation.blockers.isEmpty)
        #expect(command.workItemId == item.uuid)
        #expect(command.providerId == .codex)
        #expect(command.model == .model("modell-a"))
        #expect(command.effort == .high)
        #expect(command.idempotencyKey == request.idempotencyKey)
        #expect(command.schedule.kind == .immediate)
        #expect(validation.resolved?.resolvedEffort == .high)
    }

    @Test func inheritedValuesAreSentAsNil() throws {
        let validation = JobRequestValidation.evaluate(form: form(), workItem: item, snapshot: Fixture.library(items: [item]),
                                                       hostId: Fixture.hostId, now: Fixture.now)
        let command = try #require(validation.command)
        #expect(command.model == nil)
        #expect(command.effort == nil)
        #expect(validation.resolved?.resolvedModel == .providerDefault)
    }

    @Test func unsupportedEffortIsBlockedNotReplaced() {
        let validation = JobRequestValidation.evaluate(form: form(model: .model("modell-a"), effort: .xhigh), workItem: item,
                                                       snapshot: Fixture.library(items: [item]), hostId: Fixture.hostId, now: Fixture.now)
        #expect(validation.command == nil)
        #expect(!validation.blockers.isEmpty)
    }

    @Test func effortIsNotAdjustableWithoutAdapterSupport() {
        let capability = Fixture.capability(effortAdjustable: false)
        #expect(ModelEffortChoices.efforts(for: capability, model: .model("modell-a")) == [.auto])
        let validation = JobRequestValidation.evaluate(form: form(effort: .high), workItem: item,
                                                       snapshot: Fixture.library(items: [item], capabilities: [capability]),
                                                       hostId: Fixture.hostId, now: Fixture.now)
        #expect(validation.command == nil)
    }

    @Test func modelChoicesListDeprecatedModelsAsNotSelectable() {
        let choices = ModelEffortChoices.models(for: Fixture.capability())
        #expect(choices.first?.selection == .providerDefault)
        #expect(choices.first { $0.selection == .model("modell-alt") }?.isSelectable == false)
        #expect(ModelEffortChoices.efforts(for: Fixture.capability(), model: .model("modell-a")) == [.auto, .low, .medium, .high])
    }

    @Test func blockersForMissingAgentInboxItemsAndActiveJobs() {
        let library = Fixture.library(items: [item])
        #expect(JobRequestValidation.evaluate(form: form(nil), workItem: item, snapshot: library, hostId: Fixture.hostId,
                                              now: Fixture.now).command == nil)
        let inbox = Fixture.item("Notiz", project: nil, type: .note, status: .inbox)
        let inboxValidation = JobRequestValidation.evaluate(form: form(), workItem: inbox, snapshot: Fixture.library(items: [inbox]),
                                                            hostId: Fixture.hostId, now: Fixture.now)
        #expect(inboxValidation.blockers.contains(JobRequestValidation.blockerText(.workItemWithoutProject)))
        let active = Fixture.job(for: item, state: .running)
        let activeValidation = JobRequestValidation.evaluate(form: form(), workItem: item,
                                                             snapshot: Fixture.library(items: [item], jobs: [active]),
                                                             hostId: Fixture.hostId, now: Fixture.now)
        #expect(activeValidation.command == nil)
    }

    @Test func agentThatIsNotReadyIsBlocked() {
        let validation = JobRequestValidation.evaluate(form: form(), workItem: item,
                                                       snapshot: Fixture.library(items: [item], capabilities: [Fixture.capability(ready: false)]),
                                                       hostId: Fixture.hostId, now: Fixture.now)
        #expect(validation.command == nil)
    }

    @Test func scheduleAtKeepsWallClockTimeInIANAZone() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Vienna"))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 22, minute: 0)))
        let schedule = try ScheduleForm(choice: .at, date: date, timeZoneIdentifier: "Europe/Vienna", missedRunPolicy: .skipExpired)
            .makeSchedule(now: Fixture.now)
        guard case let .at(local) = schedule.kind else {
            Issue.record("erwartet .at")
            return
        }
        #expect(local.hour == 22)
        #expect(local.minute == 0)
        #expect(local.day == 2)
        #expect(local.timeZoneIdentifier == "Europe/Vienna")
        #expect(schedule.missedRunPolicy == .skipExpired)
    }

    @Test func pastTimesAndUnknownZonesAreRejected() {
        let past = Fixture.now.addingTimeInterval(-60)
        #expect(throws: ScheduleBuildError.inPast) { try ScheduleForm(choice: .notBefore, date: past).makeSchedule(now: Fixture.now) }
        #expect(throws: ScheduleBuildError.inPast) { try ScheduleForm(choice: .whenQuotaAvailable, date: past).makeSchedule(now: Fixture.now) }
        #expect(throws: ScheduleBuildError.invalidTimeZone("Mars/Olympus")) {
            try ScheduleForm(choice: .at, date: Fixture.now.addingTimeInterval(3_600), timeZoneIdentifier: "Mars/Olympus")
                .makeSchedule(now: Fixture.now)
        }
    }

    @Test func otherScheduleChoices() throws {
        let later = Fixture.now.addingTimeInterval(3_600)
        #expect(try ScheduleForm(choice: .saveOnly, date: later).makeSchedule(now: Fixture.now).kind == .manualPause)
        #expect(try ScheduleForm(choice: .notBefore, date: later).makeSchedule(now: Fixture.now).kind == .notBefore(later))
        let quota = try ScheduleForm(choice: .whenQuotaAvailable, date: later).makeSchedule(now: Fixture.now)
        #expect(try quota.plannedStart() == later)
    }
}
