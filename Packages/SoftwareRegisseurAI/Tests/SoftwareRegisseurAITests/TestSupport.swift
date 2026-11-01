import Foundation
import Synchronization
@testable import SoftwareRegisseurAI

/// Records requests and answers from a queue or handler. Never touches the network.
final class StubHTTPClient: HTTPClient {
    private let state = Mutex<(requests: [URLRequest], queue: [HTTPResponse])>(([], []))
    private let handler: (@Sendable (URLRequest) -> HTTPResponse)?

    init(responses: [HTTPResponse] = [], handler: (@Sendable (URLRequest) -> HTTPResponse)? = nil) {
        self.handler = handler
        state.withLock { $0.queue = responses }
    }

    var requests: [URLRequest] { state.withLock { $0.requests } }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let queued: HTTPResponse? = state.withLock { state in
            state.requests.append(request)
            return state.queue.isEmpty ? nil : state.queue.removeFirst()
        }
        if let queued { return queued }
        if let handler { return handler(request) }
        throw AIProviderError.network("No stubbed response")
    }
}

func jsonResponse(_ status: Int = 200, _ body: String, headers: [String: String] = [:]) -> HTTPResponse {
    HTTPResponse(statusCode: status, headers: headers, body: Data(body.utf8))
}

func bodyJSON(_ request: URLRequest) throws -> JSONValue {
    try JSONValue.parse(request.httpBody ?? Data())
}

/// Text provider stub returning canned output and capturing requests.
final class StubTextProvider: TextAIProvider {
    let providerID: AIProviderID
    private let state = Mutex<(requests: [TextGenerationRequest], outputs: [String])>(([], []))
    let finishReason: FinishReason

    init(providerID: AIProviderID = .anthropic, outputs: [String], finishReason: FinishReason = .completed) {
        self.providerID = providerID
        self.finishReason = finishReason
        state.withLock { $0.outputs = outputs }
    }

    var requests: [TextGenerationRequest] { state.withLock { $0.requests } }

    func listModels() async throws -> [AIModelInfo] { [] }
    func validateAPIKey() async throws -> KeyValidationResult { .valid }

    func generate(_ request: TextGenerationRequest) async throws -> TextGenerationResult {
        let output: String = state.withLock { state in
            state.requests.append(request)
            return state.outputs.isEmpty ? "" : state.outputs.removeFirst()
        }
        return TextGenerationResult(
            provider: providerID, model: request.model, text: output, finishReason: finishReason,
            usage: AIUsage(inputTokens: 100, outputTokens: 50)
        )
    }
}

let fixedNow = Date(timeIntervalSince1970: 1_793_354_400) // 2026-10-30 10:00:00 UTC
