import Foundation
import GRDB
import SoftwareRegisseurDomain

public protocol ProjectRepository: Sendable {
    /// Creates project and settings (including project-scoped model preferences) atomically.
    func create(_ project: Project, settings: ProjectSettings, at date: Date) async throws
    func fetch(_ id: ProjectID) async throws -> Project?
    func fetch(repositoryIdentity: RepositoryIdentity) async throws -> [Project]
    func list(statuses: Set<ProjectStatus>) async throws -> [Project]
    func update(_ project: Project, expectedRevision: Int, at date: Date) async throws -> Project
    func transition(_ id: ProjectID, to status: ProjectStatus, expectedRevision: Int, at date: Date) async throws -> Project
    func settings(forProject id: ProjectID) async throws -> ProjectSettings?
    /// Saves settings with optimistic revision check; `agentModelPreferencesByProvider` replaces the
    /// project's stored preferences (single source of truth: `agent_model_preferences`).
    func saveSettings(_ settings: ProjectSettings, expectedRevision: Int, at date: Date) async throws -> ProjectSettings
    func saveLocation(_ location: RepositoryLocation, at date: Date) async throws
    func locations(projectId: ProjectID) async throws -> [RepositoryLocation]
    func locations(hostId: HostID) async throws -> [RepositoryLocation]
    func deleteLocation(projectId: ProjectID, hostId: HostID, at date: Date) async throws
    /// Deletes an empty project with its settings, locations and preferences (tombstones + outbox).
    func delete(_ id: ProjectID, expectedRevision: Int, at date: Date) async throws
}

public struct GRDBProjectRepository: ProjectRepository {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func create(_ project: Project, settings: ProjectSettings, at date: Date = .now) async throws {
        try await database.write { db in
            guard project.settingsId == settings.id else { throw StoreError.settingsMismatch(projectId: project.id) }
            if try ProjectStorage.fetch(db, syncID: project.id.rawValue) != nil {
                throw StoreError.alreadyExists(entity: .project, id: project.id.uuidString)
            }
            if try ProjectSettingsStorage.fetch(db, syncID: settings.id.rawValue) != nil {
                throw StoreError.alreadyExists(entity: .projectSettings, id: settings.id.uuidString)
            }
            try SyncBookkeeping.save(db, ProjectSettingsStorage.self, settings, isNew: true, at: date)
            try SyncBookkeeping.save(db, ProjectStorage.self, project, isNew: true, at: date)
            try Self.replacePreferences(db, projectId: project.id, with: settings.agentModelPreferencesByProvider, at: date)
        }
    }

    public func fetch(_ id: ProjectID) async throws -> Project? {
        try await database.read { db in try ProjectStorage.fetch(db, syncID: id.rawValue) }
    }

    public func fetch(repositoryIdentity: RepositoryIdentity) async throws -> [Project] {
        try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM projects WHERE repository_identity = ? ORDER BY created_at, id",
                             arguments: [repositoryIdentity.rawValue]).map(ProjectStorage.decode)
        }
    }

    public func list(statuses: Set<ProjectStatus> = []) async throws -> [Project] {
        try await database.read { db in
            var sql = "SELECT * FROM projects"
            let values = statuses.map(\.rawValue).sorted()
            if !values.isEmpty { sql += " WHERE status IN (\(GRDBAgentJobRepository.placeholders(values.count)))" }
            sql += " ORDER BY name COLLATE NOCASE, id"
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(values)).map(ProjectStorage.decode)
        }
    }

    public func update(_ project: Project, expectedRevision: Int, at date: Date = .now) async throws -> Project {
        try await database.write { db in
            let stored = try Self.fetchForUpdate(db, project.id, expectedRevision: expectedRevision)
            guard project.createdAt == stored.createdAt, project.settingsId == stored.settingsId else {
                throw StoreError.identityFieldChanged(entity: .project, field: "createdAt/settingsId")
            }
            if project.status != stored.status, !stored.status.canTransition(to: project.status) {
                throw StoreError.invalidProjectTransition(InvalidStateTransition(from: stored.status, to: project.status))
            }
            var updated = project
            if updated.revision == expectedRevision { updated.touch(at: date) }
            guard updated.revision > expectedRevision else {
                throw StoreError.revisionConflict(entity: .project, id: project.id.uuidString, expected: expectedRevision, actual: project.revision)
            }
            try SyncBookkeeping.save(db, ProjectStorage.self, updated, isNew: false, at: date)
            return updated
        }
    }

    public func transition(_ id: ProjectID, to status: ProjectStatus, expectedRevision: Int, at date: Date = .now) async throws -> Project {
        try await database.write { db in
            var project = try Self.fetchForUpdate(db, id, expectedRevision: expectedRevision)
            do throws(InvalidStateTransition<ProjectStatus>) {
                try project.transition(to: status, at: date)
            } catch {
                throw StoreError.invalidProjectTransition(error)
            }
            try SyncBookkeeping.save(db, ProjectStorage.self, project, isNew: false, at: date)
            return project
        }
    }

    public func settings(forProject id: ProjectID) async throws -> ProjectSettings? {
        try await database.read { db in
            guard let project = try ProjectStorage.fetch(db, syncID: id.rawValue) else { return nil }
            return try ProjectSettingsStorage.fetch(db, syncID: project.settingsId.rawValue)
        }
    }

    public func saveSettings(_ settings: ProjectSettings, expectedRevision: Int, at date: Date = .now) async throws -> ProjectSettings {
        try await database.write { db in
            guard let stored = try ProjectSettingsStorage.fetch(db, syncID: settings.id.rawValue) else {
                throw StoreError.notFound(entity: .projectSettings, id: settings.id.uuidString)
            }
            guard stored.revision == expectedRevision else {
                throw StoreError.revisionConflict(entity: .projectSettings, id: settings.id.uuidString,
                                                        expected: expectedRevision, actual: stored.revision)
            }
            var updated = settings
            if updated.revision == expectedRevision { updated.touch(at: date) }
            guard updated.revision > expectedRevision else {
                throw StoreError.revisionConflict(entity: .projectSettings, id: settings.id.uuidString,
                                                        expected: expectedRevision, actual: settings.revision)
            }
            try SyncBookkeeping.save(db, ProjectSettingsStorage.self, updated, isNew: false, at: date)
            if let projectId: ProjectID = try String.fetchOne(db, sql: "SELECT id FROM projects WHERE settings_id = ?",
                                                              arguments: [settings.id.databaseText])
                .flatMap(ProjectID.init(uuidString:)) {
                try Self.replacePreferences(db, projectId: projectId, with: updated.agentModelPreferencesByProvider, at: date)
            }
            return try ProjectSettingsStorage.fetch(db, syncID: settings.id.rawValue) ?? updated
        }
    }

    public func saveLocation(_ location: RepositoryLocation, at date: Date = .now) async throws {
        try await database.write { db in _ = try SyncBookkeeping.upsert(db, RepositoryLocationStorage.self, location, at: date) }
    }

    public func locations(projectId: ProjectID) async throws -> [RepositoryLocation] {
        try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM repository_locations WHERE project_id = ? ORDER BY host_id",
                             arguments: [projectId.databaseText]).map(RepositoryLocationStorage.decode)
        }
    }

    public func locations(hostId: HostID) async throws -> [RepositoryLocation] {
        try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM repository_locations WHERE host_id = ? ORDER BY canonical_path",
                             arguments: [hostId.databaseText]).map(RepositoryLocationStorage.decode)
        }
    }

    public func deleteLocation(projectId: ProjectID, hostId: HostID, at date: Date = .now) async throws {
        try await database.write { db in
            let id = RepositoryLocationStorage.syncID(projectId: projectId, hostId: hostId)
            try SyncBookkeeping.delete(db, RepositoryLocationStorage.self, syncID: id, at: date)
        }
    }

    public func delete(_ id: ProjectID, expectedRevision: Int, at date: Date = .now) async throws {
        try await database.write { db in
            let project = try Self.fetchForUpdate(db, id, expectedRevision: expectedRevision)
            let itemCount = try Int.fetchOne(db, sql: "SELECT count(*) FROM work_items WHERE project_id = ?",
                                             arguments: [id.databaseText]) ?? 0
            guard itemCount == 0 else { throw StoreError.projectHasWorkItems(id) }
            for location in try Row.fetchAll(db, sql: "SELECT * FROM repository_locations WHERE project_id = ?",
                                             arguments: [id.databaseText]).map(RepositoryLocationStorage.decode) {
                try SyncBookkeeping.delete(db, RepositoryLocationStorage.self, syncID: RepositoryLocationStorage.syncID(of: location), at: date)
            }
            try Self.replacePreferences(db, projectId: id, with: [:], at: date)
            try SyncBookkeeping.delete(db, ProjectStorage.self, syncID: id.rawValue, at: date)
            if try ProjectSettingsStorage.fetch(db, syncID: project.settingsId.rawValue) != nil {
                try SyncBookkeeping.delete(db, ProjectSettingsStorage.self, syncID: project.settingsId.rawValue, at: date)
            }
        }
    }

    // MARK: Helpers

    static func fetchForUpdate(_ db: Database, _ id: ProjectID, expectedRevision: Int) throws -> Project {
        guard let stored = try ProjectStorage.fetch(db, syncID: id.rawValue) else {
            throw StoreError.notFound(entity: .project, id: id.uuidString)
        }
        guard stored.revision == expectedRevision else {
            throw StoreError.revisionConflict(entity: .project, id: id.uuidString, expected: expectedRevision, actual: stored.revision)
        }
        return stored
    }

    /// Writes changed preferences and deletes those no longer present, each with its outbox entry.
    static func replacePreferences(
        _ db: Database, projectId: ProjectID, with preferences: [ProviderID: AgentModelPreference], at date: Date
    ) throws {
        let scope = PreferenceScope.project(projectId)
        let existing = try AgentModelPreferenceStorage.fetchAll(db, scopeKey: AgentModelPreferenceStorage.scopeKey(scope))
        for (providerId, preference) in preferences {
            guard preference.scope == scope, preference.providerId == providerId else {
                throw StoreError.settingsMismatch(projectId: projectId)
            }
            if existing.first(where: { $0.providerId == providerId }) != preference {
                try SyncBookkeeping.upsert(db, AgentModelPreferenceStorage.self, preference, at: date)
            }
        }
        for stale in existing where preferences[stale.providerId] == nil {
            try SyncBookkeeping.delete(db, AgentModelPreferenceStorage.self, syncID: AgentModelPreferenceStorage.syncID(of: stale), at: date)
        }
    }
}
