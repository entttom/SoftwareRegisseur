import Foundation

public enum AudioUploadConsent: Hashable, Sendable, Codable {
    /// On-device transcription; no upload.
    case notRequired
    case pending
    case granted(at: Date)
    case denied(at: Date)

    public var permitsUpload: Bool {
        if case .granted = self { return true }
        return false
    }
}

public enum TranscriptionState: String, Hashable, Sendable, Codable, CaseIterable {
    case pending
    case inProgress
    case completed
    case failed
}

public enum AudioRetentionPolicy: Hashable, Sendable, Codable {
    case deleteAfterTranscription
    case keepLocally
    case keepForDays(Int)
}

/// Dictation recording (spec H2). `localAssetRef` points to a device-local file; audio is never synced.
public struct AudioNote: Hashable, Sendable, Codable, Identifiable {
    public let id: AudioNoteID
    public var workItemId: WorkItemID?
    public var localAssetRef: String
    public var provider: AIProviderID
    public var consent: AudioUploadConsent
    public var transcriptionState: TranscriptionState
    public var retentionPolicy: AudioRetentionPolicy
    public let createdAt: Date

    public init(
        id: AudioNoteID = AudioNoteID(),
        workItemId: WorkItemID? = nil,
        localAssetRef: String,
        provider: AIProviderID,
        consent: AudioUploadConsent,
        transcriptionState: TranscriptionState = .pending,
        retentionPolicy: AudioRetentionPolicy = .deleteAfterTranscription,
        createdAt: Date
    ) {
        self.id = id
        self.workItemId = workItemId
        self.localAssetRef = localAssetRef
        self.provider = provider
        self.consent = consent
        self.transcriptionState = transcriptionState
        self.retentionPolicy = retentionPolicy
        self.createdAt = createdAt
    }
}

public struct TokenUsage: Hashable, Sendable, Codable {
    public var inputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(inputTokens: lhs.inputTokens + rhs.inputTokens, outputTokens: lhs.outputTokens + rhs.outputTokens)
    }
}

/// Cost estimate computed by the app from usage; always labelled as an estimate.
public struct CostEstimate: Hashable, Sendable, Codable {
    public var amount: Decimal
    public var currencyCode: String

    public init(amount: Decimal, currencyCode: String) {
        self.amount = amount
        self.currencyCode = currencyCode
    }
}

public enum AIRequestMode: String, Hashable, Sendable, Codable, CaseIterable {
    case structureDraft
    case improveText
    case splitIntoTasks
    case proposeADR
    case withRepositoryContext
}

public enum AIRequestState: String, Hashable, Sendable, Codable, CaseIterable {
    case pending
    case running
    case completed
    case failed
    case cancelled
}

/// One text-AI drafting call (spec H3/H4). Uses its own provider/model, not the coding agent's.
public struct AIRequest: Hashable, Sendable, Codable, Identifiable {
    public let id: AIRequestID
    public let itemId: WorkItemID
    public var provider: AIProviderID
    public var model: AIModelID
    public var mode: AIRequestMode
    /// Revision of the item text sent to the model.
    public var inputVersion: Int
    /// Draft revision produced; nil until completed.
    public var draftVersion: Int?
    public var usage: TokenUsage?
    public var costEstimate: CostEstimate?
    public var state: AIRequestState
    public let createdAt: Date

    public init(
        id: AIRequestID = AIRequestID(),
        itemId: WorkItemID,
        provider: AIProviderID,
        model: AIModelID,
        mode: AIRequestMode,
        inputVersion: Int,
        draftVersion: Int? = nil,
        usage: TokenUsage? = nil,
        costEstimate: CostEstimate? = nil,
        state: AIRequestState = .pending,
        createdAt: Date
    ) {
        self.id = id
        self.itemId = itemId
        self.provider = provider
        self.model = model
        self.mode = mode
        self.inputVersion = inputVersion
        self.draftVersion = draftVersion
        self.usage = usage
        self.costEstimate = costEstimate
        self.state = state
        self.createdAt = createdAt
    }
}

public enum AIMessageRole: String, Hashable, Sendable, Codable, CaseIterable {
    case system
    case user
    case assistant
}

public struct AIMessage: Hashable, Sendable, Codable, Identifiable {
    public let id: AIMessageID
    public let role: AIMessageRole
    public let text: String
    public let createdAt: Date

    public init(id: AIMessageID = AIMessageID(), role: AIMessageRole, text: String, createdAt: Date) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

/// What the AI may see (spec H4: transparent context scope).
public enum AIContextScope: Hashable, Sendable, Codable {
    case itemOnly
    case project(ProjectID)
    case repositoryFiles(ProjectID, paths: [String])
}

public struct AIConversation: Hashable, Sendable, Codable, Identifiable {
    public let id: AIConversationID
    public let itemId: WorkItemID
    public var provider: AIProviderID
    public var model: AIModelID
    public private(set) var messages: [AIMessage]
    public var contextScope: AIContextScope
    public var proposedDraftVersion: Int?
    public private(set) var usage: TokenUsage
    public let createdAt: Date
    public private(set) var updatedAt: Date

    public init(
        id: AIConversationID = AIConversationID(),
        itemId: WorkItemID,
        provider: AIProviderID,
        model: AIModelID,
        messages: [AIMessage] = [],
        contextScope: AIContextScope = .itemOnly,
        proposedDraftVersion: Int? = nil,
        usage: TokenUsage = TokenUsage(),
        createdAt: Date
    ) {
        self.id = id
        self.itemId = itemId
        self.provider = provider
        self.model = model
        self.messages = messages
        self.contextScope = contextScope
        self.proposedDraftVersion = proposedDraftVersion
        self.usage = usage
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    public mutating func append(_ message: AIMessage, usage additional: TokenUsage = TokenUsage()) {
        messages.append(message)
        usage = usage + additional
        updatedAt = max(updatedAt, message.createdAt)
    }
}

public enum ProviderPurpose: String, Hashable, Sendable, Codable, CaseIterable {
    case textDrafting
    case conversation
    case transcription
}

public enum DeviceScope: String, Hashable, Sendable, Codable, CaseIterable {
    /// Key exists only in this device's keychain.
    case thisDeviceOnly
    /// Key is in the iCloud Keychain (synchronizable item), never in CloudKit records.
    case iCloudKeychain
}

/// Keychain lookup coordinates. Contains no secret material.
public struct KeychainReference: Hashable, Sendable, Codable {
    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }
}

/// BYOK provider configuration (spec I, ADR-0008). Holds only a keychain reference, never a key.
public struct ProviderProfile: Hashable, Sendable, Codable, Identifiable {
    public let id: ProviderProfileID
    public var providerId: AIProviderID
    public var purpose: ProviderPurpose
    public var model: AIModelID?
    public var keychainReference: KeychainReference?
    public var deviceScope: DeviceScope
    /// Non-secret provider options (e.g. base URL, language).
    public var settings: [String: String]

    public init(
        id: ProviderProfileID = ProviderProfileID(),
        providerId: AIProviderID,
        purpose: ProviderPurpose,
        model: AIModelID? = nil,
        keychainReference: KeychainReference? = nil,
        deviceScope: DeviceScope = .thisDeviceOnly,
        settings: [String: String] = [:]
    ) {
        self.id = id
        self.providerId = providerId
        self.purpose = purpose
        self.model = model
        self.keychainReference = keychainReference
        self.deviceScope = deviceScope
        self.settings = settings
    }
}
