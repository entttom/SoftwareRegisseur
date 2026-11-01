import Foundation
import GRDB
import SoftwareRegisseurDomain

enum ProjectStorage: EntityStorage {
    typealias Entity = Project
    static let entityType = SyncEntityType.project

    static func syncID(of entity: Project) -> UUID { entity.id.rawValue }

    static func decode(_ row: Row) throws -> Project {
        Project(
            id: try row.id("id"),
            name: try row.string("name"),
            repositoryIdentity: try row.optionalOpen("repository_identity"),
            repositoryKind: try row.enumValue("repository_kind"),
            remote: row["remote"],
            hostId: try row.optionalID("host_id"),
            status: try row.enumValue("status"),
            settingsId: try row.id("settings_id"),
            revision: try row.int("revision"),
            createdAt: try row.date("created_at"),
            updatedAt: try row.date("updated_at"),
            // v3 column; absent (nil) on databases migrated only to v1/v2.
            statusReason: row.hasColumn("status_reason") ? row["status_reason"] : nil
        )
    }

    static func fetch(_ db: Database, syncID: UUID) throws -> Project? {
        try Row.fetchOne(db, sql: "SELECT * FROM projects WHERE id = ?", arguments: [syncID.uuidString]).map(decode)
    }

    static func save(_ db: Database, _ p: Project) throws {
        try db.upsert(into: "projects", [
            "id": p.id.databaseText,
            "name": p.name,
            "repository_identity": p.repositoryIdentity?.rawValue,
            "repository_kind": p.repositoryKind.rawValue,
            "remote": p.remote,
            "host_id": p.hostId?.databaseText,
            "status": p.status.rawValue,
            "settings_id": p.settingsId.databaseText,
            "revision": p.revision,
            "created_at": StoredDate.value(p.createdAt),
            "updated_at": StoredDate.value(p.updatedAt),
        ], conflictKeys: ["id"])
        // `status_reason` exists from v3 on; writes keep working on older schema versions (migration tests).
        if try db.columns(in: "projects").contains(where: { $0.name == "status_reason" }) {
            try db.execute(sql: "UPDATE projects SET status_reason = ? WHERE id = ?", arguments: [p.statusReason, p.id.databaseText])
        }
    }

    static func delete(_ db: Database, syncID: UUID) throws {
        try db.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [syncID.uuidString])
    }
}

/// Project-scoped model preferences live in `agent_model_preferences` (single source of truth) and
/// are assembled into `ProjectSettings.agentModelPreferencesByProvider` on read.
enum ProjectSettingsStorage: EntityStorage {
    typealias Entity = ProjectSettings
    static let entityType = SyncEntityType.projectSettings

    static func syncID(of entity: ProjectSettings) -> UUID { entity.id.rawValue }

    static func decode(_ row: Row, preferences: [ProviderID: AgentModelPreference]) throws -> ProjectSettings {
        ProjectSettings(
            id: try row.id("id"),
            adrPath: try row.string("adr_path"),
            requestsRoot: try row.string("requests_root"),
            openPath: try row.string("open_path"),
            activePath: try row.string("active_path"),
            reviewPath: try row.string("review_path"),
            donePath: try row.string("done_path"),
            defaultAgentId: try row.optionalOpen("default_agent_id"),
            agentModelPreferencesByProvider: preferences,
            allowParallel: try row.bool("allow_parallel"),
            projectWideLock: try row.bool("project_wide_lock"),
            maxParallelJobs: row.optionalInt("max_parallel_jobs"),
            reviewPolicy: try row.enumValue("review_policy"),
            integrationStrategy: try row.enumValue("integration_strategy"),
            agentInstructionsPolicy: try row.enumValue("agent_instructions_policy"),
            revision: try row.int("revision"),
            updatedAt: try row.date("updated_at")
        )
    }

    static func fetch(_ db: Database, syncID: UUID) throws -> ProjectSettings? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM project_settings WHERE id = ?", arguments: [syncID.uuidString]) else {
            return nil
        }
        let projectId = try String.fetchOne(db, sql: "SELECT id FROM projects WHERE settings_id = ?", arguments: [syncID.uuidString])
        var preferences: [ProviderID: AgentModelPreference] = [:]
        if let projectId {
            for preference in try AgentModelPreferenceStorage.fetchAll(db, scopeKey: projectId) {
                preferences[preference.providerId] = preference
            }
        }
        return try decode(row, preferences: preferences)
    }

    /// Writes the settings row only; see `ProjectRepository.saveSettings` for preferences.
    static func save(_ db: Database, _ s: ProjectSettings) throws {
        try db.upsert(into: "project_settings", [
            "id": s.id.databaseText,
            "adr_path": s.adrPath,
            "requests_root": s.requestsRoot,
            "open_path": s.openPath,
            "active_path": s.activePath,
            "review_path": s.reviewPath,
            "done_path": s.donePath,
            "default_agent_id": s.defaultAgentId?.rawValue,
            "allow_parallel": s.allowParallel,
            "project_wide_lock": s.projectWideLock,
            "max_parallel_jobs": s.maxParallelJobs,
            "review_policy": s.reviewPolicy.rawValue,
            "integration_strategy": s.integrationStrategy.rawValue,
            "agent_instructions_policy": s.agentInstructionsPolicy.rawValue,
            "revision": s.revision,
            "updated_at": StoredDate.value(s.updatedAt),
        ], conflictKeys: ["id"])
    }

    static func delete(_ db: Database, syncID: UUID) throws {
        try db.execute(sql: "DELETE FROM project_settings WHERE id = ?", arguments: [syncID.uuidString])
    }

    /// Preferences sync as `agentModelPreference` entities, not inside the settings record.
    static func syncPayload(_ s: ProjectSettings) -> ProjectSettings {
        ProjectSettings(
            id: s.id, adrPath: s.adrPath, requestsRoot: s.requestsRoot, openPath: s.openPath,
            activePath: s.activePath, reviewPath: s.reviewPath, donePath: s.donePath,
            defaultAgentId: s.defaultAgentId, agentModelPreferencesByProvider: [:],
            allowParallel: s.allowParallel, projectWideLock: s.projectWideLock, maxParallelJobs: s.maxParallelJobs,
            reviewPolicy: s.reviewPolicy, integrationStrategy: s.integrationStrategy,
            agentInstructionsPolicy: s.agentInstructionsPolicy, revision: s.revision, updatedAt: s.updatedAt
        )
    }
}

enum RepositoryLocationStorage: EntityStorage {
    typealias Entity = RepositoryLocation
    static let entityType = SyncEntityType.repositoryLocation

    static func syncID(of entity: RepositoryLocation) -> UUID {
        syncID(projectId: entity.projectId, hostId: entity.hostId)
    }

    static func syncID(projectId: ProjectID, hostId: HostID) -> UUID {
        DeterministicUUID.make([entityType.rawValue, projectId.databaseText, hostId.databaseText])
    }

    static func decode(_ row: Row) throws -> RepositoryLocation {
        RepositoryLocation(
            projectId: try row.id("project_id"),
            hostId: try row.id("host_id"),
            canonicalPath: try row.string("canonical_path"),
            bookmarkReference: row["bookmark_reference"],
            scanState: try row.enumValue("scan_state"),
            lastScanAt: row.optionalDate("last_scan_at")
        )
    }

    static func fetch(_ db: Database, syncID: UUID) throws -> RepositoryLocation? {
        try Row.fetchOne(db, sql: "SELECT * FROM repository_locations WHERE sync_id = ?", arguments: [syncID.uuidString]).map(decode)
    }

    static func save(_ db: Database, _ l: RepositoryLocation) throws {
        try db.upsert(into: "repository_locations", [
            "project_id": l.projectId.databaseText,
            "host_id": l.hostId.databaseText,
            "sync_id": syncID(of: l).uuidString,
            "canonical_path": l.canonicalPath,
            "bookmark_reference": l.bookmarkReference,
            "scan_state": l.scanState.rawValue,
            "last_scan_at": StoredDate.value(l.lastScanAt),
        ], conflictKeys: ["project_id", "host_id"])
    }

    static func delete(_ db: Database, syncID: UUID) throws {
        try db.execute(sql: "DELETE FROM repository_locations WHERE sync_id = ?", arguments: [syncID.uuidString])
    }
}
