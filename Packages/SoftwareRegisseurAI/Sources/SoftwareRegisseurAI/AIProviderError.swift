import Foundation

/// Typed provider errors with German user-facing messages (spec H3 "Providerfehler transparent", I, Q1).
public enum AIProviderError: Error, Sendable, Equatable {
    case missingAPIKey
    case keychainLocked
    case invalidAPIKey
    case permissionDenied(String?)
    case modelNotFound(String?)
    /// Temporary rate limit; `retryAt` from `Retry-After` (or provider reset headers) when known.
    case rateLimited(retryAt: Date?)
    /// Credit, billing or spend limit exhausted. Never retried automatically (research §2.5).
    case quotaExhausted(String?)
    case overloaded(retryAt: Date?)
    case server(statusCode: Int)
    case timeout
    case offline
    case network(String)
    case requestTooLarge
    case fileTooLarge(bytes: Int, limit: Int)
    case unsupportedAudioFormat(String)
    case invalidTranscriptionHint(String)
    case invalidRequest(String)
    case capabilityUnsupported(String)
    /// The model declined to answer (OpenAI refusal item, Anthropic `stop_reason: refusal`, Gemini block).
    case refusal(String?)
    /// Output cut off (token limit) so structured output cannot be trusted.
    case incompleteOutput(String?)
    case invalidResponse(String)
    case cancelled

    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .overloaded, .timeout, .network, .offline:
            return true
        case .server(let status):
            return status >= 500 || status == 408
        default:
            return false
        }
    }

    public var retryAt: Date? {
        switch self {
        case .rateLimited(let date), .overloaded(let date): return date
        default: return nil
        }
    }

    public func userMessage(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        switch self {
        case .missingAPIKey:
            return String(localized: "Kein API-Schlüssel hinterlegt. Bitte in den Einstellungen einen Schlüssel eintragen.", bundle: .module)
        case .keychainLocked:
            return String(localized: "Der Schlüsselbund ist gesperrt. Bitte das Gerät entsperren und erneut versuchen.", bundle: .module)
        case .invalidAPIKey:
            return String(localized: "API-Schlüssel ungültig. Bitte den Schlüssel prüfen oder neu eintragen.", bundle: .module)
        case .permissionDenied(let detail):
            return Self.withDetail(String(localized: "Keine Berechtigung für diese Anfrage.", bundle: .module), detail)
        case .modelNotFound(let model):
            if let model { return String(localized: "Modell „\(model)“ ist für diesen Schlüssel nicht verfügbar.", bundle: .module) }
            return String(localized: "Das gewählte Modell ist für diesen Schlüssel nicht verfügbar.", bundle: .module)
        case .rateLimited(let retryAt):
            if let retryAt {
                return String(localized: "Kontingent erschöpft – erneut versuchen ab \(Self.format(retryAt, now: now, timeZone: timeZone)).", bundle: .module)
            }
            return String(localized: "Kontingent erschöpft – bitte später erneut versuchen.", bundle: .module)
        case .quotaExhausted(let detail):
            return Self.withDetail(
                String(localized: "Guthaben oder Ausgabenlimit beim Anbieter erschöpft. Bitte im Anbieterkonto prüfen; es wird nicht automatisch wiederholt.", bundle: .module),
                detail
            )
        case .overloaded(let retryAt):
            if let retryAt {
                return String(localized: "Der Anbieter ist überlastet – erneut versuchen ab \(Self.format(retryAt, now: now, timeZone: timeZone)).", bundle: .module)
            }
            return String(localized: "Der Anbieter ist derzeit überlastet. Bitte später erneut versuchen.", bundle: .module)
        case .server(let status):
            return String(localized: "Serverfehler beim Anbieter (HTTP \(status)). Bitte später erneut versuchen.", bundle: .module)
        case .timeout:
            return String(localized: "Zeitüberschreitung bei der Anfrage an den Anbieter.", bundle: .module)
        case .offline:
            return String(localized: "Keine Internetverbindung. Die Daten bleiben erhalten; bitte später erneut versuchen.", bundle: .module)
        case .network(let detail):
            return Self.withDetail(String(localized: "Netzwerkfehler.", bundle: .module), detail)
        case .requestTooLarge:
            return String(localized: "Die Anfrage ist zu groß für den Anbieter. Bitte Kontext verkleinern.", bundle: .module)
        case .fileTooLarge(let bytes, let limit):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .decimal
            return String(localized: "Audiodatei zu groß (\(formatter.string(fromByteCount: Int64(bytes))), erlaubt \(formatter.string(fromByteCount: Int64(limit)))). Die Aufnahme wird in Abschnitte geteilt.", bundle: .module)
        case .unsupportedAudioFormat(let format):
            return String(localized: "Audioformat „\(format)“ wird vom Anbieter nicht unterstützt.", bundle: .module)
        case .invalidTranscriptionHint(let hint):
            return String(localized: "Transkriptionshinweis „\(hint)“ enthält unzulässige Zeichen (<, > oder Zeilenumbruch).", bundle: .module)
        case .invalidRequest(let detail):
            return Self.withDetail(String(localized: "Ungültige Anfrage.", bundle: .module), detail)
        case .capabilityUnsupported(let detail):
            return Self.withDetail(String(localized: "Das gewählte Modell unterstützt diese Funktion nicht.", bundle: .module), detail)
        case .refusal(let detail):
            return Self.withDetail(String(localized: "Das Modell hat die Antwort abgelehnt.", bundle: .module), detail)
        case .incompleteOutput(let detail):
            return Self.withDetail(String(localized: "Die Antwort des Modells ist unvollständig (Tokenlimit erreicht).", bundle: .module), detail)
        case .invalidResponse(let detail):
            return Self.withDetail(String(localized: "Unerwartete Antwort des Anbieters.", bundle: .module), detail)
        case .cancelled:
            return String(localized: "Die Anfrage wurde abgebrochen.", bundle: .module)
        }
    }

    private static func withDetail(_ base: String, _ detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return base }
        return "\(base) (\(detail))"
    }

    static func format(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.timeZone = timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm:ss 'Uhr'" : "dd.MM.yyyy HH:mm 'Uhr'"
        return formatter.string(from: date)
    }
}

// MARK: - Retry-After parsing

public enum RetryAfterParser {
    /// Parses `Retry-After` as delta-seconds or HTTP-date.
    public static func parse(_ value: String?, now: Date) -> Date? {
        guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let seconds = Double(raw), seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }

    /// Parses RFC 3339 timestamps (Anthropic `anthropic-ratelimit-*-reset`).
    public static func parseRFC3339(_ value: String?) -> Date? {
        guard let value else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }

    /// Google `RetryInfo.retryDelay` duration strings such as "30s" or "1.5s".
    public static func parseProtobufDuration(_ value: String?) -> TimeInterval? {
        guard let value, value.hasSuffix("s") else { return nil }
        return Double(value.dropLast())
    }
}

// MARK: - Retry policy

/// Bounded exponential backoff with jitter; honours `retryAt`; never retries quota/billing,
/// auth or request errors (research §2.5).
public struct RetryPolicy: Sendable {
    public var maxAttempts: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    /// Upper bound for a server-requested wait; longer waits are surfaced to the user instead.
    public var maxServerRequestedDelay: TimeInterval
    public var jitterRatio: Double

    public init(
        maxAttempts: Int = 3,
        baseDelay: TimeInterval = 1,
        maxDelay: TimeInterval = 20,
        maxServerRequestedDelay: TimeInterval = 60,
        jitterRatio: Double = 0.2
    ) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.maxServerRequestedDelay = maxServerRequestedDelay
        self.jitterRatio = jitterRatio
    }

    public static let none = RetryPolicy(maxAttempts: 1)

    /// Delay before the next attempt, or `nil` when the error must be surfaced.
    /// `attempt` is the 1-based number of the attempt that just failed; `jitter` in 0...1.
    public func delay(afterAttempt attempt: Int, error: AIProviderError, now: Date, jitter: Double) -> TimeInterval? {
        guard attempt < maxAttempts, error.isRetryable else { return nil }
        let jitterFactor = 1 + jitterRatio * min(max(jitter, 0), 1)
        if let retryAt = error.retryAt {
            let wait = retryAt.timeIntervalSince(now)
            guard wait <= maxServerRequestedDelay else { return nil }
            return max(wait, 0) * jitterFactor
        }
        let exponential = baseDelay * pow(2, Double(attempt - 1))
        return min(exponential, maxDelay) * jitterFactor
    }

    public func run<T: Sendable>(
        now: @Sendable () -> Date = { Date() },
        jitter: @Sendable () -> Double = { Double.random(in: 0...1) },
        sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch let error as AIProviderError {
                guard let wait = delay(afterAttempt: attempt, error: error, now: now(), jitter: jitter()) else {
                    throw error
                }
                try await sleep(wait)
                attempt += 1
            }
        }
    }
}
