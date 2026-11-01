import Foundation

/// German planning status texts shared by iPhone and Mac (spec K3: „für 22:00 geplant, Mac zuletzt
/// online 21:30“ statt „läuft“; K2: documented next quota attempt).
public enum ScheduleStatusText {
    public static func planned(_ planned: Date, hostLastSeen: Date?, now: Date, timeZone: TimeZone) -> String {
        let time = format(planned, now: now, timeZone: timeZone)
        guard let hostLastSeen else {
            return String(localized: "für \(time) geplant", bundle: .module)
        }
        let seen = format(hostLastSeen, now: now, timeZone: timeZone)
        return String(localized: "für \(time) geplant, Mac zuletzt online \(seen)", bundle: .module)
    }

    public static func quota(_ state: QuotaRetryState, now: Date, timeZone: TimeZone) -> String {
        let basis = switch state.basis {
        case .providerSignal: String(localized: "vom Anbieter gemeldet", bundle: .module)
        case .userExpectedReset: String(localized: "erwarteter Reset laut Benutzer", bundle: .module)
        case .backoff: String(localized: "begrenzter Backoff, Versuch \(state.attempt)", bundle: .module)
        }
        let next = format(state.nextAttemptAt, now: now, timeZone: timeZone)
        if state.isUserRequested {
            return String(localized: "Start bei verfügbarem Kontingent, frühestens \(next) (\(basis))", bundle: .module)
        }
        return String(localized: "wartet auf Kontingent – nächster Versuch \(next) (\(basis))", bundle: .module)
    }

    public static func policy(_ policy: MissedRunPolicy) -> String {
        switch policy {
        case .runImmediatelyWhenAvailable: String(localized: "sofort nachholen", bundle: .module)
        case .ask: String(localized: "nachfragen", bundle: .module)
        case .skipExpired: String(localized: "verpassten Termin überspringen", bundle: .module)
        }
    }

    /// Missed run (spec K3): planned time, last contact of the Mac and the catch-up rule.
    public static func missed(scheduledFor: Date, hostLastSeen: Date?, policy: MissedRunPolicy, now: Date, timeZone: TimeZone) -> String {
        let planned = planned(scheduledFor, hostLastSeen: hostLastSeen, now: now, timeZone: timeZone)
        let rule = Self.policy(policy)
        return String(localized: "\(planned) – Termin verpasst, Nachholregel: \(rule)", bundle: .module)
    }

    /// Job waits for its Mac host, which was last online at `hostLastSeen`.
    public static func waitingForHost(hostLastSeen: Date?, now: Date, timeZone: TimeZone) -> String {
        guard let hostLastSeen else { return String(localized: "wartet auf den Mac", bundle: .module) }
        let seen = format(hostLastSeen, now: now, timeZone: timeZone)
        return String(localized: "wartet auf den Mac, zuletzt online \(seen)", bundle: .module)
    }

    /// Planning text for a job from synced data only (iPhone and Mac UI); nil when the job state itself
    /// is the best description (running, finished, …). `timeZone` is used unless the job was planned in
    /// an explicit IANA zone.
    public static func status(for job: AgentJob, hostLastSeen: Date?, now: Date, timeZone: TimeZone = .current) -> String? {
        let zone = Self.timeZone(of: job.schedule) ?? timeZone
        switch job.state {
        case .waitingQuota:
            if case let .retryAfterQuota(state) = job.schedule.kind { return quota(state, now: now, timeZone: zone) }
            return nil
        case .requested, .pendingMac, .scheduled:
            if case let .retryAfterQuota(state) = job.schedule.kind, state.nextAttemptAt > now {
                return quota(state, now: now, timeZone: zone)
            }
            if let planned = job.scheduledAt, planned > now {
                return self.planned(planned, hostLastSeen: hostLastSeen, now: now, timeZone: zone)
            }
            if job.state != .scheduled { return waitingForHost(hostLastSeen: hostLastSeen, now: now, timeZone: zone) }
            return nil
        default:
            return nil
        }
    }

    /// IANA zone of an `.at` schedule.
    public static func timeZone(of schedule: JobSchedule) -> TimeZone? {
        if case let .at(local) = schedule.kind { return local.timeZone }
        return nil
    }

    /// `HH:mm` on the same local day as `now`, otherwise `dd.MM. HH:mm` (de_AT).
    public static func format(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_AT")
        formatter.timeZone = timeZone
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "dd.MM. HH:mm"
        return formatter.string(from: date)
    }
}
