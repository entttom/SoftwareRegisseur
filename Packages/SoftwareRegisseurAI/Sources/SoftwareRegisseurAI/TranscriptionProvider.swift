import Foundation

/// API transcription provider (spec H2 B, C.9). Separate from `TextAIProvider` so dictation and
/// elaboration can use different providers (spec H3, ADR-0008).
public protocol TranscriptionProvider: Sendable {
    var providerID: AIProviderID { get }
    /// Maximum upload size in bytes; larger audio must be segmented first.
    var maxUploadBytes: Int { get }
    var supportedFormats: Set<AudioFormat> { get }
    func listModels() async throws -> [AIModelInfo]
    func validateAPIKey() async throws -> KeyValidationResult
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult
}

public enum AudioFormat: String, Sendable, Hashable, Codable, CaseIterable {
    case mp3, mp4, mpeg, mpga, m4a, wav, webm

    public init?(fileExtension: String) {
        self.init(rawValue: fileExtension.lowercased())
    }

    public var mimeType: String {
        switch self {
        case .mp3, .mpeg, .mpga: return "audio/mpeg"
        case .mp4, .m4a: return "audio/mp4"
        case .wav: return "audio/wav"
        case .webm: return "audio/webm"
        }
    }
}

public struct AudioPayload: Sendable, Hashable {
    public enum Source: Sendable, Hashable {
        case data(Data)
        case file(URL)
    }

    public var source: Source
    public var fileName: String
    public var format: AudioFormat

    public init(data: Data, fileName: String, format: AudioFormat) {
        self.source = .data(data)
        self.fileName = fileName
        self.format = format
    }

    /// Format derived from the file extension.
    public init(fileURL: URL) throws {
        guard let format = AudioFormat(fileExtension: fileURL.pathExtension) else {
            throw AIProviderError.unsupportedAudioFormat(fileURL.pathExtension)
        }
        self.source = .file(fileURL)
        self.fileName = fileURL.lastPathComponent
        self.format = format
    }

    /// Byte size determined without loading the file.
    public func byteCount() throws -> Int {
        switch source {
        case .data(let data):
            return data.count
        case .file(let url):
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let size = values.fileSize else {
                throw AIProviderError.invalidRequest(String(localized: "Dateigröße unbekannt", bundle: .module))
            }
            return size
        }
    }

    func loadData() throws -> Data {
        switch source {
        case .data(let data): return data
        case .file(let url): return try Data(contentsOf: url, options: .mappedIfSafe)
        }
    }
}

public struct TranscriptionRequest: Sendable, Hashable {
    public var audio: AudioPayload
    public var model: String
    /// Free-form context, e.g. the tail of the previous segment's transcript.
    public var prompt: String?
    /// Expected literal terms (project vocabulary). Hints only, never required output (spec H2).
    public var keywords: [String]
    /// ISO-639-1 codes; empty = automatic detection.
    public var languages: [String]

    public init(
        audio: AudioPayload,
        model: String = OpenAITranscriptionClient.defaultModel,
        prompt: String? = nil,
        keywords: [String] = [],
        languages: [String] = []
    ) {
        self.audio = audio
        self.model = model
        self.prompt = prompt
        self.keywords = keywords
        self.languages = languages
    }
}

public struct TranscriptionResult: Sendable, Hashable {
    public var provider: AIProviderID
    public var model: String
    public var text: String
    /// Detected languages; empty when the provider could not detect one reliably.
    public var detectedLanguages: [String]
    public var usage: AIUsage

    public init(provider: AIProviderID, model: String, text: String, detectedLanguages: [String], usage: AIUsage) {
        self.provider = provider
        self.model = model
        self.text = text
        self.detectedLanguages = detectedLanguages
        self.usage = usage
    }
}
