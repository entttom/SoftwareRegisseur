import Foundation
import SoftwareRegisseurAI
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

/// Draft versions of a work item (spec H3), stored as the synced Domain `DraftVersion` so the Mac sees
/// them too (spec N1). Versions that earlier app builds kept in a device-only JSON file are imported once
/// (`importLegacyVersions()`); the file is renamed afterwards, so nothing is lost or imported twice.
public actor DraftVersionStore {
    private let repository: any DraftVersionRepository
    private let legacyFileURL: URL?

    public init(repository: any DraftVersionRepository, legacyFileURL: URL? = nil) {
        self.repository = repository
        self.legacyFileURL = legacyFileURL
    }

    public func versions(for item: WorkItemID) async throws -> [DraftVersion] {
        try await repository.versions(workItemId: item)
    }

    /// Stores an AI draft version (never adopted automatically, never starts an agent).
    @discardableResult
    public func append(
        for item: WorkItemID, source channel: DraftGenerationChannel, mode: DraftMode?, provider: String, model: String,
        drafts: [StructuredDraft], usage: AIUsage, at date: Date
    ) async throws -> DraftVersion {
        let contents = drafts.map(DraftMapping.content)
        return try await repository.append({ version in
            DraftVersion(
                workItemId: item, version: version, source: .ai, channel: channel, mode: mode?.rawValue,
                providerId: AIProviderID(rawValue: provider), modelId: AIModelID(rawValue: model), contents: contents,
                usage: TokenUsage(inputTokens: usage.inputTokens, outputTokens: usage.outputTokens), createdAt: date)
        }, for: item, at: date)
    }

    /// Records the original note or a transcript as its own version (spec H3: separately versioned).
    /// No-op when the latest version of that source already has the same text.
    @discardableResult
    public func recordText(_ text: String, source: DraftVersionSource, for item: WorkItemID, at date: Date) async throws -> DraftVersion? {
        precondition(source != .ai, "AI versions carry structured contents")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let existing = try await repository.versions(workItemId: item)
        if existing.last(where: { $0.source == source })?.text == text { return nil }
        return try await repository.append({ version in
            DraftVersion(workItemId: item, version: version, source: source, text: text, createdAt: date)
        }, for: item, at: date)
    }

    /// Explicit adoption of drafts of a version (spec H3: „erst danach freigeben“).
    public func markAdopted(_ versionID: DraftVersionID, draftIndexes: [Int], for item: WorkItemID, at date: Date = .now) async throws {
        _ = try await repository.accept(versionID, contentIndexes: draftIndexes, at: date)
    }

    /// One-time import of the device-only `draft-versions.json` of earlier builds. Returns the number of
    /// imported versions. Idempotent: version IDs are kept, the file is renamed to `*.imported`.
    @discardableResult
    public func importLegacyVersions(at date: Date = .now) async throws -> Int {
        guard let legacyFileURL, FileManager.default.fileExists(atPath: legacyFileURL.path) else { return 0 }
        let data = try Data(contentsOf: legacyFileURL)
        let legacy: [UUID: [LegacyDraftVersion]]
        if let decoded = try? JSONDecoder().decode([UUID: [LegacyDraftVersion]].self, from: data) {
            legacy = decoded
        } else {
            // Tolerate a string-keyed object as well.
            let keyed = try JSONDecoder().decode([String: [LegacyDraftVersion]].self, from: data)
            legacy = Dictionary(uniqueKeysWithValues: keyed.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
        }
        var imported = 0
        for (item, versions) in legacy {
            for old in versions.sorted(by: { $0.version < $1.version }) {
                try await repository.save(old.domain(workItemId: WorkItemID(item)), at: date)
                imported += 1
            }
        }
        let target = legacyFileURL.appendingPathExtension("imported")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: legacyFileURL, to: target)
        return imported
    }
}

/// Format of the device-only draft store of earlier builds (read only for the one-time import).
struct LegacyDraftVersion: Codable {
    enum Source: String, Codable {
        case composer
        case conversation
    }

    var id: UUID
    var version: Int
    var createdAt: Date
    var source: Source
    var mode: DraftMode?
    var provider: String
    var model: String
    var drafts: [StructuredDraft]
    var inputTokens: Int
    var outputTokens: Int
    var adoptedDraftIndexes: [Int]

    func domain(workItemId: WorkItemID) -> DraftVersion {
        DraftVersion(
            id: DraftVersionID(id), workItemId: workItemId, version: version, source: .ai,
            channel: source == .composer ? .composer : .conversation, mode: mode?.rawValue,
            providerId: AIProviderID(rawValue: provider), modelId: AIModelID(rawValue: model),
            contents: drafts.map(DraftMapping.content),
            usage: TokenUsage(inputTokens: inputTokens, outputTokens: outputTokens), createdAt: createdAt,
            // The old store kept no adoption time; the creation time is the closest known value.
            acceptedAt: adoptedDraftIndexes.isEmpty ? nil : createdAt, acceptedContentIndexes: adoptedDraftIndexes)
    }
}

extension DraftVersion {
    /// Structured drafts of an AI version in the AI package's format (UI, adoption).
    public var drafts: [StructuredDraft] { contents.map(DraftMapping.structuredDraft) }
    /// Indexes of `drafts` the user adopted.
    public var adoptedDraftIndexes: [Int] { acceptedContentIndexes }
    /// `DraftMode` of the AI request, if known.
    public var draftMode: DraftMode? { mode.flatMap(DraftMode.init(rawValue:)) }
}

/// Device-local settings (spec H2: dictation per device; I: provider/model per purpose). API keys are not
/// part of it; they live in the keychain.
public struct AppSettings: Hashable, Sendable, Codable {
    public var dictationMethod: TranscriptionMethod
    public var transcriptionModel: String
    public var speechLocaleIdentifier: String
    public var transcriptionHints: [String]
    public var audioRetention: AudioRetentionPolicy
    public var autoDraftAfterDictation: Bool
    /// Raw `SoftwareRegisseurAI.AIProviderID`; nil until the user picks one.
    public var textProvider: String?
    public var textModel: String?
    /// Legacy device-only default agent of earlier builds. The synced `GlobalSettings.defaultAgentId`
    /// replaces it; `GlobalDefaultsEditor.importLegacyDefaultAgent` moves it there once and clears it.
    public var defaultAgent: ProviderID?
    public var priceTable: PriceTable

    public init(
        dictationMethod: TranscriptionMethod = .appleSpeech,
        transcriptionModel: String = OpenAITranscriptionClient.defaultModel,
        speechLocaleIdentifier: String = "de-AT",
        transcriptionHints: [String] = [],
        audioRetention: AudioRetentionPolicy = .deleteAfterTranscription,
        autoDraftAfterDictation: Bool = false,
        textProvider: String? = nil,
        textModel: String? = nil,
        defaultAgent: ProviderID? = nil,
        priceTable: PriceTable = .empty
    ) {
        self.dictationMethod = dictationMethod
        self.transcriptionModel = transcriptionModel
        self.speechLocaleIdentifier = speechLocaleIdentifier
        self.transcriptionHints = transcriptionHints
        self.audioRetention = audioRetention
        self.autoDraftAfterDictation = autoDraftAfterDictation
        self.textProvider = textProvider
        self.textModel = textModel
        self.defaultAgent = defaultAgent
        self.priceTable = priceTable
    }

    public var textProviderID: SoftwareRegisseurAI.AIProviderID? {
        textProvider.map(SoftwareRegisseurAI.AIProviderID.init(rawValue:))
    }
}

/// JSON-backed settings in the app container.
public struct SettingsStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return settings
    }

    public func save(_ settings: AppSettings) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(settings).write(to: fileURL, options: .atomic)
    }
}
