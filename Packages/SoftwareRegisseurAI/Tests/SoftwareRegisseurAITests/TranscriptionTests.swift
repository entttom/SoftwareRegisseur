import Foundation
import Synchronization
import Testing
import SoftwareRegisseurSecrets
@testable import SoftwareRegisseurAI

@Suite("OpenAI transcription")
struct OpenAITranscriptionTests {
    func client(_ http: StubHTTPClient) -> OpenAITranscriptionClient {
        OpenAITranscriptionClient(
            connection: OpenAIConnection(apiKey: SecretValue("sk-test-transcribe")),
            http: http,
            configuration: AIClientConfiguration(retryPolicy: .none),
            boundary: { "BOUNDARY123" }
        )
    }

    @Test func multipartRequestShape() async throws {
        let http = StubHTTPClient(responses: [jsonResponse(200, """
        {"text":"Hallo Welt","languages":["de"],"usage":{"type":"tokens","input_tokens":40,"output_tokens":5,"total_tokens":45,
         "input_token_details":{"audio_tokens":38,"text_tokens":2}}}
        """)])
        let request = TranscriptionRequest(
            audio: AudioPayload(data: Data("AUDIO".utf8), fileName: "note.m4a", format: .m4a),
            prompt: "Projekt Software Regisseur",
            keywords: ["CloudKit", "SwiftData", "  "],
            languages: ["de"]
        )
        let result = try await client(http).transcribe(request)

        let sent = try #require(http.requests.first)
        #expect(sent.url?.absoluteString == "https://api.openai.com/v1/audio/transcriptions")
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-transcribe")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=BOUNDARY123")

        let body = String(decoding: try #require(sent.httpBody), as: UTF8.self)
        #expect(body.contains("name=\"model\"\r\n\r\ngpt-transcribe\r\n"))
        #expect(body.contains("name=\"prompt\"\r\n\r\nProjekt Software Regisseur\r\n"))
        #expect(body.contains("name=\"keywords[]\"\r\n\r\nCloudKit\r\n"))
        #expect(body.contains("name=\"keywords[]\"\r\n\r\nSwiftData\r\n"))
        #expect(body.components(separatedBy: "name=\"keywords[]\"").count == 3)
        #expect(body.contains("name=\"languages[]\"\r\n\r\nde\r\n"))
        #expect(!body.contains("name=\"language\""))
        #expect(body.contains("name=\"file\"; filename=\"note.m4a\"\r\nContent-Type: audio/mp4\r\n\r\nAUDIO\r\n"))
        #expect(body.hasSuffix("--BOUNDARY123--\r\n"))

        #expect(result.text == "Hallo Welt")
        #expect(result.detectedLanguages == ["de"])
        #expect(result.usage.inputTokens == 40)
        #expect(result.usage.outputTokens == 5)
    }

    @Test func durationUsage() throws {
        let result = try OpenAITranscriptionClient.parse(
            jsonResponse(200, #"{"text":"x","languages":[],"usage":{"type":"duration","seconds":42}}"#), model: "gpt-transcribe"
        )
        #expect(result.usage.audioSeconds == 42)
        #expect(result.detectedLanguages.isEmpty)
    }

    @Test func refusesOversizedAudioBeforeUpload() async {
        let http = StubHTTPClient()
        let big = Data(count: OpenAITranscriptionClient.uploadLimitBytes + 1)
        let request = TranscriptionRequest(audio: AudioPayload(data: big, fileName: "long.m4a", format: .m4a))
        await #expect(throws: AIProviderError.fileTooLarge(bytes: big.count, limit: 25_000_000)) {
            try await client(http).transcribe(request)
        }
        #expect(http.requests.isEmpty)
        #expect(AIProviderError.fileTooLarge(bytes: big.count, limit: 25_000_000).userMessage().contains("Audiodatei zu groß"))
    }

    @Test func rejectsKeywordsWithForbiddenCharacters() async {
        let http = StubHTTPClient()
        for bad in ["<tag>", "a\nb", "x>y"] {
            let request = TranscriptionRequest(
                audio: AudioPayload(data: Data("A".utf8), fileName: "n.m4a", format: .m4a), keywords: [bad]
            )
            await #expect(throws: AIProviderError.invalidTranscriptionHint(bad)) { try await client(http).transcribe(request) }
        }
        #expect(http.requests.isEmpty)
    }

    @Test func unsupportedFileExtension() {
        #expect(throws: AIProviderError.unsupportedAudioFormat("caf")) {
            try AudioPayload(fileURL: URL(fileURLWithPath: "/tmp/x.caf"))
        }
    }

    @Test func keyValidationWarnsWhenModelMissing() async throws {
        let http = StubHTTPClient(responses: [jsonResponse(200, #"{"object":"list","data":[{"id":"gpt-6-luna","object":"model"}]}"#)])
        guard case .validWithWarning(let warning) = try await client(http).validateAPIKey() else {
            Issue.record("expected warning")
            return
        }
        #expect(warning.contains("gpt-transcribe"))
    }
}

@Suite("Transcription chunking")
struct TranscriptionChunkingTests {
    @Test func plannerSplitsByTargetSize() throws {
        let planner = TranscriptionChunkPlanner(targetSegmentBytes: 24_000_000, maxPauseSearchWindow: 10)
        let single = try planner.plan(duration: 600, byteCount: 5_000_000)
        #expect(!single.requiresSplitting)
        #expect(single.segments == [PlannedAudioSegment(index: 0, start: 0, end: 600)])

        let plan = try planner.plan(duration: 7200, byteCount: 60_000_000)
        #expect(plan.segments.count == 3)
        #expect(plan.segments[0].start == 0)
        #expect(plan.segments[1].start == 2400)
        #expect(plan.segments[2].end == 7200)
        #expect(plan.pauseSearchWindow == 10)

        #expect(throws: AIProviderError.self) { try planner.plan(duration: 0, byteCount: 10) }
    }

    @Test func chunkedTranscriberSendsSegmentsSequentiallyWithPromptTail() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sr-chunk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("long.m4a")
        try Data(count: 250).write(to: file)

        let provider = RecordingTranscriptionProvider(limit: 100, texts: ["Erster Teil.", "Zweiter Teil.", "Dritter Teil."])
        let transcriber = ChunkedTranscriber(
            provider: provider,
            segmenter: StubSegmenter(),
            planner: TranscriptionChunkPlanner(targetSegmentBytes: 90),
            promptTailCharacters: 7
        )
        let template = TranscriptionRequest(
            audio: AudioPayload(data: Data(), fileName: "x.m4a", format: .m4a),
            prompt: "Kontext", keywords: ["CloudKit"], languages: ["de"]
        )
        let result = try await transcriber.transcribe(file: file, duration: 90, template: template)

        let requests = provider.requests
        #expect(requests.count == 3)
        #expect(requests[0].prompt == "Kontext")
        #expect(requests[1].prompt == "Kontext\nr Teil.")
        #expect(requests.allSatisfy { $0.keywords == ["CloudKit"] && $0.languages == ["de"] })
        #expect(result.text == "Erster Teil. Zweiter Teil. Dritter Teil.")
        #expect(result.usage.audioSeconds == 90)
    }
}

final class RecordingTranscriptionProvider: TranscriptionProvider {
    let providerID: AIProviderID = .openai
    let maxUploadBytes: Int
    let supportedFormats: Set<AudioFormat> = [.m4a]
    private let state: Mutex<(requests: [TranscriptionRequest], texts: [String])>

    init(limit: Int, texts: [String]) {
        maxUploadBytes = limit
        state = Mutex(([], texts))
    }

    var requests: [TranscriptionRequest] { state.withLock { $0.requests } }

    func listModels() async throws -> [AIModelInfo] { [] }
    func validateAPIKey() async throws -> KeyValidationResult { .valid }
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        if try request.audio.byteCount() > maxUploadBytes {
            throw AIProviderError.fileTooLarge(bytes: try request.audio.byteCount(), limit: maxUploadBytes)
        }
        let text: String = state.withLock { state in
            state.requests.append(request)
            return state.texts.removeFirst()
        }
        return TranscriptionResult(provider: .openai, model: request.model, text: text, detectedLanguages: ["de"],
                                   usage: AIUsage(audioSeconds: 30))
    }
}

struct StubSegmenter: AudioSegmenter {
    func split(_ audio: URL, plan: TranscriptionChunkPlan) async throws -> [AudioPayload] {
        plan.segments.map { AudioPayload(data: Data(count: 80), fileName: "seg\($0.index).m4a", format: .m4a) }
    }
}
