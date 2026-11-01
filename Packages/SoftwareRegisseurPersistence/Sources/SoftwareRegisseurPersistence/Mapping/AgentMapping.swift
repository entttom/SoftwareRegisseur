import Foundation
import GRDB
import SoftwareRegisseurDomain

enum AgentHostStorage: EntityStorage {
    typealias Entity = AgentHost
    static let entityType = SyncEntityType.agentHost

    static func syncID(of entity: AgentHost) -> UUID { entity.hostId.rawValue }

    static func fetch(_ db: Database, syncID: UUID) throws -> AgentHost? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM agent_hosts WHERE host_id = ?", arguments: [syncID.uuidString]) else {
            return nil
        }
        let hostId: HostID = try row.id("host_id")
        return AgentHost(
            hostId: hostId,
            name: try row.string("name"),
            lastSeen: try row.date("last_seen"),
            ready: try row.bool("ready"),
            agentCapabilities: try AgentCapabilityStorage.fetchAll(db, hostId: hostId),
            serviceVersion: try row.string("service_version")
        )
    }

    /// Host row only; capabilities are written through `AgentCapabilityStorage`.
    static func save(_ db: Database, _ h: AgentHost) throws {
        try db.upsert(into: "agent_hosts", [
            "host_id": h.hostId.databaseText,
            "name": h.name,
            "last_seen": StoredDate.value(h.lastSeen),
            "ready": h.ready,
            "service_version": h.serviceVersion,
        ], conflictKeys: ["host_id"])
    }

    static func delete(_ db: Database, syncID: UUID) throws {
        try db.execute(sql: "DELETE FROM agent_hosts WHERE host_id = ?", arguments: [syncID.uuidString])
    }

    static func syncPayload(_ h: AgentHost) -> AgentHost {
        AgentHost(hostId: h.hostId, name: h.name, lastSeen: h.lastSeen, ready: h.ready, agentCapabilities: [], serviceVersion: h.serviceVersion)
    }
}

enum AgentCapabilityStorage: EntityStorage {
    typealias Entity = AgentCapability
    static let entityType = SyncEntityType.agentCapability

    static func syncID(of entity: AgentCapability) -> UUID {
        syncID(hostId: entity.hostId, providerId: entity.providerId)
    }

    static func syncID(hostId: HostID, providerId: ProviderID) -> UUID {
        DeterministicUUID.make([entityType.rawValue, hostId.databaseText, providerId.rawValue])
    }

    static func decode(_ db: Database, _ row: Row) throws -> AgentCapability {
        let hostId: String = try row.string("host_id")
        let providerId: String = try row.string("provider_id")
        let models = try Row.fetchAll(db, sql: """
            SELECT * FROM agent_model_capabilities WHERE host_id = ? AND provider_id = ? ORDER BY position
            """, arguments: [hostId, providerId]).map(decodeModel)
        return AgentCapability(
            providerId: try row.open("provider_id"),
            displayName: try row.string("display_name"),
            hostId: try row.id("host_id"),
            executablePath: row["executable_path"],
            appBundleId: row["app_bundle_id"],
            version: try row.string("version"),
            installed: try row.bool("installed"),
            authenticated: try row.bool("authenticated"),
            runnable: try row.bool("runnable"),
            supportsRemote: try row.bool("supports_remote"),
            supportsAutomaticStart: try row.bool("supports_automatic_start"),
            supportsResume: try row.bool("supports_resume"),
            supportsApprovals: try row.bool("supports_approvals"),
            supportsModelSelection: try row.bool("supports_model_selection"),
            supportsEffortSelection: try row.bool("supports_effort_selection"),
            modelCatalog: models,
            defaultModelId: try row.optionalOpen("default_model_id"),
            capabilitySource: try row.enumValue("capability_source"),
            capabilityRevision: try row.int("capability_revision"),
            lastChecked: try row.date("last_checked"),
            detectionTimestamp: try row.date("detection_timestamp"),
            sessionLinkFormat: row["session_link_format"],
            diagnostic: row["diagnostic"]
        )
    }

    static func decodeModel(_ row: Row) throws -> AgentModelCapability {
        AgentModelCapability(
            providerId: try row.open("model_provider_id"),
            modelId: try row.open("model_id"),
            displayName: try row.string("display_name"),
            supportedEffortIds: try row.json("supported_effort_ids"),
            defaultEffortId: try row.optionalOpen("default_effort_id"),
            availability: try row.enumValue("availability"),
            source: try row.enumValue("source"),
            lastValidatedAt: try row.date("last_validated_at")
        )
    }

    static func fetch(_ db: Database, syncID: UUID) throws -> AgentCapability? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM agent_capabilities WHERE sync_id = ?", arguments: [syncID.uuidString]) else {
            return nil
        }
        return try decode(db, row)
    }

    static func fetchAll(_ db: Database, hostId: HostID) throws -> [AgentCapability] {
        try Row.fetchAll(db, sql: "SELECT * FROM agent_capabilities WHERE host_id = ? ORDER BY provider_id", arguments: [hostId.databaseText])
            .map { try decode(db, $0) }
    }

    /// Replaces the model catalog rows together with the capability row.
    static func save(_ db: Database, _ c: AgentCapability) throws {
        try db.upsert(into: "agent_capabilities", [
            "host_id": c.hostId.databaseText,
            "provider_id": c.providerId.rawValue,
            "sync_id": syncID(of: c).uuidString,
            "display_name": c.displayName,
            "executable_path": c.executablePath,
            "app_bundle_id": c.appBundleId,
            "version": c.version,
            "installed": c.installed,
            "authenticated": c.authenticated,
            "runnable": c.runnable,
            "supports_remote": c.supportsRemote,
            "supports_automatic_start": c.supportsAutomaticStart,
            "supports_resume": c.supportsResume,
            "supports_approvals": c.supportsApprovals,
            "supports_model_selection": c.supportsModelSelection,
            "supports_effort_selection": c.supportsEffortSelection,
            "default_model_id": c.defaultModelId?.rawValue,
            "capability_source": c.capabilitySource.rawValue,
            "capability_revision": c.capabilityRevision,
            "last_checked": StoredDate.value(c.lastChecked),
            "detection_timestamp": StoredDate.value(c.detectionTimestamp),
            "session_link_format": c.sessionLinkFormat,
            "diagnostic": c.diagnostic,
        ], conflictKeys: ["host_id", "provider_id"])
        try db.execute(
            sql: "DELETE FROM agent_model_capabilities WHERE host_id = ? AND provider_id = ?",
            arguments: [c.hostId.databaseText, c.providerId.rawValue]
        )
        for (position, model) in c.modelCatalog.enumerated() {
            try db.insert(into: "agent_model_capabilities", [
                "host_id": c.hostId.databaseText,
                "provider_id": c.providerId.rawValue,
                "position": position,
                "model_provider_id": model.providerId.rawValue,
                "model_id": model.modelId.rawValue,
                "display_name": model.displayName,
                "supported_effort_ids": try JSONColumn.encode(model.supportedEffortIds),
                "default_effort_id": model.defaultEffortId?.rawValue,
                "availability": model.availability.rawValue,
                "source": model.source.rawValue,
                "last_validated_at": StoredDate.value(model.lastValidatedAt),
            ])
        }
    }

    static func delete(_ db: Database, syncID: UUID) throws {
        try db.execute(sql: "DELETE FROM agent_capabilities WHERE sync_id = ?", arguments: [syncID.uuidString])
    }
}

enum AgentModelPreferenceStorage: EntityStorage {
    typealias Entity = AgentModelPreference
    static let entityType = SyncEntityType.agentModelPreference
    static let globalScopeKey = "global"

    static func scopeKey(_ scope: PreferenceScope) -> String {
        switch scope {
        case .global: globalScopeKey
        case let .project(id): id.databaseText
        }
    }

    static func syncID(of entity: AgentModelPreference) -> UUID {
        syncID(scope: entity.scope, providerId: entity.providerId)
    }

    static func syncID(scope: PreferenceScope, providerId: ProviderID) -> UUID {
        DeterministicUUID.make([entityType.rawValue, scopeKey(scope), providerId.rawValue])
    }

    static func decode(_ row: Row) throws -> AgentModelPreference {
        let scope: PreferenceScope =
            if let projectId: ProjectID = try row.optionalID("project_id") { .project(projectId) } else { .global }
        let model: ModelSelection? =
            switch row["model_selection"] as String? {
            case nil: nil
            case "providerDefault": .providerDefault
            case "model": .model(try row.open("model_id"))
            case let other?: throw StoreError.corruptValue(column: "model_selection", detail: other)
            }
        return AgentModelPreference(
            scope: scope,
            providerId: try row.open("provider_id"),
            model: model,
            effort: try row.optionalOpen("effort"),
            inheritsDefault: try row.bool("inherits_default"),
            updatedAt: try row.date("updated_at")
        )
    }

    static func fetch(_ db: Database, syncID: UUID) throws -> AgentModelPreference? {
        try Row.fetchOne(db, sql: "SELECT * FROM agent_model_preferences WHERE sync_id = ?", arguments: [syncID.uuidString]).map(decode)
    }

    static func fetchAll(_ db: Database, scopeKey: String) throws -> [AgentModelPreference] {
        try Row.fetchAll(db, sql: "SELECT * FROM agent_model_preferences WHERE scope_key = ? ORDER BY provider_id", arguments: [scopeKey])
            .map(decode)
    }

    static func save(_ db: Database, _ p: AgentModelPreference) throws {
        let projectId: String? =
            if case let .project(id) = p.scope { id.databaseText } else { nil }
        let selection: String? =
            switch p.model {
            case nil: nil
            case .providerDefault?: "providerDefault"
            case .model?: "model"
            }
        try db.upsert(into: "agent_model_preferences", [
            "scope_key": scopeKey(p.scope),
            "provider_id": p.providerId.rawValue,
            "sync_id": syncID(of: p).uuidString,
            "project_id": projectId,
            "model_selection": selection,
            "model_id": p.model?.modelID?.rawValue,
            "effort": p.effort?.rawValue,
            "inherits_default": p.inheritsDefault,
            "updated_at": StoredDate.value(p.updatedAt),
        ], conflictKeys: ["scope_key", "provider_id"])
    }

    static func delete(_ db: Database, syncID: UUID) throws {
        try db.execute(sql: "DELETE FROM agent_model_preferences WHERE sync_id = ?", arguments: [syncID.uuidString])
    }
}

enum AgentJobStorage: EntityStorage {
    typealias Entity = AgentJob
    static let entityType = SyncEntityType.agentJob
    static let terminalStatesSQL = "('finished', 'failed', 'cancelled')"

    static func syncID(of entity: AgentJob) -> UUID { entity.jobId.rawValue }

    static func decode(_ row: Row) throws -> AgentJob {
        let snapshot: ConfigurationSnapshot = try row.json("config_snapshot")
        let schedule: JobSchedule = try row.json("schedule")
        let fields: [String: (any Encodable)?] = [
            "jobId": try row.uuid("job_id"),
            "idempotencyKey": try row.uuid("idempotency_key"),
            "projectId": try row.uuid("project_id"),
            "workItemId": try row.uuid("work_item_id"),
            "hostId": try row.optionalUUID("host_id"),
            "providerId": try row.string("provider_id"),
            "configSnapshot": snapshot,
            "effectiveModelId": row["effective_model_id"] as String?,
            "effectiveEffort": row["effective_effort"] as String?,
            "effectiveConfirmedAt": row.optionalDate("effective_confirmed_at"),
            "schedule": schedule,
            "priority": try row.string("priority"),
            "state": try row.string("state"),
            "workItemStatusBeforeJob": try row.string("work_item_status_before_job"),
            "retryCount": try row.int("retry_count"),
            "sessionId": row["session_id"] as String?,
            "branch": row["branch"] as String?,
            "worktreePath": row["worktree_path"] as String?,
            "startedAt": row.optionalDate("started_at"),
            "finishedAt": row.optionalDate("finished_at"),
            "lastError": row["last_error"] as String?,
            "retryOfJobId": row.hasColumn("retry_of_job_id") ? try row.optionalUUID("retry_of_job_id") : nil,
            "revision": try row.int("revision"),
            "createdAt": try row.date("created_at"),
            "updatedAt": try row.date("updated_at"),
        ]
        do {
            return try DomainBridge.make(AgentJob.self, fields)
        } catch {
            throw StoreError.corruptValue(column: "agent_jobs", detail: "\(error)")
        }
    }

    static func fetch(_ db: Database, syncID: UUID) throws -> AgentJob? {
        try Row.fetchOne(db, sql: "SELECT * FROM agent_jobs WHERE job_id = ?", arguments: [syncID.uuidString]).map(decode)
    }

    static func save(_ db: Database, _ j: AgentJob) throws {
        try db.upsert(into: "agent_jobs", [
            "job_id": j.jobId.databaseText,
            "idempotency_key": j.idempotencyKey.databaseText,
            "project_id": j.projectId.databaseText,
            "work_item_id": j.workItemId.databaseText,
            "host_id": j.hostId?.databaseText,
            "provider_id": j.providerId.rawValue,
            "config_snapshot": try JSONColumn.encode(j.configSnapshot),
            "requested_model_id": j.requestedModelId?.rawValue,
            "requested_effort": j.requestedEffort?.rawValue,
            "resolved_model_id": j.resolvedModelId?.rawValue,
            "resolved_effort": j.resolvedEffort.rawValue,
            "capability_revision": j.capabilityRevision,
            "effective_model_id": j.effectiveModelId?.rawValue,
            "effective_effort": j.effectiveEffort?.rawValue,
            "effective_confirmed_at": StoredDate.value(j.effectiveConfirmedAt),
            "schedule": try JSONColumn.encode(j.schedule),
            "scheduled_at": StoredDate.value(j.scheduledAt),
            "priority": j.priority.rawValue,
            "priority_rank": j.priority.storedRank,
            "state": j.state.rawValue,
            "work_item_status_before_job": j.workItemStatusBeforeJob.rawValue,
            "retry_count": j.retryCount,
            "session_id": j.sessionId,
            "branch": j.branch,
            "worktree_path": j.worktreePath,
            "started_at": StoredDate.value(j.startedAt),
            "finished_at": StoredDate.value(j.finishedAt),
            "last_error": j.lastError,
            "revision": j.revision,
            "created_at": StoredDate.value(j.createdAt),
            "updated_at": StoredDate.value(j.updatedAt),
        ], conflictKeys: ["job_id"])
        // v4 column (see `WorkItemStorage.save`).
        if try db.hasColumn("retry_of_job_id", in: "agent_jobs") {
            try db.execute(sql: "UPDATE agent_jobs SET retry_of_job_id = ? WHERE job_id = ?",
                           arguments: [j.retryOfJobId?.databaseText, j.jobId.databaseText])
        }
    }

    static func delete(_ db: Database, syncID: UUID) throws {
        try db.execute(sql: "DELETE FROM agent_jobs WHERE job_id = ?", arguments: [syncID.uuidString])
    }
}

enum TaskLockStorage: EntityStorage {
    typealias Entity = TaskLock
    static let entityType = SyncEntityType.taskLock

    static func syncID(of entity: TaskLock) -> UUID { entity.lockId.rawValue }

    static func decode(_ row: Row) throws -> TaskLock {
        let fields: [String: (any Encodable)?] = [
            "lockId": try row.uuid("lock_id"),
            "taskId": try row.uuid("task_id"),
            "projectId": try row.uuid("project_id"),
            "jobId": try row.uuid("job_id"),
            "hostId": try row.uuid("host_id"),
            "owner": try row.string("owner"),
            "scope": try row.string("scope"),
            "acquiredAt": try row.date("acquired_at"),
            "lastHeartbeat": try row.date("last_heartbeat"),
            "leaseUntil": try row.date("lease_until"),
            "recoveryState": try row.string("recovery_state"),
            "releasedAt": row.optionalDate("released_at"),
            "releaseReason": row["release_reason"] as String?,
        ]
        do {
            return try DomainBridge.make(TaskLock.self, fields)
        } catch {
            throw StoreError.corruptValue(column: "task_locks", detail: "\(error)")
        }
    }

    static func fetch(_ db: Database, syncID: UUID) throws -> TaskLock? {
        try Row.fetchOne(db, sql: "SELECT * FROM task_locks WHERE lock_id = ?", arguments: [syncID.uuidString]).map(decode)
    }

    static func save(_ db: Database, _ l: TaskLock) throws {
        try db.upsert(into: "task_locks", [
            "lock_id": l.lockId.databaseText,
            "task_id": l.taskId.databaseText,
            "project_id": l.projectId.databaseText,
            "job_id": l.jobId.databaseText,
            "host_id": l.hostId.databaseText,
            "owner": l.owner,
            "scope": l.scope.rawValue,
            "acquired_at": StoredDate.value(l.acquiredAt),
            "last_heartbeat": StoredDate.value(l.lastHeartbeat),
            "lease_until": StoredDate.value(l.leaseUntil),
            "recovery_state": l.recoveryState.rawValue,
            "released_at": StoredDate.value(l.releasedAt),
            "release_reason": l.releaseReason?.rawValue,
        ], conflictKeys: ["lock_id"])
    }

    static func delete(_ db: Database, syncID: UUID) throws {
        try db.execute(sql: "DELETE FROM task_locks WHERE lock_id = ?", arguments: [syncID.uuidString])
    }
}
