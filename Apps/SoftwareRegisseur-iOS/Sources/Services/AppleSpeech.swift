import AVFoundation
import Foundation
import Speech

/// Truthful availability of Apple speech recognition (spec H2 A, apple-platform.md §SpeechAnalyzer):
/// „offline verfügbar“ only once the language model is installed.
enum AppleSpeechAvailability: Equatable, Sendable {
    /// Model installed: transcription runs on the device without network.
    case installed(localeIdentifier: String, module: AppleSpeechModule)
    /// Supported, but the model must be downloaded once (internet required).
    case downloadRequired(localeIdentifier: String, module: AppleSpeechModule)
    case unsupportedLocale
    /// Neither SpeechTranscriber nor DictationTranscriber is available on this device.
    case unavailable
}

enum AppleSpeechModule: String, Equatable, Sendable {
    /// `SpeechTranscriber` (iOS 26, general purpose).
    case speechTranscriber
    /// `DictationTranscriber` fallback for devices without SpeechTranscriber.
    case dictationTranscriber
}

enum AppleSpeechError: Error {
    case unavailable
    case emptyResult
}

/// On-device transcription of a recorded file with `SpeechAnalyzer`. Audio is not sent to Apple
/// („SpeechAnalyzer transcriber modules don’t send audio data … to Apple’s servers“).
enum AppleSpeechService {
    static func availability(localeIdentifier: String) async -> AppleSpeechAvailability {
        let requested = Locale(identifier: localeIdentifier)
        if SpeechTranscriber.isAvailable {
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else { return .unsupportedLocale }
            let installed = await SpeechTranscriber.installedLocales
            let id = locale.identifier(.bcp47)
            return installed.contains { $0.identifier(.bcp47) == id }
                ? .installed(localeIdentifier: id, module: .speechTranscriber)
                : .downloadRequired(localeIdentifier: id, module: .speechTranscriber)
        }
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: requested) else { return .unavailable }
        let installed = await DictationTranscriber.installedLocales
        let id = locale.identifier(.bcp47)
        return installed.contains { $0.identifier(.bcp47) == id }
            ? .installed(localeIdentifier: id, module: .dictationTranscriber)
            : .downloadRequired(localeIdentifier: id, module: .dictationTranscriber)
    }

    /// Downloads the language model once (needs internet; triggered by the user in settings or dictation).
    static func downloadModel(localeIdentifier: String, module: AppleSpeechModule) async throws {
        let modules: [any SpeechModule] = [makeModule(module, locale: Locale(identifier: localeIdentifier))]
        if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            try await request.downloadAndInstall()
        }
    }

    static func transcribe(file: URL, localeIdentifier: String, module: AppleSpeechModule, hints: [String]) async throws -> String {
        let locale = Locale(identifier: localeIdentifier)
        let context = AnalysisContext()
        if !hints.isEmpty { context.contextualStrings[.general] = hints }
        switch module {
        case .speechTranscriber:
            let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
            async let text = collect(transcriber.results.map { ($0.isFinal, String($0.text.characters)) })
            try await run(file: file, module: transcriber, context: context)
            return try await finish(text)
        case .dictationTranscriber:
            let transcriber = DictationTranscriber(locale: locale, preset: .longDictation)
            async let text = collect(transcriber.results.map { ($0.isFinal, String($0.text.characters)) })
            try await run(file: file, module: transcriber, context: context)
            return try await finish(text)
        }
    }

    private static func makeModule(_ module: AppleSpeechModule, locale: Locale) -> any SpeechModule {
        switch module {
        case .speechTranscriber: SpeechTranscriber(locale: locale, preset: .transcription)
        case .dictationTranscriber: DictationTranscriber(locale: locale, preset: .longDictation)
        }
    }

    private static func run(file: URL, module: any SpeechModule, context: AnalysisContext) async throws {
        let analyzer = SpeechAnalyzer(modules: [module])
        try await analyzer.setContext(context)
        let audioFile = try AVAudioFile(forReading: file)
        try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
    }

    private static func collect<S: AsyncSequence & Sendable>(_ results: S) async throws -> String where S.Element == (Bool, String) {
        var parts: [String] = []
        for try await (isFinal, text) in results where isFinal {
            parts.append(text)
        }
        return parts.joined()
    }

    private static func finish(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppleSpeechError.emptyResult }
        return trimmed
    }
}
