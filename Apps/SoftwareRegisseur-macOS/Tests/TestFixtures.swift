import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC

enum Fixture {
    static let now = Date(timeIntervalSince1970: 1_793_000_000)
    static let hostId = HostID(UUID(uuidString: "11111111-2222-4333-8444-555555555555")!)
    static let projectA = ProjectID(UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!)
    static let projectB = ProjectID(UUID(uuidString: "BBBBBBBB-0000-4000-8000-000000000002")!)

    static func item(
        _ title: String, project: ProjectID? = projectA, type: WorkItemType = .feature, status: WorkItemStatus = .open,
        priority: Priority = .medium, labels: [String] = [], body: String = "", number: Int? = nil,
        created: TimeInterval = 0, archived: Bool = false
    ) -> WorkItem {
        var item = WorkItem(
            humanId: number.flatMap { try? HumanID(type: type, number: $0) }, projectId: project, type: type, title: title,
            originalNote: title, structuredBody: body, status: status, priority: priority, labels: labels,
            createdAt: now.addingTimeInterval(created)
        )
        if archived { item.archive(at: now.addingTimeInterval(created + 1)) }
        return item
    }

    static func snapshot(provider: ProviderID = .codex, model: ModelSelection = .providerDefault, effort: EffortLevel = .auto) -> ConfigurationSnapshot {
        ConfigurationSnapshot(providerId: provider, requestedModel: nil, requestedEffort: nil, resolvedModel: model, resolvedEffort: effort,
                              profileSource: ProfileSources(model: .providerDefault, effort: .providerDefault), capabilityRevision: 1,
                              agentVersion: "1.0", createdAt: now)
    }

    /// Job im gewünschten Zustand (über die erlaubten Übergänge der Zustandsmaschine).
    static func job(
        for item: WorkItem, state: AgentJobState, priority: Priority = .medium, schedule: JobSchedule = JobSchedule(kind: .immediate),
        created: TimeInterval = 0, provider: ProviderID = .codex
    ) -> AgentJob {
        var job = AgentJob(idempotencyKey: IdempotencyKey(), projectId: item.projectId ?? projectA, workItemId: item.uuid, hostId: hostId,
                           configSnapshot: snapshot(provider: provider), schedule: schedule, priority: priority,
                           workItemStatusBeforeJob: item.status, createdAt: now.addingTimeInterval(created))
        let path: [AgentJobState] = switch state {
        case .requested: []
        case .pendingMac: [.pendingMac]
        case .scheduled: [.scheduled]
        case .admitted: [.admitted]
        case .starting: [.admitted, .starting]
        case .running: [.admitted, .starting, .running]
        case .finished: [.admitted, .starting, .running, .finished]
        case .needsConfiguration: [.needsConfiguration]
        case .waitingApproval: [.admitted, .starting, .running, .waitingApproval]
        case .waitingQuota: [.scheduled, .waitingQuota]
        case .paused: [.scheduled, .paused]
        case .failed: [.failed]
        case .cancelled: [.cancelled]
        }
        for step in path { try? job.transition(to: step, at: now) }
        return job
    }

    static func capability(
        provider: ProviderID = .codex, effortAdjustable: Bool = true, ready: Bool = true
    ) -> AgentCapability {
        AgentCapability(
            providerId: provider, displayName: "Codex", hostId: hostId, version: "1.0", authenticated: ready,
            supportsModelSelection: true, supportsEffortSelection: effortAdjustable,
            modelCatalog: [
                AgentModelCapability(providerId: provider, modelId: "modell-a", displayName: "Modell A",
                                     supportedEffortIds: [.low, .medium, .high], source: .documentedCLI, lastValidatedAt: now),
                AgentModelCapability(providerId: provider, modelId: "modell-alt", displayName: "Alt", supportedEffortIds: [.low],
                                     availability: .deprecated, source: .documentedCLI, lastValidatedAt: now),
            ],
            defaultModelId: "modell-a", capabilitySource: .documentedCLI, capabilityRevision: 2, lastChecked: now
        )
    }

    static func project(_ id: ProjectID, name: String) -> ProjectEntry {
        let settings = GlobalSettings.defaults.makeProjectSettings(updatedAt: now)
        let project = Project(id: id, name: name, repositoryKind: .gitRepository, hostId: hostId, status: .ready,
                              settingsId: settings.id, createdAt: now)
        return ProjectEntry(project: project, settings: settings,
                            locations: [RepositoryLocation(projectId: id, hostId: hostId, canonicalPath: "/tmp/\(name)")],
                            adrs: [], activeLocks: [], setupCommands: [])
    }

    static func library(items: [WorkItem], jobs: [AgentJob] = [], capabilities: [AgentCapability] = [capability()]) -> LibrarySnapshot {
        var snapshot = LibrarySnapshot.empty
        snapshot.projects = [project(projectA, name: "Alpha"), project(projectB, name: "Beta")]
        snapshot.workItems = items
        snapshot.jobs = jobs
        snapshot.capabilities = capabilities
        return snapshot
    }
}
