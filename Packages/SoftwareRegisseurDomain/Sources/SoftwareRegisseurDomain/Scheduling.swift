import Foundation

public enum ScheduleError: Error, Hashable, Sendable {
    case invalidTimeZone(String)
    case invalidLocalDateTime(String)
    case invalidBackoffPolicy(String)
}

/// How to resolve a wall-clock time that occurs twice (DST end, e.g. Europe/Vienna 2026-10-25 02:30).
public enum RepeatedTimePolicy: String, Hashable, Sendable, Codable, CaseIterable {
    case earlier
    case later
}

public enum LocalTimeAdjustment: String, Hashable, Sendable, Codable {
    case exact
    /// Wall-clock time skipped by DST start; shifted forward by the gap (02:30 → 03:30).
    case shiftedForwardOverGap
    case ambiguousResolvedEarlier
    case ambiguousResolvedLater
}

public struct ResolvedInstant: Hashable, Sendable {
    public let date: Date
    public let adjustment: LocalTimeAdjustment
}

/// Wall-clock date/time in an IANA time zone (spec K1, K3). Stored as local components so the intended
/// local time survives DST changes; resolved to an instant only when needed.
public struct ZonedLocalDateTime: Hashable, Sendable, Codable {
    public let year: Int
    public let month: Int
    public let day: Int
    public let hour: Int
    public let minute: Int
    public let second: Int
    public let timeZoneIdentifier: String

    public init(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int = 0, timeZoneIdentifier: String) throws(ScheduleError) {
        guard TimeZone(identifier: timeZoneIdentifier) != nil else { throw .invalidTimeZone(timeZoneIdentifier) }
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
        self.timeZoneIdentifier = timeZoneIdentifier
        _ = try naiveSecondsSinceEpoch()
    }

    public var timeZone: TimeZone? { TimeZone(identifier: timeZoneIdentifier) }

    public func resolve(repeatedTimePolicy: RepeatedTimePolicy = .earlier) throws(ScheduleError) -> ResolvedInstant {
        guard let zone = timeZone else { throw .invalidTimeZone(timeZoneIdentifier) }
        let naive = try naiveSecondsSinceEpoch()
        let day: TimeInterval = 86_400
        let offsetBefore = TimeInterval(zone.secondsFromGMT(for: Date(timeIntervalSince1970: naive - day)))
        let offsetAfter = TimeInterval(zone.secondsFromGMT(for: Date(timeIntervalSince1970: naive + day)))

        let candidates = Set([offsetBefore, offsetAfter])
            .map { Date(timeIntervalSince1970: naive - $0) }
            .filter { candidate in
                TimeInterval(zone.secondsFromGMT(for: candidate)) == naive - candidate.timeIntervalSince1970
            }
            .sorted()

        switch candidates.count {
        case 1:
            return ResolvedInstant(date: candidates[0], adjustment: .exact)
        case 2:
            return repeatedTimePolicy == .earlier
                ? ResolvedInstant(date: candidates[0], adjustment: .ambiguousResolvedEarlier)
                : ResolvedInstant(date: candidates[1], adjustment: .ambiguousResolvedLater)
        default:
            // Gap: interpret with the pre-transition offset, which lands after the gap.
            return ResolvedInstant(date: Date(timeIntervalSince1970: naive - offsetBefore), adjustment: .shiftedForwardOverGap)
        }
    }

    /// Components interpreted as UTC; validates that they form a real calendar date/time.
    private func naiveSecondsSinceEpoch() throws(ScheduleError) -> TimeInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: components) else { throw .invalidLocalDateTime(debugDescription) }
        let check = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard check.year == year, check.month == month, check.day == day,
              check.hour == hour, check.minute == minute, check.second == second
        else { throw .invalidLocalDateTime(debugDescription) }
        return date.timeIntervalSince1970
    }

    private var debugDescription: String {
        String(format: "%04d-%02d-%02dT%02d:%02d:%02d %@", year, month, day, hour, minute, second, timeZoneIdentifier)
    }
}

/// Behaviour when the host was off/asleep at the planned time (spec K3).
public enum MissedRunPolicy: String, Hashable, Sendable, Codable, CaseIterable {
    case runImmediatelyWhenAvailable
    case ask
    case skipExpired
}

public enum MissedRunAction: String, Hashable, Sendable, Codable {
    case runNow
    case askUser
    case skip
}

/// Basis for the next quota retry, shown to the user as the documented next attempt (spec K2).
public enum QuotaRetryBasis: String, Hashable, Sendable, Codable {
    case providerSignal
    case userExpectedReset
    case backoff
}

public struct QuotaRetryState: Hashable, Sendable, Codable {
    /// 1-based number of the upcoming retry attempt.
    public let attempt: Int
    public let nextAttemptAt: Date
    public let lastFailureAt: Date
    public let basis: QuotaRetryBasis
    public let providerRetryAfter: Date?
    public let userExpectedReset: Date?

    public init(attempt: Int, nextAttemptAt: Date, lastFailureAt: Date, basis: QuotaRetryBasis, providerRetryAfter: Date? = nil, userExpectedReset: Date? = nil) {
        self.attempt = attempt
        self.nextAttemptAt = nextAttemptAt
        self.lastFailureAt = lastFailureAt
        self.basis = basis
        self.providerRetryAfter = providerRetryAfter
        self.userExpectedReset = userExpectedReset
    }
    /// „Bei Kontingent verfügbar erneut versuchen“ chosen before any quota error (spec J2, K2): start no
    /// earlier than the user's expected reset. `attempt == 0` marks it as a user request, not a retry;
    /// quota errors after the start are planned by `QuotaRetryPlanner` as usual.
    public static func userRequested(expectedReset: Date, requestedAt: Date) -> QuotaRetryState {
        QuotaRetryState(attempt: 0, nextAttemptAt: expectedReset, lastFailureAt: requestedAt,
                        basis: .userExpectedReset, userExpectedReset: expectedReset)
    }

    /// Created by `userRequested` (no quota error happened yet).
    public var isUserRequested: Bool { attempt == 0 }
}

public enum ScheduleKind: Hashable, Sendable, Codable {
    /// `.retryAfterQuota` for a job the user asked to start when quota is available (spec J2).
    public static func whenQuotaAvailable(expectedReset: Date, requestedAt: Date) -> ScheduleKind {
        .retryAfterQuota(.userRequested(expectedReset: expectedReset, requestedAt: requestedAt))
    }

    case immediate
    /// Concrete wall-clock time in an IANA zone.
    case at(ZonedLocalDateTime)
    /// Earliest allowed start; never "missed".
    case notBefore(Date)
    case retryAfterQuota(QuotaRetryState)
    case manualPause
}

public enum ScheduleEvaluation: Hashable, Sendable {
    case runNow
    case waitUntil(Date)
    case paused
    case missed(scheduledFor: Date, action: MissedRunAction)
}

public struct JobSchedule: Hashable, Sendable, Codable {
    public var kind: ScheduleKind
    public var missedRunPolicy: MissedRunPolicy
    /// A run started within this interval after the planned time is not considered missed.
    public var missedRunTolerance: TimeInterval
    public var repeatedTimePolicy: RepeatedTimePolicy

    public init(
        kind: ScheduleKind,
        missedRunPolicy: MissedRunPolicy = .ask,
        missedRunTolerance: TimeInterval = 300,
        repeatedTimePolicy: RepeatedTimePolicy = .earlier
    ) {
        self.kind = kind
        self.missedRunPolicy = missedRunPolicy
        self.missedRunTolerance = missedRunTolerance
        self.repeatedTimePolicy = repeatedTimePolicy
    }

    /// Planned start instant; nil for `immediate` and `manualPause`.
    public func plannedStart() throws(ScheduleError) -> Date? {
        switch kind {
        case .immediate, .manualPause: nil
        case let .at(local): try local.resolve(repeatedTimePolicy: repeatedTimePolicy).date
        case let .notBefore(date): date
        case let .retryAfterQuota(state): state.nextAttemptAt
        }
    }

    /// Pure due-check. Double-start protection is the job state machine's/lock's job, not this one's.
    public func evaluate(at now: Date) throws(ScheduleError) -> ScheduleEvaluation {
        switch kind {
        case .immediate:
            return .runNow
        case .manualPause:
            return .paused
        case let .notBefore(date):
            return now < date ? .waitUntil(date) : .runNow
        case let .retryAfterQuota(state):
            return now < state.nextAttemptAt ? .waitUntil(state.nextAttemptAt) : .runNow
        case let .at(local):
            let planned = try local.resolve(repeatedTimePolicy: repeatedTimePolicy).date
            if now < planned { return .waitUntil(planned) }
            if now.timeIntervalSince(planned) <= missedRunTolerance { return .runNow }
            let action: MissedRunAction =
                switch missedRunPolicy {
                case .runImmediatelyWhenAvailable: .runNow
                case .ask: .askUser
                case .skipExpired: .skip
                }
            return .missed(scheduledFor: planned, action: action)
        }
    }
}

// MARK: - Backoff

/// Bounded exponential backoff with jitter and a maximum number of attempts (spec K2).
public struct BackoffPolicy: Hashable, Sendable, Codable {
    public enum Jitter: String, Hashable, Sendable, Codable, CaseIterable {
        case none
        /// Uniform in `0...delay`.
        case full
        /// Uniform in `delay/2...delay`; keeps a lower bound so retries never hammer the provider.
        case equal
    }

    public let baseDelay: TimeInterval
    public let multiplier: Double
    public let maxDelay: TimeInterval
    public let maxAttempts: Int
    public let jitter: Jitter

    public static let quotaDefault = try! BackoffPolicy(baseDelay: 15 * 60, multiplier: 2, maxDelay: 6 * 3600, maxAttempts: 8, jitter: .equal)

    public init(baseDelay: TimeInterval, multiplier: Double, maxDelay: TimeInterval, maxAttempts: Int, jitter: Jitter) throws(ScheduleError) {
        guard baseDelay > 0, baseDelay.isFinite else { throw .invalidBackoffPolicy("baseDelay must be > 0") }
        guard multiplier >= 1, multiplier.isFinite else { throw .invalidBackoffPolicy("multiplier must be >= 1") }
        guard maxDelay >= baseDelay, maxDelay.isFinite else { throw .invalidBackoffPolicy("maxDelay must be >= baseDelay") }
        guard maxAttempts >= 1 else { throw .invalidBackoffPolicy("maxAttempts must be >= 1") }
        self.baseDelay = baseDelay
        self.multiplier = multiplier
        self.maxDelay = maxDelay
        self.maxAttempts = maxAttempts
        self.jitter = jitter
    }

    private enum CodingKeys: String, CodingKey {
        case baseDelay, multiplier, maxDelay, maxAttempts, jitter
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let baseDelay = try c.decode(TimeInterval.self, forKey: .baseDelay)
        let multiplier = try c.decode(Double.self, forKey: .multiplier)
        let maxDelay = try c.decode(TimeInterval.self, forKey: .maxDelay)
        let maxAttempts = try c.decode(Int.self, forKey: .maxAttempts)
        let jitter = try c.decode(Jitter.self, forKey: .jitter)
        do {
            try self.init(baseDelay: baseDelay, multiplier: multiplier, maxDelay: maxDelay, maxAttempts: maxAttempts, jitter: jitter)
        } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid backoff policy: \(error)"))
        }
    }

    /// Delay before jitter for 1-based `attempt`; nil when attempts are exhausted.
    public func cappedDelay(forAttempt attempt: Int) -> TimeInterval? {
        guard attempt >= 1, attempt <= maxAttempts else { return nil }
        let raw = baseDelay * pow(multiplier, Double(attempt - 1))
        return raw.isFinite ? min(raw, maxDelay) : maxDelay
    }

    public func delay(forAttempt attempt: Int, using generator: inout some RandomNumberGenerator) -> TimeInterval? {
        guard let capped = cappedDelay(forAttempt: attempt) else { return nil }
        switch jitter {
        case .none: return capped
        case .full: return Double.random(in: 0...capped, using: &generator)
        case .equal: return capped / 2 + Double.random(in: 0...(capped / 2), using: &generator)
        }
    }

    public func delay(forAttempt attempt: Int) -> TimeInterval? {
        var generator = SystemRandomNumberGenerator()
        return delay(forAttempt: attempt, using: &generator)
    }
}

public enum QuotaRetryDecision: Hashable, Sendable {
    case retry(QuotaRetryState)
    case giveUp(attempts: Int)
}

/// Plans the next attempt after a quota error (spec K2). An explicit provider retry-after or a
/// user-set expected reset in the future wins over backoff; attempts stay bounded either way.
/// No claim is made that providers expose their reset time.
public struct QuotaRetryPlanner: Hashable, Sendable, Codable {
    public let policy: BackoffPolicy

    public init(policy: BackoffPolicy = .quotaDefault) {
        self.policy = policy
    }

    public func nextAttempt(
        afterFailureAt failureAt: Date,
        previousAttempts: Int,
        providerRetryAfter: Date? = nil,
        userExpectedReset: Date? = nil,
        using generator: inout some RandomNumberGenerator
    ) -> QuotaRetryDecision {
        let attempt = previousAttempts + 1
        guard let backoff = policy.delay(forAttempt: attempt, using: &generator) else {
            return .giveUp(attempts: previousAttempts)
        }

        let signals: [(Date, QuotaRetryBasis)] = [
            providerRetryAfter.map { ($0, .providerSignal) },
            userExpectedReset.map { ($0, .userExpectedReset) },
        ].compactMap { $0 }.filter { $0.0 > failureAt }

        let (next, basis): (Date, QuotaRetryBasis) =
            if let latest = signals.max(by: { $0.0 < $1.0 }) { latest }
            else { (failureAt.addingTimeInterval(backoff), .backoff) }

        return .retry(QuotaRetryState(
            attempt: attempt,
            nextAttemptAt: next,
            lastFailureAt: failureAt,
            basis: basis,
            providerRetryAfter: providerRetryAfter,
            userExpectedReset: userExpectedReset
        ))
    }
}
