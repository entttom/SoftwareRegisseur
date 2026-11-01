import Foundation

/// A planned cut of a long recording (spec H2 "Lange Notizen sinnvoll behandeln", research §1.1).
public struct PlannedAudioSegment: Sendable, Hashable {
    public var index: Int
    public var start: TimeInterval
    public var end: TimeInterval

    public init(index: Int, start: TimeInterval, end: TimeInterval) {
        self.index = index
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { end - start }
}

public struct TranscriptionChunkPlan: Sendable, Hashable {
    public var segments: [PlannedAudioSegment]
    /// The segmenter may move each inner cut up to this many seconds earlier to land on a
    /// speech pause (never mid-sentence, research §1.1). Moving earlier keeps segments small.
    public var pauseSearchWindow: TimeInterval

    public var requiresSplitting: Bool { segments.count > 1 }
}

public struct TranscriptionChunkPlanner: Sendable {
    /// Target size per segment, below the hard upload limit to leave headroom (research §1.1: ~24 MB).
    public var targetSegmentBytes: Int
    public var maxPauseSearchWindow: TimeInterval

    public init(targetSegmentBytes: Int = 24_000_000, maxPauseSearchWindow: TimeInterval = 10) {
        self.targetSegmentBytes = targetSegmentBytes
        self.maxPauseSearchWindow = maxPauseSearchWindow
    }

    /// Splits by duration assuming a roughly constant bitrate (AAC/m4a recording).
    public func plan(duration: TimeInterval, byteCount: Int) throws -> TranscriptionChunkPlan {
        guard duration > 0, byteCount > 0, targetSegmentBytes > 0 else {
            throw AIProviderError.invalidRequest(String(localized: "Aufnahme ohne Dauer oder Inhalt", bundle: .module))
        }
        let count = max(1, Int((Double(byteCount) / Double(targetSegmentBytes)).rounded(.up)))
        let length = duration / Double(count)
        let segments = (0..<count).map { index in
            PlannedAudioSegment(
                index: index,
                start: Double(index) * length,
                end: index == count - 1 ? duration : Double(index + 1) * length
            )
        }
        let window = count > 1 ? min(maxPauseSearchWindow, length * 0.1) : 0
        return TranscriptionChunkPlan(segments: segments, pauseSearchWindow: window)
    }
}

/// Implemented by the app layer with AVFoundation (export ranges, snap cuts to pauses via
/// metering/VAD). Returned payloads must each fit the provider's upload limit.
public protocol AudioSegmenter: Sendable {
    func split(_ audio: URL, plan: TranscriptionChunkPlan) async throws -> [AudioPayload]
}

/// Transcribes long recordings sequentially, passing the previous segment's tail as `prompt`
/// so wording stays consistent across cuts (research §1.1).
public struct ChunkedTranscriber: Sendable {
    public var provider: any TranscriptionProvider
    public var segmenter: any AudioSegmenter
    public var planner: TranscriptionChunkPlanner
    public var promptTailCharacters: Int

    public init(
        provider: any TranscriptionProvider,
        segmenter: any AudioSegmenter,
        planner: TranscriptionChunkPlanner = TranscriptionChunkPlanner(),
        promptTailCharacters: Int = 300
    ) {
        self.provider = provider
        self.segmenter = segmenter
        self.planner = planner
        self.promptTailCharacters = promptTailCharacters
    }

    /// - Parameter template: model, keywords, languages and base prompt; its `audio` is replaced.
    public func transcribe(
        file: URL,
        duration: TimeInterval,
        template: TranscriptionRequest,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> TranscriptionResult {
        let whole = try AudioPayload(fileURL: file)
        let size = try whole.byteCount()
        if size <= provider.maxUploadBytes {
            var request = template
            request.audio = whole
            progress?(1, 1)
            return try await provider.transcribe(request)
        }

        let plan = try planner.plan(duration: duration, byteCount: size)
        let segments = try await segmenter.split(file, plan: plan)
        guard !segments.isEmpty else { throw AIProviderError.invalidRequest(String(localized: "Segmentierung ergab keine Abschnitte", bundle: .module)) }

        var texts: [String] = []
        var usage = AIUsage.zero
        var languages: [String] = []
        var model = template.model
        for (index, segment) in segments.enumerated() {
            try Task.checkCancellation()
            var request = template
            request.audio = segment
            request.prompt = Self.prompt(base: template.prompt, previous: texts.last, tail: promptTailCharacters)
            let result = try await provider.transcribe(request)
            texts.append(result.text.trimmingCharacters(in: .whitespacesAndNewlines))
            usage = usage + result.usage
            model = result.model
            for language in result.detectedLanguages where !languages.contains(language) {
                languages.append(language)
            }
            progress?(index + 1, segments.count)
        }
        return TranscriptionResult(
            provider: provider.providerID,
            model: model,
            text: texts.filter { !$0.isEmpty }.joined(separator: " "),
            detectedLanguages: languages,
            usage: usage
        )
    }

    static func prompt(base: String?, previous: String?, tail: Int) -> String? {
        let parts = [base, previous.map { String($0.suffix(tail)) }]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}
