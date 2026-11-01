import Foundation

/// Maps non-2xx provider responses to `AIProviderError` (research §2.5). Status **and** the
/// provider error code are evaluated because 429 covers both rate limits and exhausted credit.
enum ProviderErrorMapper {
    // MARK: OpenAI

    static let openAIQuotaCodes: Set<String> = [
        "insufficient_quota", "credit_balance_exhausted",
        "organization_spend_limit_exceeded", "project_spend_limit_exceeded", "billing_hard_limit_reached",
    ]

    static func openAI(_ response: HTTPResponse, now: Date) -> AIProviderError {
        let error = (try? JSONValue.parse(response.body))?["error"]
        let code = error?["code"]?.stringValue
        let type = error?["type"]?.stringValue
        let message = error?["message"]?.stringValue
        let retryAt = RetryAfterParser.parse(response.header("retry-after"), now: now)

        switch response.statusCode {
        case 401:
            return .invalidAPIKey
        case 403:
            return .permissionDenied(message)
        case 404:
            return code == "model_not_found" ? .modelNotFound(nil) : .invalidRequest(message ?? "HTTP \(response.statusCode)")
        case 413:
            return .requestTooLarge
        case 429:
            if let code, openAIQuotaCodes.contains(code) { return .quotaExhausted(message) }
            if let type, openAIQuotaCodes.contains(type) { return .quotaExhausted(message) }
            return .rateLimited(retryAt: retryAt)
        case 400, 422:
            if code == "model_not_found" { return .modelNotFound(nil) }
            return .invalidRequest(message ?? "HTTP \(response.statusCode)")
        case 408:
            return .timeout
        case 503:
            return .overloaded(retryAt: retryAt)
        default:
            return response.statusCode >= 500 ? .server(statusCode: response.statusCode)
                : .invalidRequest(message ?? "HTTP \(response.statusCode)")
        }
    }

    // MARK: Anthropic

    static func anthropic(_ response: HTTPResponse, now: Date) -> AIProviderError {
        let error = (try? JSONValue.parse(response.body))?["error"]
        let type = error?["type"]?.stringValue
        let message = error?["message"]?.stringValue
        let retryAt = RetryAfterParser.parse(response.header("retry-after"), now: now)

        switch (response.statusCode, type) {
        case (401, _), (_, "authentication_error"):
            return .invalidAPIKey
        case (402, _), (_, "billing_error"):
            return .quotaExhausted(message)
        case (403, _), (_, "permission_error"):
            return .permissionDenied(message)
        case (404, _), (_, "not_found_error"):
            return .modelNotFound(nil)
        case (413, _), (_, "request_too_large"):
            return .requestTooLarge
        case (429, _), (_, "rate_limit_error"):
            // A spend-cap 429 carries no retry-after and keeps failing until released, so it
            // must not be retried automatically (research §2.5). Fall back to reset headers
            // only when a limit is visibly at zero.
            if let retryAt { return .rateLimited(retryAt: retryAt) }
            if let reset = anthropicExhaustedReset(response) { return .rateLimited(retryAt: reset) }
            return .quotaExhausted(message)
        case (529, _), (_, "overloaded_error"):
            return .overloaded(retryAt: retryAt)
        case (504, _), (_, "timeout_error"):
            return .timeout
        case (400, _), (_, "invalid_request_error"):
            return .invalidRequest(message ?? "HTTP \(response.statusCode)")
        default:
            return response.statusCode >= 500 ? .server(statusCode: response.statusCode)
                : .invalidRequest(message ?? "HTTP \(response.statusCode)")
        }
    }

    /// Latest reset time among `anthropic-ratelimit-*` families whose `remaining` is 0.
    static func anthropicExhaustedReset(_ response: HTTPResponse) -> Date? {
        let families = ["requests", "tokens", "input-tokens", "output-tokens"]
        let resets = families.compactMap { family -> Date? in
            guard response.header("anthropic-ratelimit-\(family)-remaining") == "0" else { return nil }
            return RetryAfterParser.parseRFC3339(response.header("anthropic-ratelimit-\(family)-reset"))
        }
        return resets.max()
    }

    // MARK: Gemini

    static func gemini(_ response: HTTPResponse, now: Date) -> AIProviderError {
        let error = (try? JSONValue.parse(response.body))?["error"]
        let status = error?["status"]?.stringValue
        let message = error?["message"]?.stringValue
        let details = error?["details"]?.arrayValue ?? []
        let reasons = details.compactMap { $0["reason"]?.stringValue }

        // Gemini does not document Retry-After (research §2.5, "nicht belegt"); honour it if
        // present, otherwise use google.rpc.RetryInfo when the error carries one.
        var retryAt = RetryAfterParser.parse(response.header("retry-after"), now: now)
        if retryAt == nil,
           let delay = details.lazy.compactMap({ RetryAfterParser.parseProtobufDuration($0["retryDelay"]?.stringValue) }).first {
            retryAt = now.addingTimeInterval(delay)
        }

        if reasons.contains("API_KEY_INVALID") || (message?.localizedCaseInsensitiveContains("API key not valid") ?? false) {
            return .invalidAPIKey
        }
        switch (response.statusCode, status) {
        case (401, _), (_, "UNAUTHENTICATED"):
            return .invalidAPIKey
        case (403, _), (_, "PERMISSION_DENIED"):
            return .permissionDenied(message)
        case (404, _), (_, "NOT_FOUND"):
            return .modelNotFound(nil)
        case (429, _), (_, "RESOURCE_EXHAUSTED"):
            return .rateLimited(retryAt: retryAt)
        case (503, _), (_, "UNAVAILABLE"):
            return .overloaded(retryAt: retryAt)
        case (504, _), (408, _), (_, "DEADLINE_EXCEEDED"):
            return .timeout
        case (400, _), (_, "INVALID_ARGUMENT"), (_, "FAILED_PRECONDITION"):
            return .invalidRequest(message ?? "HTTP \(response.statusCode)")
        default:
            return response.statusCode >= 500 ? .server(statusCode: response.statusCode)
                : .invalidRequest(message ?? "HTTP \(response.statusCode)")
        }
    }
}
