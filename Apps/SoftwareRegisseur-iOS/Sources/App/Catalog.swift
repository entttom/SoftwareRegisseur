import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

/// Synced data loaded for the views. Read with one call per repository; the database is local, so this
/// works offline (spec B: iPhone independent of the Mac).
struct Catalog: Sendable {
    var projects: [Project] = []
    var items: [WorkItem] = []
    var jobs: [AgentJob] = []
    var hosts: [AgentHost] = []
    var capabilities: [AgentCapability] = []

    func project(_ id: ProjectID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    func item(_ id: WorkItemID) -> WorkItem? { items.first { $0.uuid == id } }

    func host(_ id: HostID?) -> AgentHost? {
        guard let id else { return nil }
        return hosts.first { $0.hostId == id }
    }

    func projectName(_ id: ProjectID?) -> String? { project(id)?.name }
}

extension AppModel {
    func loadCatalog(includeAgents: Bool = true) async throws -> Catalog {
        guard let database else { return Catalog() }
        var catalog = Catalog()
        catalog.projects = try await database.projects.list()
        catalog.items = try await database.workItems.list(WorkItemFilter())
        catalog.jobs = try await database.jobs.jobs(inStates: Set(AgentJobState.allCases), hostId: nil, limit: nil)
        if includeAgents {
            catalog.hosts = try await database.capabilities.hosts()
            for host in catalog.hosts {
                catalog.capabilities += try await database.capabilities.capabilities(hostId: host.hostId)
            }
        }
        return catalog
    }
}
