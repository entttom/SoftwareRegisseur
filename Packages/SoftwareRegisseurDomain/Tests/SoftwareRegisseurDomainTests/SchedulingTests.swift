import Foundation
import Testing
@testable import SoftwareRegisseurDomain

private let vienna = "Europe/Vienna"

private func local(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int, zone: String = vienna) throws -> ZonedLocalDateTime {
    try ZonedLocalDateTime(year: y, month: m, day: d, hour: h, minute: min, timeZoneIdentifier: zone)
}

@Suite("Scheduling with IANA time zones (spec K1/K3, A17/A18)")
struct SchedulingTests {
    @Test func regularTimesAroundAutumnDSTChange() throws {
        // 2026-10-25: CEST (+2) → CET (+1) at 03:00 local.
        let before = try local(2026, 10, 24, 7, 0).resolve()
        let after = try local(2026, 10, 25, 7, 0).resolve()
        #expect(before == ResolvedInstant(date: utc("2026-10-24T05:00:00Z"), adjustment: .exact))
        #expect(after == ResolvedInstant(date: utc("2026-10-25T06:00:00Z"), adjustment: .exact))
        #expect(after.date.timeIntervalSince(before.date) == 25 * 3600)
    }

    @Test func repeatedHourOnAutumnDSTChange() throws {
        let ambiguous = try local(2026, 10, 25, 2, 30)
        #expect(try ambiguous.resolve(repeatedTimePolicy: .earlier)
            == ResolvedInstant(date: utc("2026-10-25T00:30:00Z"), adjustment: .ambiguousResolvedEarlier))
        #expect(try ambiguous.resolve(repeatedTimePolicy: .later)
            == ResolvedInstant(date: utc("2026-10-25T01:30:00Z"), adjustment: .ambiguousResolvedLater))
    }

    @Test func regularTimesAroundSpringDSTChange() throws {
        // 2027-03-28: CET (+1) → CEST (+2) at 02:00 local.
        let before = try local(2027, 3, 27, 7, 0).resolve()
        let after = try local(2027, 3, 28, 7, 0).resolve()
        #expect(before.date == utc("2027-03-27T06:00:00Z"))
        #expect(after.date == utc("2027-03-28T05:00:00Z"))
        #expect(after.date.timeIntervalSince(before.date) == 23 * 3600)
    }

    @Test func skippedHourOnSpringDSTChangeShiftsForward() throws {
        let gap = try local(2027, 3, 28, 2, 30).resolve()
        #expect(gap == ResolvedInstant(date: utc("2027-03-28T01:30:00Z"), adjustment: .shiftedForwardOverGap))
        // 01:59 and 03:00 are regular.
        #expect(try local(2027, 3, 28, 1, 59).resolve().date == utc("2027-03-28T00:59:00Z"))
        #expect(try local(2027, 3, 28, 3, 0).resolve().date == utc("2027-03-28T01:00:00Z"))
    }

    @Test func otherZonesAreIndependent() throws {
        let newYork = try local(2026, 10, 25, 7, 0, zone: "America/New_York").resolve()
        #expect(newYork == ResolvedInstant(date: utc("2026-10-25T11:00:00Z"), adjustment: .exact))
    }

    @Test func invalidInputIsRejected() {
        #expect(throws: ScheduleError.invalidTimeZone("Mars/Olympus")) { try local(2026, 10, 25, 7, 0, zone: "Mars/Olympus") }
        #expect(throws: ScheduleError.self) { try local(2027, 2, 30, 7, 0) }
        #expect(throws: ScheduleError.self) { try local(2026, 10, 25, 24, 0) }
    }

    @Test func localTimeAndZoneSurviveCodable() throws {
        let schedule = JobSchedule(kind: .at(try local(2026, 10, 25, 2, 30)), missedRunPolicy: .skipExpired, repeatedTimePolicy: .later)
        let decoded = try roundTrip(schedule)
        #expect(decoded == schedule)
        #expect(try decoded.plannedStart() == utc("2026-10-25T01:30:00Z"))
    }

    @Test func evaluateAtSchedule() throws {
        let planned = utc("2026-10-31T06:00:00Z") // 07:00 Vienna (CET)
        let at = ScheduleKind.at(try local(2026, 10, 31, 7, 0))
        let schedule = JobSchedule(kind: at, missedRunPolicy: .ask, missedRunTolerance: 300)
        #expect(try schedule.evaluate(at: planned.addingTimeInterval(-60)) == .waitUntil(planned))
        #expect(try schedule.evaluate(at: planned) == .runNow)
        #expect(try schedule.evaluate(at: planned.addingTimeInterval(300)) == .runNow)
        #expect(try schedule.evaluate(at: planned.addingTimeInterval(301)) == .missed(scheduledFor: planned, action: .askUser))
    }

    @Test(arguments: [
        (MissedRunPolicy.runImmediatelyWhenAvailable, MissedRunAction.runNow),
        (.ask, .askUser),
        (.skipExpired, .skip),
    ])
    func missedRunPolicies(policy: MissedRunPolicy, action: MissedRunAction) throws {
        let schedule = JobSchedule(kind: .at(try local(2026, 10, 31, 22, 0)), missedRunPolicy: policy)
        let macBackOnline = utc("2026-11-01T08:00:00Z")
        #expect(try schedule.evaluate(at: macBackOnline) == .missed(scheduledFor: utc("2026-10-31T21:00:00Z"), action: action))
    }

    @Test func otherKinds() throws {
        let limit = utc("2026-11-01T00:00:00Z")
        #expect(try JobSchedule(kind: .immediate).evaluate(at: limit) == .runNow)
        #expect(try JobSchedule(kind: .manualPause).evaluate(at: limit) == .paused)
        #expect(try JobSchedule(kind: .immediate).plannedStart() == nil)
        let notBefore = JobSchedule(kind: .notBefore(limit), missedRunPolicy: .skipExpired)
        #expect(try notBefore.evaluate(at: limit.addingTimeInterval(-1)) == .waitUntil(limit))
        // An earliest-start constraint is never missed.
        #expect(try notBefore.evaluate(at: limit.addingTimeInterval(86_400)) == .runNow)
        let retry = QuotaRetryState(attempt: 2, nextAttemptAt: limit, lastFailureAt: limit.addingTimeInterval(-600), basis: .backoff)
        #expect(try JobSchedule(kind: .retryAfterQuota(retry)).evaluate(at: limit.addingTimeInterval(-5)) == .waitUntil(limit))
        #expect(try JobSchedule(kind: .retryAfterQuota(retry)).evaluate(at: limit) == .runNow)
    }
}

@Suite("Quota backoff (spec K2, A19)")
struct BackoffTests {
    let policy = try! BackoffPolicy(baseDelay: 60, multiplier: 2, maxDelay: 600, maxAttempts: 5, jitter: .equal)

    @Test func cappedExponentialSequenceAndMaxAttempts() {
        #expect((1...5).map { policy.cappedDelay(forAttempt: $0) } == [60, 120, 240, 480, 600])
        #expect(policy.cappedDelay(forAttempt: 0) == nil)
        #expect(policy.cappedDelay(forAttempt: 6) == nil)
    }

    @Test(arguments: [BackoffPolicy.Jitter.none, .full, .equal])
    func jitterStaysWithinBounds(jitter: BackoffPolicy.Jitter) throws {
        let policy = try BackoffPolicy(baseDelay: 60, multiplier: 2, maxDelay: 600, maxAttempts: 5, jitter: jitter)
        for seed in UInt64(0)..<200 {
            var rng = SplitMix64(seed: seed)
            for attempt in 1...5 {
                let capped = try #require(policy.cappedDelay(forAttempt: attempt))
                let delay = try #require(policy.delay(forAttempt: attempt, using: &rng))
                let lower: TimeInterval = switch jitter {
                case .none: capped
                case .full: 0
                case .equal: capped / 2
                }
                #expect(delay >= lower && delay <= capped, "attempt \(attempt) delay \(delay)")
                #expect(delay <= 600)
            }
            #expect(policy.delay(forAttempt: 6, using: &rng) == nil)
        }
    }

    @Test func jitterIsDeterministicWithInjectedRandomSource() {
        var a = SplitMix64(seed: 42)
        var b = SplitMix64(seed: 42)
        #expect(policy.delay(forAttempt: 3, using: &a) == policy.delay(forAttempt: 3, using: &b))
    }

    @Test func hugeAttemptCountsStayCapped() throws {
        let long = try BackoffPolicy(baseDelay: 60, multiplier: 10, maxDelay: 3600, maxAttempts: 5000, jitter: .none)
        #expect(long.cappedDelay(forAttempt: 5000) == 3600)
    }

    @Test func invalidPoliciesAreRejected() {
        #expect(throws: ScheduleError.self) { try BackoffPolicy(baseDelay: 0, multiplier: 2, maxDelay: 10, maxAttempts: 3, jitter: .none) }
        #expect(throws: ScheduleError.self) { try BackoffPolicy(baseDelay: 10, multiplier: 0.5, maxDelay: 10, maxAttempts: 3, jitter: .none) }
        #expect(throws: ScheduleError.self) { try BackoffPolicy(baseDelay: 10, multiplier: 2, maxDelay: 5, maxAttempts: 3, jitter: .none) }
        #expect(throws: ScheduleError.self) { try BackoffPolicy(baseDelay: 10, multiplier: 2, maxDelay: 50, maxAttempts: 0, jitter: .none) }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(BackoffPolicy.self, from: Data(#"{"baseDelay":0,"multiplier":2,"maxDelay":10,"maxAttempts":1,"jitter":"none"}"#.utf8))
        }
    }

    @Test func plannerUsesBackoffAndGivesUp() throws {
        let planner = QuotaRetryPlanner(policy: policy)
        var rng = SplitMix64(seed: 7)
        let failure = referenceDate
        guard case let .retry(first) = planner.nextAttempt(afterFailureAt: failure, previousAttempts: 0, using: &rng) else {
            Issue.record("expected retry"); return
        }
        #expect(first.attempt == 1)
        #expect(first.basis == .backoff)
        let wait = first.nextAttemptAt.timeIntervalSince(failure)
        #expect(wait >= 30 && wait <= 60)
        #expect(planner.nextAttempt(afterFailureAt: failure, previousAttempts: 5, using: &rng) == .giveUp(attempts: 5))
    }

    @Test func plannerHonoursExplicitSignalsInTheFuture() throws {
        let planner = QuotaRetryPlanner(policy: policy)
        var rng = SplitMix64(seed: 1)
        let failure = referenceDate
        let provider = failure.addingTimeInterval(3600)
        let user = failure.addingTimeInterval(7200)

        let both = planner.nextAttempt(afterFailureAt: failure, previousAttempts: 1, providerRetryAfter: provider, userExpectedReset: user, using: &rng)
        guard case let .retry(state) = both else { Issue.record("expected retry"); return }
        #expect(state.nextAttemptAt == user)
        #expect(state.basis == .userExpectedReset)
        #expect(state.attempt == 2)

        let providerOnly = planner.nextAttempt(afterFailureAt: failure, previousAttempts: 1, providerRetryAfter: provider, using: &rng)
        guard case let .retry(providerState) = providerOnly else { Issue.record("expected retry"); return }
        #expect(providerState.nextAttemptAt == provider)
        #expect(providerState.basis == .providerSignal)

        // A reset time already in the past is ignored in favour of backoff (no immediate hammering).
        let stale = planner.nextAttempt(afterFailureAt: failure, previousAttempts: 1, userExpectedReset: failure.addingTimeInterval(-60), using: &rng)
        guard case let .retry(staleState) = stale else { Issue.record("expected retry"); return }
        #expect(staleState.basis == .backoff)
        #expect(staleState.nextAttemptAt > failure)

        // Explicit signals do not lift the attempt limit.
        #expect(planner.nextAttempt(afterFailureAt: failure, previousAttempts: 5, providerRetryAfter: provider, using: &rng) == .giveUp(attempts: 5))
    }
}
