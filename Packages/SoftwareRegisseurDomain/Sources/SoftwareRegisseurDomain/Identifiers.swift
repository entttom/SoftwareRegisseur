import Foundation

/// Typed UUID wrapper. `Tag` is a phantom type, so IDs of different entities cannot be mixed up.
/// Encodes as a plain UUID string.
public struct Identifier<Tag>: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    /// Creates a new random identifier, or wraps the given UUID.
    public init(_ uuid: UUID = UUID()) {
        self.rawValue = uuid
    }

    public init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        self.rawValue = uuid
    }

    public var uuidString: String { rawValue.uuidString }
    public var description: String { rawValue.uuidString }

    /// First eight lowercase hex characters, e.g. for branch names (spec L2).
    public var shortString: String { String(rawValue.uuidString.prefix(8)).lowercased() }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Phantom tags for identifiers that have no dedicated entity type in this package.
public enum IdentifierTag {
    public enum IdempotencyKey {}
    public enum Device {}
    public enum AIMessage {}
}

public typealias ProjectID = Identifier<Project>
public typealias ProjectSettingsID = Identifier<ProjectSettings>
public typealias WorkItemID = Identifier<WorkItem>
public typealias ADRID = Identifier<ADR>
public typealias JobID = Identifier<AgentJob>
public typealias HostID = Identifier<AgentHost>
public typealias LockID = Identifier<TaskLock>
public typealias EventID = Identifier<TaskEvent>
public typealias ReviewID = Identifier<Review>
public typealias AudioNoteID = Identifier<AudioNote>
public typealias AIRequestID = Identifier<AIRequest>
public typealias AIConversationID = Identifier<AIConversation>
public typealias AIMessageID = Identifier<IdentifierTag.AIMessage>
public typealias SyncOperationID = Identifier<SyncOperation>
public typealias ProviderProfileID = Identifier<ProviderProfile>
public typealias IdempotencyKey = Identifier<IdentifierTag.IdempotencyKey>
public typealias DeviceID = Identifier<IdentifierTag.Device>
