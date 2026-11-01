import Foundation
import Testing
import SoftwareRegisseurSecrets
@testable import SoftwareRegisseurAI

private let schema = StructuredOutputFormat(name: "test_schema", schema: DraftSchema.draftList)
private let noRetry = AIClientConfiguration(retryPolicy: .none)

private func sampleRequest(model: String) -> TextGenerationRequest {
    TextGenerationRequest(
        model: model,
        systemPrompt: "SYSTEM",
        messages: [.user("Hallo"), .assistant("Hi"), .user("Weiter")],
        structuredOutput: schema,
        maxOutputTokens: 1234
    )
}

// MARK: - OpenAI

@Suite("OpenAI Responses client")
struct OpenAITextClientTests {
    let key = SecretValue("sk-test-openai-key")

    @Test func requestShape() async throws {
        let http = StubHTTPClient(responses: [jsonResponse(200, #"{"status":"completed","output":[]}"#)])
        let client = OpenAITextClient(
            connection: OpenAIConnection(apiKey: key, projectID: "proj_1"), http: http, configuration: noRetry
        )
        _ = try await client.generate(sampleRequest(model: "gpt-6.1-sol"))

        let request = try #require(http.requests.first)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-openai-key")
        #expect(request.value(forHTTPHeaderField: "OpenAI-Project") == "proj_1")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try bodyJSON(request)
        #expect(body["model"] == "gpt-6.1-sol")
        #expect(body["instructions"] == "SYSTEM")
        #expect(body["max_output_tokens"] == 1234)
        #expect(body["store"] == false)
        #expect(body["input"]?.arrayValue?.count == 3)
        #expect(body["input"]?[1]?["role"] == "assistant")
        let format = try #require(body["text"]?["format"])
        #expect(format["type"] == "json_schema")
        #expect(format["name"] == "test_schema")
        #expect(format["strict"] == true)
        #expect(format["schema"] == DraftSchema.draftList)
        #expect(body["temperature"] == nil)
    }

    @Test func parsesOutputUsageAndRefusal() throws {
        let response = jsonResponse(200, """
        {"id":"resp_1","object":"response","status":"completed","model":"gpt-6.1-sol",
         "output":[{"type":"reasoning","id":"rs_1","summary":[]},
                   {"type":"message","role":"assistant","content":[{"type":"output_text","text":"{\\"drafts\\":[]}","annotations":[]}]}],
         "usage":{"input_tokens":120,"input_tokens_details":{"cached_tokens":20},"output_tokens":80,
                  "output_tokens_details":{"reasoning_tokens":30},"total_tokens":200}}
        """, headers: ["x-request-id": "req_abc"])
        let result = try OpenAITextClient.parse(response, model: "x")
        #expect(result.text == #"{"drafts":[]}"#)
        #expect(result.finishReason == .completed)
        #expect(result.usage == AIUsage(inputTokens: 120, outputTokens: 80, cachedInputTokens: 20, reasoningTokens: 30))
        #expect(result.requestID == "req_abc")

        let refusal = try OpenAITextClient.parse(jsonResponse(200, """
        {"status":"completed","output":[{"type":"message","content":[{"type":"refusal","refusal":"Kann ich nicht."}]}]}
        """), model: "x")
        #expect(throws: AIProviderError.refusal("Kann ich nicht.")) { try refusal.decodeStructured(DraftList.self) }

        let incomplete = try OpenAITextClient.parse(jsonResponse(200, """
        {"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[{"type":"message","content":[{"type":"output_text","text":"{\\"dra"}]}]}
        """), model: "x")
        #expect(incomplete.finishReason == .maxTokens)
        #expect(throws: AIProviderError.incompleteOutput(nil)) { try incomplete.decodeStructured(DraftList.self) }
    }

    @Test func modelListParsing() async throws {
        let http = StubHTTPClient(responses: [jsonResponse(200, """
        {"object":"list","data":[
          {"id":"gpt-transcribe","object":"model","created":1790000000,"owned_by":"system","shutdown_date":null},
          {"id":"gpt-4o-transcribe","object":"model","created":1700000000,"owned_by":"system","shutdown_date":"2027-02-26"},
          {"id":"gpt-6-luna","object":"model","created":1791000000,"owned_by":"system"}
        ]}
        """)])
        let table = LocalCapabilityTable(entries: ["gpt-6-luna": AIModelCapabilities(textGeneration: .supported, structuredOutput: .supported)])
        let client = OpenAITextClient(
            connection: OpenAIConnection(apiKey: key), http: http,
            configuration: AIClientConfiguration(retryPolicy: .none, capabilityTable: table)
        )
        let models = try await client.listModels()
        #expect(http.requests.first?.url?.absoluteString == "https://api.openai.com/v1/models")
        #expect(http.requests.first?.httpMethod == "GET")
        #expect(models.map(\.id) == ["gpt-transcribe", "gpt-4o-transcribe", "gpt-6-luna"])
        #expect(models[0].capabilities == .unknown)
        #expect(models[0].lifecycle == .active)
        #expect(models[1].lifecycle == .deprecated)
        let shutdown = try #require(models[1].shutdownDate)
        #expect(Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: shutdown).year == 2027)
        #expect(models[2].capabilities.structuredOutput == .supported)
        #expect(models[2].capabilities.thinking == .unknown)
    }

    @Test func keyValidation() async throws {
        let ok = OpenAITextClient(
            connection: OpenAIConnection(apiKey: key),
            http: StubHTTPClient(responses: [jsonResponse(200, #"{"object":"list","data":[]}"#)]), configuration: noRetry
        )
        #expect(try await ok.validateAPIKey() == .valid)

        let bad = OpenAITextClient(
            connection: OpenAIConnection(apiKey: key),
            http: StubHTTPClient(responses: [jsonResponse(401, #"{"error":{"message":"Incorrect API key provided","type":"invalid_request_error","code":"invalid_api_key"}}"#)]),
            configuration: noRetry
        )
        #expect(try await bad.validateAPIKey() == .invalid)

        let missing = OpenAITextClient(connection: OpenAIConnection(apiKey: SecretValue("  ")), http: StubHTTPClient(), configuration: noRetry)
        await #expect(throws: AIProviderError.missingAPIKey) { try await missing.listModels() }
    }

    @Test func errorMapping() {
        let invalid = ProviderErrorMapper.openAI(jsonResponse(401, #"{"error":{"message":"bad","code":"invalid_api_key"}}"#), now: fixedNow)
        #expect(invalid == .invalidAPIKey)
        #expect(invalid.userMessage().hasPrefix("API-Schlüssel ungültig"))

        let limited = ProviderErrorMapper.openAI(
            jsonResponse(429, #"{"error":{"message":"Rate limit reached","type":"requests","code":"rate_limit_exceeded"}}"#,
                         headers: ["Retry-After": "20"]),
            now: fixedNow
        )
        #expect(limited == .rateLimited(retryAt: fixedNow.addingTimeInterval(20)))
        #expect(limited.isRetryable)
        let message = limited.userMessage(now: fixedNow, timeZone: TimeZone(identifier: "UTC")!)
        #expect(message.hasPrefix("Kontingent erschöpft – erneut versuchen ab "))
        #expect(message.contains("10:00:20"))

        for code in ["insufficient_quota", "credit_balance_exhausted", "project_spend_limit_exceeded"] {
            let quota = ProviderErrorMapper.openAI(jsonResponse(429, #"{"error":{"message":"m","code":"\#(code)"}}"#), now: fixedNow)
            #expect(quota == .quotaExhausted("m"))
            #expect(!quota.isRetryable)
        }
        #expect(ProviderErrorMapper.openAI(jsonResponse(503, #"{"error":{"code":"server_is_overloaded"}}"#), now: fixedNow) == .overloaded(retryAt: nil))
        #expect(ProviderErrorMapper.openAI(jsonResponse(404, #"{"error":{"code":"model_not_found","message":"x"}}"#), now: fixedNow) == .modelNotFound(nil))
    }
}

// MARK: - Anthropic

@Suite("Anthropic Messages client")
struct AnthropicTextClientTests {
    let key = SecretValue("sk-ant-test-key")

    @Test func requestShapeWithoutSamplingParameters() async throws {
        let http = StubHTTPClient(responses: [jsonResponse(200, #"{"type":"message","content":[],"stop_reason":"end_turn"}"#)])
        let client = AnthropicTextClient(apiKey: key, http: http, configuration: noRetry)
        _ = try await client.generate(sampleRequest(model: "claude-sonnet-5-5"))

        let request = try #require(http.requests.first)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-ant-test-key")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)

        let body = try bodyJSON(request)
        #expect(body["model"] == "claude-sonnet-5-5")
        #expect(body["max_tokens"] == 1234)
        #expect(body["system"] == "SYSTEM")
        #expect(body["messages"]?.arrayValue?.count == 3)
        #expect(body["output_config"]?["format"]?["type"] == "json_schema")
        #expect(body["output_config"]?["format"]?["schema"] == DraftSchema.draftList)
        for forbidden in ["temperature", "top_p", "top_k"] {
            #expect(body[forbidden] == nil, "\(forbidden) must never be sent")
        }
    }

    @Test func legacyHeaderScheme() async throws {
        let http = StubHTTPClient(responses: [jsonResponse(200, #"{"data":[],"has_more":false}"#)])
        let client = AnthropicTextClient(apiKey: key, http: http, configuration: noRetry, authScheme: .xAPIKey)
        #expect(try await client.validateAPIKey() == .valid)
        let request = try #require(http.requests.first)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test-key")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/models?limit=1")
    }

    @Test func parsesMessageUsageAndStopReasons() throws {
        let result = try AnthropicTextClient.parse(jsonResponse(200, """
        {"id":"msg_1","type":"message","role":"assistant","model":"claude-sonnet-5-5",
         "content":[{"type":"thinking","thinking":"…"},{"type":"text","text":"{\\"drafts\\":"},{"type":"text","text":"[]}"}],
         "stop_reason":"end_turn",
         "usage":{"input_tokens":50,"cache_creation_input_tokens":10,"cache_read_input_tokens":40,"output_tokens":70,"service_tier":"standard"}}
        """, headers: ["request-id": "req_1"]), model: "x")
        #expect(result.text == #"{"drafts":[]}"#)
        #expect(result.usage.inputTokens == 100)
        #expect(result.usage.cachedInputTokens == 40)
        #expect(result.usage.cacheWriteInputTokens == 10)
        #expect(result.usage.outputTokens == 70)
        #expect(result.requestID == "req_1")
        #expect(try result.decodeStructured(DraftList.self).drafts.isEmpty)

        let refusal = try AnthropicTextClient.parse(jsonResponse(200, #"{"content":[],"stop_reason":"refusal"}"#), model: "x")
        #expect(throws: AIProviderError.refusal(nil)) { try refusal.decodeStructured(DraftList.self) }
        let cut = try AnthropicTextClient.parse(jsonResponse(200, #"{"content":[{"type":"text","text":"{"}],"stop_reason":"max_tokens"}"#), model: "x")
        #expect(cut.finishReason == .maxTokens)
    }

    @Test func modelListWithCapabilitiesAndPagination() async throws {
        let page1 = """
        {"data":[{"type":"model","id":"claude-opus-5-5","display_name":"Claude Opus 5.5","created_at":"2026-09-01T00:00:00Z",
                  "lifecycle":"active","deprecated_at":null,"retires_at":null,"line":"opus",
                  "max_input_tokens":1000000,"max_tokens":128000,
                  "capabilities":{"structured_outputs":{"supported":true},"effort":{"supported":true,"levels":["low","medium","high","xhigh","max"]},
                                  "thinking":{"types":["adaptive"]},"image_input":{"supported":true},"pdf_input":{"supported":true},"batch":{"supported":true}}}],
         "has_more":true,"first_id":"claude-opus-5-5","last_id":"claude-opus-5-5"}
        """
        let page2 = """
        {"data":[{"type":"model","id":"claude-haiku-4-5","display_name":"Claude Haiku 4.5","created_at":"2025-10-01T00:00:00Z",
                  "lifecycle":"deprecated","deprecated_at":"2026-08-01T00:00:00Z","retires_at":"2027-01-15T00:00:00Z",
                  "capabilities":{"structured_outputs":{"supported":false},"thinking":{"types":[]}}}],
         "has_more":false,"first_id":"claude-haiku-4-5","last_id":"claude-haiku-4-5"}
        """
        let http = StubHTTPClient(responses: [jsonResponse(200, page1), jsonResponse(200, page2)])
        let client = AnthropicTextClient(apiKey: key, http: http, configuration: noRetry)
        let models = try await client.listModels()

        #expect(http.requests.count == 2)
        #expect(http.requests[1].url?.query?.contains("after_id=claude-opus-5-5") == true)
        #expect(models.map(\.id) == ["claude-opus-5-5", "claude-haiku-4-5"])
        let opus = models[0]
        #expect(opus.displayName == "Claude Opus 5.5")
        #expect(opus.capabilities.structuredOutput == .supported)
        #expect(opus.capabilities.thinking == .supported)
        #expect(opus.capabilities.imageInput == .supported)
        #expect(opus.capabilities.effortLevels == ["low", "medium", "high", "xhigh", "max"])
        #expect(opus.inputTokenLimit == 1_000_000)
        #expect(opus.outputTokenLimit == 128_000)
        #expect(opus.lifecycle == .active)
        let haiku = models[1]
        #expect(haiku.capabilities.structuredOutput == .unsupported)
        #expect(haiku.capabilities.thinking == .unsupported)
        #expect(haiku.capabilities.imageInput == .unknown)
        #expect(haiku.lifecycle == .deprecated)
        #expect(haiku.shutdownDate != nil)
    }

    @Test func errorMapping() {
        let auth = ProviderErrorMapper.anthropic(jsonResponse(401, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#), now: fixedNow)
        #expect(auth == .invalidAPIKey)

        let limited = ProviderErrorMapper.anthropic(
            jsonResponse(429, #"{"type":"error","error":{"type":"rate_limit_error","message":"Rate limited"}}"#, headers: ["retry-after": "45"]),
            now: fixedNow
        )
        #expect(limited == .rateLimited(retryAt: fixedNow.addingTimeInterval(45)))
        #expect(limited.userMessage(now: fixedNow).contains("Kontingent erschöpft – erneut versuchen ab"))

        // Spend cap: no retry-after → not retried automatically.
        let spendCap = ProviderErrorMapper.anthropic(
            jsonResponse(429, #"{"type":"error","error":{"type":"rate_limit_error","message":"spend limit reached"}}"#), now: fixedNow
        )
        #expect(spendCap == .quotaExhausted("spend limit reached"))
        #expect(!spendCap.isRetryable)

        let resetFromHeaders = ProviderErrorMapper.anthropic(
            jsonResponse(429, #"{"type":"error","error":{"type":"rate_limit_error","message":"x"}}"#, headers: [
                "anthropic-ratelimit-tokens-remaining": "0",
                "anthropic-ratelimit-tokens-reset": "2026-10-30T08:05:00Z",
                "anthropic-ratelimit-requests-remaining": "10",
                "anthropic-ratelimit-requests-reset": "2026-10-30T09:00:00Z",
            ]),
            now: fixedNow
        )
        #expect(resetFromHeaders == .rateLimited(retryAt: RetryAfterParser.parseRFC3339("2026-10-30T08:05:00Z")))

        #expect(ProviderErrorMapper.anthropic(jsonResponse(402, #"{"type":"error","error":{"type":"billing_error","message":"b"}}"#), now: fixedNow) == .quotaExhausted("b"))
        #expect(ProviderErrorMapper.anthropic(jsonResponse(529, #"{"type":"error","error":{"type":"overloaded_error","message":"o"}}"#), now: fixedNow) == .overloaded(retryAt: nil))
        #expect(ProviderErrorMapper.anthropic(jsonResponse(413, #"{"type":"error","error":{"type":"request_too_large","message":"t"}}"#), now: fixedNow) == .requestTooLarge)
    }

    @Test func endToEndErrorThrownFromClient() async {
        let http = StubHTTPClient(responses: [jsonResponse(401, #"{"type":"error","error":{"type":"authentication_error","message":"bad"}}"#)])
        let client = AnthropicTextClient(apiKey: key, http: http, configuration: noRetry)
        await #expect(throws: AIProviderError.invalidAPIKey) { try await client.generate(sampleRequest(model: "m")) }
        let validation = try? await AnthropicTextClient(
            apiKey: key, http: StubHTTPClient(responses: [jsonResponse(401, "{}")]), configuration: noRetry
        ).validateAPIKey()
        #expect(validation == .invalid)
    }
}

// MARK: - Gemini

@Suite("Gemini generateContent client")
struct GeminiTextClientTests {
    let key = SecretValue("AIzaTESTKEY")

    @Test func requestShapeKeyOnlyInHeader() async throws {
        let http = StubHTTPClient(responses: [jsonResponse(200, #"{"candidates":[{"content":{"parts":[{"text":"{}"}],"role":"model"},"finishReason":"STOP"}]}"#)])
        let client = GeminiTextClient(apiKey: key, http: http, configuration: noRetry)
        _ = try await client.generate(sampleRequest(model: "models/gemini-4-pro"))

        let request = try #require(http.requests.first)
        let url = try #require(request.url?.absoluteString)
        #expect(url == "https://generativelanguage.googleapis.com/v1beta/models/gemini-4-pro:generateContent")
        #expect(!url.contains("key="))
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "AIzaTESTKEY")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)

        let body = try bodyJSON(request)
        #expect(body["systemInstruction"]?["parts"]?[0]?["text"] == "SYSTEM")
        #expect(body["contents"]?[0]?["role"] == "user")
        #expect(body["contents"]?[1]?["role"] == "model")
        #expect(body["contents"]?[2]?["parts"]?[0]?["text"] == "Weiter")
        #expect(body["generationConfig"]?["maxOutputTokens"] == 1234)
        #expect(body["generationConfig"]?["responseMimeType"] == "application/json")
        #expect(body["generationConfig"]?["responseJsonSchema"] == DraftSchema.draftList)
        #expect(body["generationConfig"]?["temperature"] == nil)
    }

    @Test func parsesCandidatesSkippingThoughts() throws {
        let result = try GeminiTextClient.parse(jsonResponse(200, """
        {"candidates":[{"content":{"role":"model","parts":[{"text":"thinking…","thought":true},{"text":"{\\"drafts\\":[]}"}]},"finishReason":"STOP","index":0}],
         "usageMetadata":{"promptTokenCount":200,"cachedContentTokenCount":50,"candidatesTokenCount":40,"thoughtsTokenCount":60,"totalTokenCount":300},
         "modelVersion":"gemini-4-pro","responseId":"resp-9"}
        """), model: "gemini-4-pro")
        #expect(result.text == #"{"drafts":[]}"#)
        #expect(result.usage == AIUsage(inputTokens: 200, outputTokens: 100, cachedInputTokens: 50, reasoningTokens: 60))
        #expect(result.requestID == "resp-9")

        let blocked = try GeminiTextClient.parse(jsonResponse(200, #"{"promptFeedback":{"blockReason":"SAFETY"}}"#), model: "m")
        #expect(throws: AIProviderError.refusal("SAFETY")) { try blocked.decodeStructured(DraftList.self) }
        let cut = try GeminiTextClient.parse(jsonResponse(200, #"{"candidates":[{"content":{"parts":[{"text":"{"}]},"finishReason":"MAX_TOKENS"}]}"#), model: "m")
        #expect(cut.finishReason == .maxTokens)
    }

    @Test func modelListPaginationAndCapabilities() async throws {
        let page1 = """
        {"models":[{"name":"models/gemini-4-pro","baseModelId":"gemini-4-pro","version":"4.0","displayName":"Gemini 4 Pro",
                    "description":"…","inputTokenLimit":2097152,"outputTokenLimit":65536,
                    "supportedGenerationMethods":["generateContent","countTokens"],"thinking":true,
                    "temperature":1.0,"maxTemperature":2.0,"topP":0.95,"topK":64}],
         "nextPageToken":"tok2"}
        """
        let page2 = """
        {"models":[{"name":"models/text-embedding-005","displayName":"Embedding","supportedGenerationMethods":["embedContent"],"thinking":false}]}
        """
        let http = StubHTTPClient(responses: [jsonResponse(200, page1), jsonResponse(200, page2)])
        let client = GeminiTextClient(apiKey: key, http: http, configuration: noRetry)
        let models = try await client.listModels()

        #expect(http.requests[0].url?.query == "pageSize=100")
        #expect(http.requests[1].url?.query?.contains("pageToken=tok2") == true)
        #expect(models.map(\.id) == ["gemini-4-pro", "text-embedding-005"])
        #expect(models[0].capabilities.textGeneration == .supported)
        #expect(models[0].capabilities.thinking == .supported)
        #expect(models[0].capabilities.structuredOutput == .unknown)
        #expect(models[0].inputTokenLimit == 2_097_152)
        #expect(models[1].capabilities.textGeneration == .unsupported)
        #expect(models.filter { $0.capabilities.textGeneration == .supported }.count == 1)
    }

    @Test func keyValidationAndErrorMapping() async throws {
        let invalidBody = """
        {"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT",
          "details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"API_KEY_INVALID","domain":"googleapis.com"}]}}
        """
        let http = StubHTTPClient(responses: [jsonResponse(400, invalidBody)])
        let client = GeminiTextClient(apiKey: key, http: http, configuration: noRetry)
        #expect(try await client.validateAPIKey() == .invalid)
        #expect(http.requests.first?.url?.query == "pageSize=1")

        let exhausted = ProviderErrorMapper.gemini(jsonResponse(429, """
        {"error":{"code":429,"message":"Quota exceeded","status":"RESOURCE_EXHAUSTED",
          "details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"30s"}]}}
        """), now: fixedNow)
        #expect(exhausted == .rateLimited(retryAt: fixedNow.addingTimeInterval(30)))

        let noHint = ProviderErrorMapper.gemini(jsonResponse(429, #"{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","message":"q"}}"#), now: fixedNow)
        #expect(noHint == .rateLimited(retryAt: nil))
        #expect(noHint.userMessage() == "Kontingent erschöpft – bitte später erneut versuchen.")
        #expect(ProviderErrorMapper.gemini(jsonResponse(403, #"{"error":{"code":403,"status":"PERMISSION_DENIED","message":"p"}}"#), now: fixedNow) == .permissionDenied("p"))
        #expect(ProviderErrorMapper.gemini(jsonResponse(503, #"{"error":{"code":503,"status":"UNAVAILABLE","message":"u"}}"#), now: fixedNow) == .overloaded(retryAt: nil))
    }
}

// MARK: - Retry

@Suite("Retry policy")
struct RetryPolicyTests {
    @Test func retriesRateLimitHonouringRetryAfter() async throws {
        let attempts = Counter()
        let sleeps = Recorder()
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 1, maxDelay: 10, maxServerRequestedDelay: 60, jitterRatio: 0)
        let value = try await policy.run(
            now: { fixedNow }, jitter: { 0 }, sleep: { await sleeps.add($0) }
        ) {
            if await attempts.increment() < 3 {
                throw AIProviderError.rateLimited(retryAt: fixedNow.addingTimeInterval(5))
            }
            return "ok"
        }
        #expect(value == "ok")
        #expect(await sleeps.values == [5, 5])
    }

    @Test func neverRetriesQuotaOrAuth() async {
        let attempts = Counter()
        await #expect(throws: AIProviderError.quotaExhausted(nil)) {
            try await RetryPolicy().run(sleep: { _ in }) {
                _ = await attempts.increment()
                throw AIProviderError.quotaExhausted(nil)
            }
        }
        #expect(await attempts.value == 1)
        #expect(RetryPolicy().delay(afterAttempt: 1, error: .invalidAPIKey, now: fixedNow, jitter: 0) == nil)
    }

    @Test func backoffIsBoundedAndLongServerWaitsSurface() {
        let policy = RetryPolicy(maxAttempts: 5, baseDelay: 1, maxDelay: 4, jitterRatio: 0)
        #expect(policy.delay(afterAttempt: 1, error: .server(statusCode: 500), now: fixedNow, jitter: 0) == 1)
        #expect(policy.delay(afterAttempt: 4, error: .server(statusCode: 500), now: fixedNow, jitter: 0) == 4)
        #expect(policy.delay(afterAttempt: 5, error: .server(statusCode: 500), now: fixedNow, jitter: 0) == nil)
        #expect(policy.delay(afterAttempt: 1, error: .rateLimited(retryAt: fixedNow.addingTimeInterval(3600)), now: fixedNow, jitter: 0) == nil)
    }

    @Test func retryAfterParsing() {
        #expect(RetryAfterParser.parse("12", now: fixedNow) == fixedNow.addingTimeInterval(12))
        #expect(RetryAfterParser.parse("Wed, 21 Oct 2015 07:28:00 GMT", now: fixedNow) == Date(timeIntervalSince1970: 1_445_412_480))
        #expect(RetryAfterParser.parse("garbage", now: fixedNow) == nil)
        #expect(RetryAfterParser.parse(nil, now: fixedNow) == nil)
    }
}

actor Counter {
    var value = 0
    func increment() -> Int {
        value += 1
        return value
    }
}

actor Recorder {
    var values: [TimeInterval] = []
    func add(_ value: TimeInterval) { values.append(value) }
}
