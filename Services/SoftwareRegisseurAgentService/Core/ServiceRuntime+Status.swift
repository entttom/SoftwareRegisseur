import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC
import SoftwareRegisseurPersistence
import SoftwareRegisseurSync

extension ServiceRuntime {
    static let activeJobStates: Set<AgentJobState> = [.admitted, .starting, .running, .waitingApproval]

    /// Statusübersicht für Menüleiste und Dashboard (D1). Jede Zahl kommt aus der Datenbank bzw. dem
    /// tatsächlichen Zustand dieses Prozesses.
    func statusSummary() async -> ServiceStatusSummary {
        let now = clock.now()
        var problems: [String] = []

        // Agenten
        let capabilities = (try? await database.capabilities.capabilities(hostId: hostId)) ?? []
        let active = (try? await database.jobs.jobs(inStates: Self.activeJobStates, hostId: hostId, limit: nil)) ?? []
        var providerIds = providers.providerIds
        for capability in capabilities where !providerIds.contains(capability.providerId) { providerIds.append(capability.providerId) }
        let agents = providerIds.map { providerId -> AgentProviderSummary in
            let capability = capabilities.first { $0.providerId == providerId }
            let name = providers.provider(for: providerId)?.displayName ?? capability?.displayName ?? providerId.rawValue
            return AgentProviderSummary(
                providerId: providerId, displayName: name, installed: capability?.installed ?? false,
                authenticated: capability?.authenticated ?? false, ready: capability?.isReady ?? false,
                version: capability.map(\.version).flatMap { $0.isEmpty ? nil : $0 }, checkedAt: capability?.lastChecked,
                diagnostic: capability?.diagnostic.map { ServiceLog.redact($0) },
                activeJobs: active.count { $0.providerId == providerId })
        }

        // Warteschlange
        var queue = QueueSummary()
        let waiting = (try? await database.jobs.jobs(inStates: [.requested, .pendingMac], hostId: nil, limit: nil)) ?? []
        queue.waiting = waiting.count { $0.hostId == nil || $0.hostId == hostId }
        let scheduled = (try? await database.jobs.jobs(inStates: [.scheduled, .waitingQuota], hostId: hostId, limit: nil)) ?? []
        queue.scheduled = scheduled.count
        queue.waitingQuota = scheduled.count { $0.state == .waitingQuota }
        queue.nextPlannedStart = scheduled.compactMap(\.scheduledAt).min()
        queue.waitingApproval = active.count { $0.state == .waitingApproval }
        queue.paused = ((try? await database.jobs.jobs(inStates: [.paused], hostId: hostId, limit: nil)) ?? []).count
        queue.openApprovals = ((try? await database.approvals.openApprovals(hostId: hostId)) ?? []).count
        queue.blocked = await count(statuses: [.blocked])
        queue.failed = await count(statuses: [.failed])
        queue.reviewsPending = await count(statuses: [.review])
        if let orchestrator {
            for job in scheduled {
                if let block = await orchestrator.admissionBlock(for: job.jobId) { queue.admissionBlocks[job.jobId] = block.germanDescription }
            }
        }

        // Projekte und Arbeitsbereich
        var workspace = WorkspaceSummary(rootFolders: rootFolders.map(\.path))
        let projects = (try? await database.projects.list()) ?? []
        let local = projects.filter { $0.hostId == hostId || $0.hostId == nil }
        workspace.projectsReady = local.count { $0.status == .ready }
        workspace.projectsUnavailable = local.count { $0.status == .unavailable }
        workspace.projectsNeedingAttention = local.count { $0.status == .needsAttention }
        workspace.projectsPendingSetup = local.count { $0.status == .pendingMacSetup }
        workspace.lastScanAt = lastScan?.finishedAt
        workspace.lastScanError = lastScanError
        workspace.isScanning = scanTask != nil
        workspace.openFileConflicts = ((try? await database.fileConflicts.open(projectId: nil)) ?? []).count
        workspace.pendingInstructionProposals = proposals.count
        workspace.pendingAIElaborations = pendingAIElaborations
        workspace.gitHubAvailable = gitHubAvailability?.isAvailable

        // Sync
        let sync = syncSummary()

        if rootFolders.isEmpty {
            problems.append("Noch kein Git-Stammordner bestätigt – der Scanner ist inaktiv.")
        }
        if orchestrator == nil {
            problems.append("Git wurde nicht gefunden – Agentenaufträge können nicht starten.")
        }
        if !agents.contains(where: \.ready) {
            problems.append("Kein einsatzbereiter Coding-Agent erkannt.")
        }
        if workspace.projectsUnavailable > 0 {
            problems.append("\(workspace.projectsUnavailable) Projekt(e) nicht erreichbar – Ordner neu verknüpfen.")
        }
        problems += sync.attention

        let macState: ServiceStatusSummary.MacState
        if !isBootstrapped {
            macState = .starting
        } else if runState == .paused {
            macState = .paused
        } else if orchestrator == nil || rootFolders.isEmpty || !agents.contains(where: \.ready) {
            macState = .degraded
        } else {
            macState = .ready
        }

        return ServiceStatusSummary(
            generatedAt: now, serviceVersion: deps.version, runState: runState, macState: macState, hostId: hostId,
            hostName: deps.hostName, startedAt: startedAt, sync: sync, agents: agents, queue: queue, workspace: workspace,
            problems: problems)
    }

    private func count(statuses: Set<WorkItemStatus>) async -> Int {
        ((try? await database.workItems.list(WorkItemFilter(statuses: statuses, archive: .activeOnly))) ?? []).count
    }

    func syncSummary() -> SyncSummary {
        guard coordinator != nil else {
            return SyncSummary(state: .unavailable, unavailableReason: syncUnavailableReason ?? "Sync-Koordinator nicht gestartet.")
        }
        guard let status = syncStatus else { return SyncSummary(state: .idle) }
        let account: SyncSummary.AccountState = switch status.accountState {
        case .unknown: .unknown
        case .available: .available
        case .signedOut: .signedOut
        case .switched: .switched
        case .temporarilyUnavailable: .temporarilyUnavailable
        }
        let state: SyncSummary.State
        if status.isSyncing {
            state = .syncing
        } else if status.isPaused {
            state = .paused
        } else if case .failed = lastSyncResult {
            state = .failed
        } else {
            state = .idle
        }
        return SyncSummary(
            state: state, accountState: account, lastSuccessfulFetch: status.lastSuccessfulFetch,
            lastSuccessfulSend: status.lastSuccessfulSend, pendingChanges: status.pendingCount,
            openConflicts: status.openConflictCount, lastError: status.lastError.map { ServiceLog.redact($0) },
            attention: status.attention.map(\.message), retryNotBefore: status.retryNotBefore,
            cloudDataDeletion: status.attention.contains(.cloudDataDeletionPending) ? .pending
                : status.attention.contains(.cloudDataDeletedByUser) ? .deleted : nil)
    }

    func health() -> ServiceHealth {
        ServiceHealth(serviceVersion: deps.version, processIdentifier: ProcessInfo.processInfo.processIdentifier,
                      startedAt: startedAt, uptimeSeconds: max(0, clock.now().timeIntervalSince(startedAt)), runState: runState)
    }
}
