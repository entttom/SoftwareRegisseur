import Foundation

public enum AIContextKind: String, Sendable, Hashable, Codable, CaseIterable {
    case originalNote
    case transcript
    case currentDraft
    case existingRequest
    case adrIndex
    case repositoryStructure
    case sourceFile
    case other

    /// Primary items are truncated instead of dropped when the budget is tight.
    var isPrimary: Bool {
        switch self {
        case .originalNote, .transcript, .currentDraft: return true
        default: return false
        }
    }

    public var displayName: String {
        switch self {
        case .originalNote: return "Originalnotiz"
        case .transcript: return "Transkript"
        case .currentDraft: return "Aktueller Entwurf"
        case .existingRequest: return "Bestehender Request"
        case .adrIndex: return "ADR-Index"
        case .repositoryStructure: return "Repository-Struktur"
        case .sourceFile: return "Quellcodedatei"
        case .other: return "Sonstiger Kontext"
        }
    }
}

/// One piece of content that may be sent to a text provider.
public struct AIContextItem: Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: AIContextKind
    public var title: String
    /// Repository-relative path for files; used for secret path exclusion.
    public var path: String?
    public var content: String

    public init(id: String = UUID().uuidString, kind: AIContextKind, title: String, path: String? = nil, content: String) {
        self.id = id
        self.kind = kind
        self.title = title
        self.path = path
        self.content = content
    }
}

public enum ContextExclusionReason: Sendable, Hashable {
    /// Path matches a secret pattern (spec H4); content is never read into the request.
    case secretPath(pattern: String)
    case overBudget
    case empty

    public var userMessage: String {
        switch self {
        case .secretPath(let pattern): return String(localized: "Ausgeschlossen: mögliche Geheimnisse (Muster „\(pattern)“)", bundle: .module)
        case .overBudget: return String(localized: "Ausgeschlossen: Kontextbudget überschritten", bundle: .module)
        case .empty: return "Ausgeschlossen: leer"
        }
    }
}

public struct ContextManifest: Sendable, Hashable {
    public struct Included: Sendable, Hashable, Identifiable {
        public var id: String
        public var kind: AIContextKind
        public var title: String
        public var path: String?
        public var characterCount: Int
        public var redactionCount: Int
        public var truncated: Bool
    }

    public struct Excluded: Sendable, Hashable, Identifiable {
        public var id: String
        public var kind: AIContextKind
        public var title: String
        public var path: String?
        public var reason: ContextExclusionReason
    }

    public var provider: AIProviderID
    public var model: String
    public var included: [Included]
    public var excluded: [Excluded]
    /// Characters of the complete request text (instructions + data + messages).
    public var totalCharacters: Int

    /// Rough heuristic (~4 characters per token); shown as an estimate only.
    public var estimatedTokens: Int { (totalCharacters + 3) / 4 }
    public var totalRedactions: Int { included.reduce(0) { $0 + $1.redactionCount } }
}

public struct ContextBudget: Sendable, Hashable {
    /// Maximum characters of context data (not counting instructions).
    public var maxCharacters: Int

    public init(maxCharacters: Int = 120_000) {
        self.maxCharacters = maxCharacters
    }
}

/// Applies the secret filter and the budget, producing the exact items to send plus a manifest.
struct ContextPreparer {
    var filter: ContextSecretFilter
    var budget: ContextBudget

    struct Prepared {
        var items: [AIContextItem]
        var included: [ContextManifest.Included]
        var excluded: [ContextManifest.Excluded]
    }

    func prepare(_ items: [AIContextItem]) -> Prepared {
        var prepared = Prepared(items: [], included: [], excluded: [])
        var remaining = budget.maxCharacters

        // Primary items first so the note itself always gets budget before repository context.
        let ordered = items.filter { $0.kind.isPrimary } + items.filter { !$0.kind.isPrimary }
        for item in ordered {
            func exclude(_ reason: ContextExclusionReason) {
                prepared.excluded.append(.init(id: item.id, kind: item.kind, title: item.title, path: item.path, reason: reason))
            }
            if let path = item.path, let pattern = filter.exclusionPattern(forPath: path) {
                exclude(.secretPath(pattern: pattern))
                continue
            }
            let redacted = filter.redact(item.content)
            var content = redacted.text
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                exclude(.empty)
                continue
            }
            var truncated = false
            if content.count > remaining {
                guard item.kind.isPrimary, remaining > 0 else {
                    exclude(.overBudget)
                    continue
                }
                content = String(content.prefix(remaining)) + "\n[… gekürzt]"
                truncated = true
            }
            remaining -= min(content.count, remaining)
            var sanitized = item
            sanitized.content = content
            prepared.items.append(sanitized)
            prepared.included.append(.init(
                id: item.id, kind: item.kind, title: item.title, path: item.path,
                characterCount: content.count, redactionCount: redacted.redactionCount, truncated: truncated
            ))
        }
        return prepared
    }
}
