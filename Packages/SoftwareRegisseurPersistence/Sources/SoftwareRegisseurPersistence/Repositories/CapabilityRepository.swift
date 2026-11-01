import Foundation
import GRDB
import SoftwareRegisseurDomain

/// Hosts and their detected agent capabilities (spec J1, N4, ADR-0006).
public protocol CapabilityRepository: Sendable {
    /// Saves the host row and every capability it carries.
    func saveHost(_ host: AgentHost, at date: Date) async throws
    func recordHeartbeat(_ hostId: HostID, ready: Bool, at date: Date) async throws
    func host(_ id: HostID) async throws -> AgentHost?
    func hosts() async throws -> [AgentHost]
    /// Saves one capability. `capabilityRevision` never decreases and is bumped when the detected
    /// catalog, model × effort matrix or support flags changed without a higher revision (A40).
    @discardableResult
    func saveCapability(_ capability: AgentCapability, at date: Date) async throws -> AgentCapability
    /// Full detection result for a host: saves all, deletes capabilities no longer reported.
    func replaceCapabilities(hostId: HostID, with capabilities: [AgentCapability], at date: Date) async throws -> [AgentCapability]
    func capability(hostId: HostID, providerId: ProviderID) async throws -> AgentCapability?
    func capabilities(hostId: HostID) async throws -> [AgentCapability]
    func capabilities(providerId: ProviderID) async throws -> [AgentCapability]
}

public struct GRDBCapabilityRepository: CapabilityRepository {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func saveHost(_ host: AgentHost, at date: Date = .now) async throws {
        try await database.write { db in
            try SyncBookkeeping.upsert(db, AgentHostStorage.self, host, at: date)
            for capability in host.agentCapabilities {
                guard capability.hostId == host.hostId else {
                    throw StoreError.identityFieldChanged(entity: .agentCapability, field: "hostId")
                }
                _ = try Self.saveCapability(db, capability, at: date)
            }
        }
    }

    public func recordHeartbeat(_ hostId: HostID, ready: Bool, at date: Date = .now) async throws {
        try await database.write { db in
            guard var host = try AgentHostStorage.fetch(db, syncID: hostId.rawValue) else {
                throw StoreError.notFound(entity: .agentHost, id: hostId.uuidString)
            }
            host.lastSeen = date
            host.ready = ready
            try SyncBookkeeping.save(db, AgentHostStorage.self, host, isNew: false, at: date)
        }
    }

    public func host(_ id: HostID) async throws -> AgentHost? {
        try await database.read { db in try AgentHostStorage.fetch(db, syncID: id.rawValue) }
    }

    public func hosts() async throws -> [AgentHost] {
        try await database.read { db in
            try String.fetchAll(db, sql: "SELECT host_id FROM agent_hosts ORDER BY name, host_id").compactMap { id in
                try UUID(uuidString: id).flatMap { try AgentHostStorage.fetch(db, syncID: $0) }
            }
        }
    }

    @discardableResult
    public func saveCapability(_ capability: AgentCapability, at date: Date = .now) async throws -> AgentCapability {
        try await database.write { db in try Self.saveCapability(db, capability, at: date) }
    }

    public func replaceCapabilities(hostId: HostID, with capabilities: [AgentCapability], at date: Date = .now) async throws -> [AgentCapability] {
        try await database.write { db in
            let saved = try capabilities.map { capability in
                guard capability.hostId == hostId else {
                    throw StoreError.identityFieldChanged(entity: .agentCapability, field: "hostId")
                }
                return try Self.saveCapability(db, capability, at: date)
            }
            let reported = Set(capabilities.map(\.providerId))
            for stale in try AgentCapabilityStorage.fetchAll(db, hostId: hostId) where !reported.contains(stale.providerId) {
                try SyncBookkeeping.delete(db, AgentCapabilityStorage.self, syncID: AgentCapabilityStorage.syncID(of: stale), at: date)
            }
            return saved
        }
    }

    public func capability(hostId: HostID, providerId: ProviderID) async throws -> AgentCapability? {
        try await database.read { db in
            try AgentCapabilityStorage.fetch(db, syncID: AgentCapabilityStorage.syncID(hostId: hostId, providerId: providerId))
        }
    }

    public func capabilities(hostId: HostID) async throws -> [AgentCapability] {
        try await database.read { db in try AgentCapabilityStorage.fetchAll(db, hostId: hostId) }
    }

    public func capabilities(providerId: ProviderID) async throws -> [AgentCapability] {
        try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM agent_capabilities WHERE provider_id = ? ORDER BY host_id",
                             arguments: [providerId.rawValue]).map { try AgentCapabilityStorage.decode(db, $0) }
        }
    }

    static func saveCapability(_ db: Database, _ capability: AgentCapability, at date: Date) throws -> AgentCapability {
        var value = capability
        if let stored = try AgentCapabilityStorage.fetch(db, syncID: AgentCapabilityStorage.syncID(of: capability)) {
            if detectedFactsDiffer(stored, value), value.capabilityRevision <= stored.capabilityRevision {
                value.capabilityRevision = stored.capabilityRevision + 1
            } else if value.capabilityRevision < stored.capabilityRevision {
                value.capabilityRevision = stored.capabilityRevision
            }
            guard value != stored else { return stored }
            try SyncBookkeeping.save(db, AgentCapabilityStorage.self, value, isNew: false, at: date)
        } else {
            try SyncBookkeeping.save(db, AgentCapabilityStorage.self, value, isNew: true, at: date)
        }
        return value
    }

    /// Facts that affect model/effort validation; timestamps and diagnostics are ignored.
    static func detectedFactsDiffer(_ a: AgentCapability, _ b: AgentCapability) -> Bool {
        func models(_ c: AgentCapability) -> [[String]] {
            c.modelCatalog.map { m in
                [m.providerId.rawValue, m.modelId.rawValue, m.availability.rawValue, m.defaultEffortId?.rawValue ?? ""]
                    + m.supportedEffortIds.map(\.rawValue)
            }
        }
        return a.version != b.version || a.installed != b.installed || a.authenticated != b.authenticated
            || a.runnable != b.runnable || a.supportsModelSelection != b.supportsModelSelection
            || a.supportsEffortSelection != b.supportsEffortSelection || a.defaultModelId != b.defaultModelId
            || models(a) != models(b)
    }
}

/// Global and project model/effort preferences per agent (ADR-0006, A38).
public protocol PreferenceRepository: Sendable {
    func save(_ preference: AgentModelPreference, at date: Date) async throws
    func preference(scope: PreferenceScope, providerId: ProviderID) async throws -> AgentModelPreference?
    func preferences(scope: PreferenceScope) async throws -> [AgentModelPreference]
    func remove(scope: PreferenceScope, providerId: ProviderID, at date: Date) async throws
}

public struct GRDBPreferenceRepository: PreferenceRepository {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func save(_ preference: AgentModelPreference, at date: Date = .now) async throws {
        try await database.write { db in _ = try SyncBookkeeping.upsert(db, AgentModelPreferenceStorage.self, preference, at: date) }
    }

    public func preference(scope: PreferenceScope, providerId: ProviderID) async throws -> AgentModelPreference? {
        try await database.read { db in
            try AgentModelPreferenceStorage.fetch(db, syncID: AgentModelPreferenceStorage.syncID(scope: scope, providerId: providerId))
        }
    }

    public func preferences(scope: PreferenceScope) async throws -> [AgentModelPreference] {
        try await database.read { db in
            try AgentModelPreferenceStorage.fetchAll(db, scopeKey: AgentModelPreferenceStorage.scopeKey(scope))
        }
    }

    public func remove(scope: PreferenceScope, providerId: ProviderID, at date: Date = .now) async throws {
        try await database.write { db in
            try SyncBookkeeping.delete(db, AgentModelPreferenceStorage.self,
                                       syncID: AgentModelPreferenceStorage.syncID(scope: scope, providerId: providerId), at: date)
        }
    }
}
