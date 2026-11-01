import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

/// Synced user-wide defaults (spec F2, J2, P 8): default agent, folder layout, workspace defaults.
/// Replaces the device-only `AppSettings.defaultAgent` of earlier builds.
public struct GlobalDefaultsEditor: Sendable {
    public let repository: any GlobalSettingsRepository

    public init(repository: any GlobalSettingsRepository) {
        self.repository = repository
    }

    public func load() async throws -> GlobalSettings {
        try await repository.fetch()
    }

    /// Saves a change made from `base` (optimistic; a concurrent edit on another device fails with
    /// `revisionConflict` and is reloaded instead of overwritten).
    @discardableResult
    public func update(from base: GlobalSettings, at date: Date, _ change: (inout GlobalSettings) -> Void) async throws -> GlobalSettings {
        var updated = base
        change(&updated)
        return try await repository.save(updated, expectedRevision: base.revision, at: date)
    }

    @discardableResult
    public func setDefaultAgent(_ provider: ProviderID?, at date: Date) async throws -> GlobalSettings {
        let current = try await repository.fetch()
        return try await update(from: current, at: date) { $0.defaultAgentId = provider }
    }

    /// One-time move of the legacy device-only default agent into the synced settings. A value already
    /// chosen in the synced settings wins. Clears the local value either way; returns whether it moved.
    @discardableResult
    public func importLegacyDefaultAgent(from settings: inout AppSettings, at date: Date) async throws -> Bool {
        guard let legacy = settings.defaultAgent else { return false }
        let current = try await repository.fetch()
        var moved = false
        if current.defaultAgentId == nil {
            _ = try await update(from: current, at: date) { $0.defaultAgentId = legacy }
            moved = true
        }
        settings.defaultAgent = nil
        return moved
    }
}
