import Foundation

/// Classification of a draft (spec H3: Todo/Feature/Bug/ADR, plus improvement and note).
public enum DraftType: String, Sendable, Hashable, Codable, CaseIterable {
    case todo, feature, bug, improvement, adr, note

    /// Enum casing is not guaranteed by every provider (research §2.3) → case-insensitive.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = DraftType(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased()) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown draft type"))
        }
        self = value
    }
}

public enum DraftPriority: String, Sendable, Hashable, Codable, CaseIterable {
    case low, medium, high, critical
}

/// AI-generated, reviewable draft (spec H3). Never auto-approved, never starts an agent.
public struct StructuredDraft: Sendable, Hashable, Codable {
    public var type: DraftType
    public var title: String
    public var goal: String
    public var context: String
    public var acceptanceCriteria: [String]
    public var technicalNotes: [String]
    public var testCases: [String]
    public var priority: DraftPriority?
    public var dependencies: [String]
    /// Clarifying questions instead of invented details (spec H3).
    public var openQuestions: [String]

    public init(
        type: DraftType,
        title: String,
        goal: String = "",
        context: String = "",
        acceptanceCriteria: [String] = [],
        technicalNotes: [String] = [],
        testCases: [String] = [],
        priority: DraftPriority? = nil,
        dependencies: [String] = [],
        openQuestions: [String] = []
    ) {
        self.type = type
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

    enum CodingKeys: String, CodingKey {
        case type, title, goal, context, acceptanceCriteria, technicalNotes, testCases, priority, dependencies, openQuestions
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func list(_ key: CodingKeys) throws -> [String] {
            (try c.decodeIfPresent([String].self, forKey: key) ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        type = try c.decode(DraftType.self, forKey: .type)
        title = try c.decode(String.self, forKey: .title).trimmingCharacters(in: .whitespacesAndNewlines)
        goal = (try c.decodeIfPresent(String.self, forKey: .goal) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        context = (try c.decodeIfPresent(String.self, forKey: .context) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        acceptanceCriteria = try list(.acceptanceCriteria)
        technicalNotes = try list(.technicalNotes)
        testCases = try list(.testCases)
        dependencies = try list(.dependencies)
        openQuestions = try list(.openQuestions)
        // Schema uses "unspecified" instead of a nullable union (fewer unions, research §2.3).
        let rawPriority = (try c.decodeIfPresent(String.self, forKey: .priority))?.lowercased()
        priority = rawPriority.flatMap(DraftPriority.init(rawValue:))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(title, forKey: .title)
        try c.encode(goal, forKey: .goal)
        try c.encode(context, forKey: .context)
        try c.encode(acceptanceCriteria, forKey: .acceptanceCriteria)
        try c.encode(technicalNotes, forKey: .technicalNotes)
        try c.encode(testCases, forKey: .testCases)
        try c.encode(priority?.rawValue ?? DraftSchema.unspecifiedPriority, forKey: .priority)
        try c.encode(dependencies, forKey: .dependencies)
        try c.encode(openQuestions, forKey: .openQuestions)
    }

    func validate() throws {
        if title.isEmpty {
            throw AIProviderError.invalidResponse(String(localized: "Entwurf ohne Titel", bundle: .module))
        }
    }
}

/// JSON schemas in the lowest common denominator of OpenAI, Anthropic and Gemini
/// (research §2.3): every field required, `additionalProperties: false`, no length/number
/// constraints, no unions, flat structure.
public enum DraftSchema {
    static let unspecifiedPriority = "unspecified"

    public static var draft: JSONValue {
        let stringList: JSONValue = ["type": "array", "items": ["type": "string"]]
        return [
            "type": "object",
            "properties": [
                "type": ["type": "string", "enum": .array(DraftType.allCases.map { .string($0.rawValue) })],
                "title": ["type": "string"],
                "goal": ["type": "string"],
                "context": ["type": "string"],
                "acceptanceCriteria": stringList,
                "technicalNotes": stringList,
                "testCases": stringList,
                "priority": [
                    "type": "string",
                    "enum": .array(([unspecifiedPriority] + DraftPriority.allCases.map(\.rawValue)).map { .string($0) }),
                ],
                "dependencies": stringList,
                "openQuestions": stringList,
            ],
            "required": .array(StructuredDraft.CodingKeys.allNames.map { .string($0) }),
            "additionalProperties": false,
        ]
    }

    /// `{ "drafts": [draft, …] }`
    public static var draftList: JSONValue {
        [
            "type": "object",
            "properties": ["drafts": ["type": "array", "items": draft]],
            "required": ["drafts"],
            "additionalProperties": false,
        ]
    }

    /// `{ "reply": string, "proposedDrafts": [draft] }` – an empty array means no proposal.
    public static var conversationReply: JSONValue {
        [
            "type": "object",
            "properties": [
                "reply": ["type": "string"],
                "proposedDrafts": ["type": "array", "items": draft],
            ],
            "required": ["reply", "proposedDrafts"],
            "additionalProperties": false,
        ]
    }
}

extension StructuredDraft.CodingKeys {
    static let allNames = [
        "type", "title", "goal", "context", "acceptanceCriteria", "technicalNotes", "testCases",
        "priority", "dependencies", "openQuestions",
    ]
}
