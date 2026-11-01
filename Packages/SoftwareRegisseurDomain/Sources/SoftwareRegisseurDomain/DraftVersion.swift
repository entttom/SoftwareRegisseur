import Foundation

// Versioned drafts of a work item (spec H3: „Originalnotiz, Transkript und KI-Entwurf getrennt
// versionieren“). Synced so the Mac sees what the iPhone drafted (spec N1). A draft version is never
// an approval and never starts an agent.

public typealias DraftVersionID = Identifier<DraftVersion>

public enum DraftVersionSource: String, Hashable, Sendable, Codable, CaseIterable {
    /// The original capture text.
    case original
    /// A dictation transcript (Apple speech or API transcription).
    case transcript
    /// An AI-generated structured draft.
    case ai
}

/// How an AI draft was produced (spec H3: Ausarbeitung vs. „Mit KI besprechen“).
public enum DraftGenerationChannel: String, Hashable, Sendable, Codable, CaseIterable {
    case composer
    case conversation
}

/// Classification proposed by the AI (spec H3); `adr` is no work item type (ADR-0018).
public enum DraftClassification: String, Hashable, Sendable, Codable, CaseIterable {
    case todo, feature, bug, improvement, adr, note

    public var workItemType: WorkItemType? {
        switch self {
        case .todo: .todo
        case .feature: .feature
        case .bug: .bug
        case .improvement: .improvement
        case .note: .note
        case .adr: nil
        }
    }

    public init(_ type: WorkItemType) {
        switch type {
        case .todo: self = .todo
        case .feature: self = .feature
        case .bug: self = .bug
        case .improvement: self = .improvement
        case .note: self = .note
        }
    }
}

/// One structured draft (several per version when the AI splits a note into tasks).
public struct DraftContent: Hashable, Sendable, Codable {
    public var classification: DraftClassification
    public var title: String
    public var goal: String
    public var context: String
    public var acceptanceCriteria: [String]
    public var technicalNotes: [String]
    public var testCases: [String]
    public var priority: Priority?
    public var dependencies: [String]
    /// Clarifying questions instead of invented details (spec H3).
    public var openQuestions: [String]

    public init(
        classification: DraftClassification, title: String, goal: String = "", context: String = "",
        acceptanceCriteria: [String] = [], technicalNotes: [String] = [], testCases: [String] = [],
        priority: Priority? = nil, dependencies: [String] = [], openQuestions: [String] = []
    ) {
        self.classification = classification
        self.title = title
        self.goal = goal
        self.context = context
        self.acceptanceCriteria = acceptanceCriteria
        self.technicalNotes = technicalNotes
        self.testCases = testCases
        self.priority = priority
        self.dependencies = dependencies
        self.openQuestions = openQuestions
    }
}

public struct DraftVersion: Hashable, Sendable, Codable, Identifiable {
    public let id: DraftVersionID
    public let workItemId: WorkItemID
    /// 1-based, per work item. Concurrent devices may produce the same number; order by `createdAt`.
    public let version: Int
    public let source: DraftVersionSource
    public let channel: DraftGenerationChannel?
    /// Raw `DraftMode` of the AI request (open string; the AI package owns the enum).
    public let mode: String?
    public let providerId: AIProviderID?
    public let modelId: AIModelID?
    /// Raw text for `original`/`transcript` versions.
    public let text: String?
    /// Structured drafts of an `ai` version.
    public let contents: [DraftContent]
    public let usage: TokenUsage
    public let createdAt: Date
    /// Set when the user adopted (parts of) this version into the work item.
    public private(set) var acceptedAt: Date?
    public private(set) var acceptedContentIndexes: [Int]
    public private(set) var revision: Int
    public private(set) var updatedAt: Date

    public init(
        id: DraftVersionID = DraftVersionID(),
        workItemId: WorkItemID,
        version: Int,
        source: DraftVersionSource,
        channel: DraftGenerationChannel? = nil,
        mode: String? = nil,
        providerId: AIProviderID? = nil,
        modelId: AIModelID? = nil,
        text: String? = nil,
        contents: [DraftContent] = [],
        usage: TokenUsage = TokenUsage(),
        createdAt: Date,
        acceptedAt: Date? = nil,
        acceptedContentIndexes: [Int] = []
    ) {
        self.id = id
        self.workItemId = workItemId
        self.version = version
        self.source = source
        self.channel = channel
        self.mode = mode
        self.providerId = providerId
        self.modelId = modelId
        self.text = text
        self.contents = contents
        self.usage = usage
        self.createdAt = createdAt
        self.acceptedAt = acceptedAt
        self.acceptedContentIndexes = acceptedContentIndexes.sorted()
        revision = 1
        updatedAt = acceptedAt ?? createdAt
    }

    public var isAccepted: Bool { acceptedAt != nil }

    /// Records the user's explicit adoption of the given contents (spec H3: „erst danach freigeben“).
    public mutating func accept(contentIndexes: [Int], at date: Date) {
        let valid = contentIndexes.filter { contents.isEmpty ? $0 == 0 : contents.indices.contains($0) }
        let merged = Array(Set(acceptedContentIndexes + valid)).sorted()
        guard merged != acceptedContentIndexes || acceptedAt == nil else { return }
        acceptedContentIndexes = merged
        if acceptedAt == nil { acceptedAt = date }
        revision += 1
        updatedAt = max(updatedAt, date)
    }

    /// Next version number for `item` given its existing versions.
    public static func nextVersion(after existing: [DraftVersion]) -> Int {
        (existing.map(\.version).max() ?? 0) + 1
    }
}
