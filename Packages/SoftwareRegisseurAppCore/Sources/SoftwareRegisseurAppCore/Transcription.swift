import Foundation
import SoftwareRegisseurAI
import SoftwareRegisseurDomain

/// Dictation method, selectable per device (spec H2).
public enum TranscriptionMethod: String, Hashable, Sendable, Codable, CaseIterable {
    /// Apple speech recognition on the device (SpeechAnalyzer); no upload.
    case appleSpeech
    /// Recording uploaded to OpenAI Speech-to-Text with the user's own key.
    case openAI

    /// Permissions needed before recording. Microphone is always needed; Apple recognition additionally
    /// asks for speech recognition (conservative reading of the open spike S7, apple-platform.md).
    public var requiredPermissions: [PermissionKind] {
        switch self {
        case .appleSpeech: [.microphone, .speechRecognition]
        case .openAI: [.microphone]
        }
    }

    public var uploadsAudio: Bool { self == .openAI }

    /// Provider that receives the audio, named in the consent sheet.
    public var uploadProvider: SoftwareRegisseurAI.AIProviderID? {
        switch self {
        case .appleSpeech: nil
        case .openAI: .openai
        }
    }

    public var domainProvider: SoftwareRegisseurDomain.AIProviderID {
        switch self {
        case .appleSpeech: .appleOnDevice
        case .openAI: .openAI
        }
    }

    public var initialConsent: AudioUploadConsent {
        uploadsAudio ? .pending : .notRequired
    }
}

public enum UploadConsentError: Error, Hashable, Sendable {
    /// The user has not (yet) confirmed that audio goes to `provider` (spec H2: „Vor externem Upload klar anzeigen“).
    case consentMissing(provider: String)
    case consentDenied(provider: String)
}

/// Explicit consent before audio leaves the device. Granted per recording, never implicitly.
public struct UploadConsentGate: Hashable, Sendable {
    public let method: TranscriptionMethod
    public private(set) var consent: AudioUploadConsent

    public init(method: TranscriptionMethod, consent: AudioUploadConsent? = nil) {
        self.method = method
        self.consent = consent ?? method.initialConsent
    }

    /// True while the consent sheet must be shown before transcription.
    public var needsDecision: Bool {
        if case .pending = consent { return true }
        return false
    }

    public mutating func grant(at date: Date) {
        guard method.uploadsAudio else { return }
        consent = .granted(at: date)
    }

    public mutating func deny(at date: Date) {
        guard method.uploadsAudio else { return }
        consent = .denied(at: date)
    }

    public func authorizeUpload() throws(UploadConsentError) {
        guard let provider = method.uploadProvider else { return }
        switch consent {
        case .granted: return
        case .denied: throw .consentDenied(provider: provider.rawValue)
        case .pending, .notRequired: throw .consentMissing(provider: provider.rawValue)
        }
    }
}

/// API transcription that refuses to upload without consent; long recordings are segmented by the
/// `AudioSegmenter` (spec H2 B).
public struct ConsentedTranscriptionService: Sendable {
    public let transcriber: ChunkedTranscriber

    public init(transcriber: ChunkedTranscriber) {
        self.transcriber = transcriber
    }

    public func transcribe(
        file: URL,
        duration: TimeInterval,
        template: TranscriptionRequest,
        gate: UploadConsentGate,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> TranscriptionResult {
        try gate.authorizeUpload()
        return try await transcriber.transcribe(file: file, duration: duration, template: template, progress: progress)
    }
}

/// Retention of the original recording (spec H2: default delete after successful processing).
public enum AudioRetention {
    /// Whether the audio file must be deleted now.
    public static func shouldDelete(policy: AudioRetentionPolicy, transcriptionSucceeded: Bool, recordedAt: Date, now: Date) -> Bool {
        switch policy {
        case .deleteAfterTranscription:
            return transcriptionSucceeded
        case .keepLocally:
            return false
        case let .keepForDays(days):
            return now.timeIntervalSince(recordedAt) >= TimeInterval(max(days, 0)) * 86_400
        }
    }
}

/// Project vocabulary as transcription hints (spec H2): de-duplicated, without characters the API rejects.
public enum TranscriptionHints {
    public static func sanitized(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains("<") && !$0.contains(">") && !$0.contains("\n") }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    public static func parse(_ text: String) -> [String] {
        sanitized(text.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" }).map(String.init))
    }
}
