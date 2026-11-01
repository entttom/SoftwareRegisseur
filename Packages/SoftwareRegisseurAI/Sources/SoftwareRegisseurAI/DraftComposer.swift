import Foundation

/// Elaboration modes (spec H3).
public enum DraftMode: String, Sendable, Hashable, Codable, CaseIterable {
    case kurz
    case ausfuehrlich
    case akzeptanzkriterienErgaenzen
    case technischeDetails
    case inAufgabenAufteilen

    public var displayName: String {
        switch self {
        case .kurz: return String(localized: "Kurz ausarbeiten", bundle: .module)
        case .ausfuehrlich: return String(localized: "Ausführlich", bundle: .module)
        case .akzeptanzkriterienErgaenzen: return String(localized: "Akzeptanzkriterien ergänzen", bundle: .module)
        case .technischeDetails: return String(localized: "Technische Details", bundle: .module)
        case .inAufgabenAufteilen: return String(localized: "In Aufgaben aufteilen", bundle: .module)
        }
    }

    public var allowsMultipleDrafts: Bool { self == .inAufgabenAufteilen }

    var instruction: String {
        switch self {
        case .kurz:
            return "MODE: short. Produce exactly one concise draft: a short goal and context, only the essential acceptance criteria (at most three), short or empty lists elsewhere."
        case .ausfuehrlich:
            return "MODE: detailed. Produce exactly one thorough draft: full context, complete testable acceptance criteria, technical notes, test cases, priority and dependencies where the data supports them."
        case .akzeptanzkriterienErgaenzen:
            return "MODE: add acceptance criteria. Produce exactly one draft. Keep the existing draft content (if given) and focus on adding complete, testable acceptance criteria and matching test cases. Change other fields only to fix obvious inconsistencies."
        case .technischeDetails:
            return "MODE: technical details. Produce exactly one draft. Keep the existing content and elaborate the technical notes (affected components, interfaces, data, risks) using only the provided data; put unknown technical facts into openQuestions."
        case .inAufgabenAufteilen:
            return "MODE: split into tasks. Split the material into separate, independently implementable work items and produce one self-contained draft per item (a single draft if there is only one topic). Reference related drafts in dependencies by their title."
        }
    }
}

/// Input for elaboration: original note and transcript are kept separate (spec H3 versioning).
public struct DraftInput: Sendable, Hashable {
    public var originalNote: String
    public var transcript: String?
    public var currentDraft: StructuredDraft?
    /// Synced project data (requests, ADR index) or Mac repository context (spec H4).
    public var projectContext: [AIContextItem]

    public init(
        originalNote: String,
        transcript: String? = nil,
        currentDraft: StructuredDraft? = nil,
        projectContext: [AIContextItem] = []
    ) {
        self.originalNote = originalNote
        self.transcript = transcript
        self.currentDraft = currentDraft
        self.projectContext = projectContext
    }

    func contextItems() -> [AIContextItem] {
        var items = [AIContextItem(id: "original-note", kind: .originalNote, title: "Originalnotiz", content: originalNote)]
        if let transcript {
            items.append(AIContextItem(id: "transcript", kind: .transcript, title: "Transkript", content: transcript))
        }
        if let currentDraft, let json = try? JSONValue.parse(JSONEncoder().encode(currentDraft)).encodedString() {
            items.append(AIContextItem(id: "current-draft", kind: .currentDraft, title: "Aktueller Entwurf", content: json))
        }
        return items + projectContext
    }
}

/// A fully prepared request; the manifest is shown to the user before sending (spec H3/H4).
public struct PreparedDraftRequest: Sendable, Hashable {
    public var mode: DraftMode
    public var manifest: ContextManifest
    public var request: TextGenerationRequest
}

public struct DraftComposition: Sendable, Hashable {
    public var mode: DraftMode
    public var drafts: [StructuredDraft]
    public var provider: AIProviderID
    public var model: String
    public var usage: AIUsage
    public var manifest: ContextManifest
    public var requestID: String?
}

/// Turns a raw note into structured draft(s) via a `TextAIProvider` (spec H3).
/// Produces drafts only; approval and any agent start are separate user actions.
public struct DraftComposer: Sendable {
    public var provider: any TextAIProvider
    public var model: String
    public var filter: ContextSecretFilter
    public var budget: ContextBudget
    public var maxOutputTokens: Int
    private let nonce: @Sendable () -> String

    public init(
        provider: any TextAIProvider,
        model: String,
        filter: ContextSecretFilter = ContextSecretFilter(),
        budget: ContextBudget = ContextBudget(),
        maxOutputTokens: Int = 8192,
        nonce: @escaping @Sendable () -> String = { UntrustedDataFormatter.randomNonce() }
    ) {
        self.provider = provider
        self.model = model
        self.filter = filter
        self.budget = budget
        self.maxOutputTokens = maxOutputTokens
        self.nonce = nonce
    }

    public func prepare(_ input: DraftInput, mode: DraftMode) throws -> PreparedDraftRequest {
        guard !input.originalNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(input.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AIProviderError.invalidRequest(String(localized: "Notiz ist leer", bundle: .module))
        }
        let formatter = UntrustedDataFormatter(nonce: nonce())
        let prepared = ContextPreparer(filter: filter, budget: budget).prepare(input.contextItems())

        let system = Self.systemPrompt(formatter: formatter)
        let user = """
        \(mode.instruction)

        Work only with the data blocks below. Respond with JSON of the form {"drafts": [ … ]}.

        \(formatter.blocks(for: prepared.items))
        """
        let request = TextGenerationRequest(
            model: model,
            systemPrompt: system,
            messages: [.user(user)],
            structuredOutput: StructuredOutputFormat(name: "software_regisseur_drafts", schema: DraftSchema.draftList),
            maxOutputTokens: maxOutputTokens
        )
        let manifest = ContextManifest(
            provider: provider.providerID, model: model, included: prepared.included, excluded: prepared.excluded,
            totalCharacters: system.count + user.count
        )
        return PreparedDraftRequest(mode: mode, manifest: manifest, request: request)
    }

    public func compose(_ prepared: PreparedDraftRequest) async throws -> DraftComposition {
        let result = try await provider.generate(prepared.request)
        let list = try result.decodeStructured(DraftList.self)
        try list.drafts.forEach { try $0.validate() }
        if list.drafts.isEmpty {
            throw AIProviderError.invalidResponse("Kein Entwurf erhalten")
        }
        if !prepared.mode.allowsMultipleDrafts && list.drafts.count != 1 {
            throw AIProviderError.invalidResponse(String(localized: "Genau ein Entwurf erwartet, \(list.drafts.count) erhalten", bundle: .module))
        }
        return DraftComposition(
            mode: prepared.mode, drafts: list.drafts, provider: result.provider, model: result.model,
            usage: result.usage, manifest: prepared.manifest, requestID: result.requestID
        )
    }

    public func compose(_ input: DraftInput, mode: DraftMode) async throws -> DraftComposition {
        try await compose(try prepare(input, mode: mode))
    }

    static func systemPrompt(formatter: UntrustedDataFormatter) -> String {
        """
        You are the drafting assistant of "Software Regisseur". You turn a raw software idea (note or dictation transcript) into structured work item drafts that a human reviews before anything happens.

        \(formatter.guardInstructions)

        CONTENT RULES:
        - Classify each draft as one of: todo, feature, bug, improvement, adr, note.
        - Fill title, goal, context, acceptanceCriteria, technicalNotes, testCases, priority, dependencies and openQuestions.
        - Do not invent requirements, names, numbers or technical facts that are not supported by the data. When something important is unclear or missing, add a precise clarifying question to openQuestions and leave the field empty or general.
        - Use priority "unspecified" unless the data states or clearly implies a priority.
        - Write in the language of the original note.
        """
    }
}

struct DraftList: Decodable {
    var drafts: [StructuredDraft]
}
