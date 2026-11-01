import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

/// Result of reconciling one project (requests + ADRs).
public struct ProjectReconciliation: Sendable, Hashable {
    public let projectId: ProjectID
    public let requests: RequestSyncReport
    public let adrs: ADRImportReport?
    public let error: String?
}

/// Keeps repositories and database in step on the Mac host (spec E3 "Änderungen von außen … erkannt",
/// U4): FSEvents trigger a debounced reconciliation of the affected project; a periodic full pass covers
/// dropped events, sleep/wake and changes made while the service was not running.
public actor RepositorySyncService {
    let environment: WorkspaceEnvironment
    public let materializer: RequestMaterializer
    let adrImporter: ADRImporter
    private var watcher: RepositoryWatcher?
    private var tasks: [Task<Void, Never>] = []
    private var roots: [(projectId: ProjectID, path: String)] = []
    private var pending: Set<ProjectID> = []
    private var flushScheduled = false
    private let reportContinuation: AsyncStream<ProjectReconciliation>.Continuation
    /// Every completed reconciliation (UI, tests).
    public nonisolated let reconciliations: AsyncStream<ProjectReconciliation>

    public init(environment: WorkspaceEnvironment, materializer: RequestMaterializer? = nil) {
        self.environment = environment
        self.materializer = materializer ?? RequestMaterializer(environment: environment)
        adrImporter = ADRImporter(environment: environment)
        (reconciliations, reportContinuation) = AsyncStream<ProjectReconciliation>.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    /// Projects with an existing folder on this host.
    public func watchedProjects() async throws -> [(ProjectID, URL)] {
        var result: [(ProjectID, URL)] = []
        for location in try await environment.database.projects.locations(hostId: environment.hostId) {
            guard let project = try await environment.database.projects.fetch(location.projectId),
                  project.status != .archived else { continue }
            let url = URL(filePath: location.canonicalPath, directoryHint: .isDirectory)
            if FileSystem.isDirectory(url) { result.append((location.projectId, url)) }
        }
        return result
    }

    /// One reconciliation pass for a project (works without FSEvents).
    @discardableResult
    public func reconcile(projectId: ProjectID) async -> ProjectReconciliation {
        let result: ProjectReconciliation
        do {
            let requests = try await materializer.reconcile(projectId: projectId)
            let adrs = try? await adrImporter.importADRs(projectId: projectId)
            result = ProjectReconciliation(projectId: projectId, requests: requests, adrs: adrs, error: nil)
        } catch {
            result = ProjectReconciliation(projectId: projectId, requests: RequestSyncReport(), adrs: nil, error: "\(error)")
        }
        reportContinuation.yield(result)
        return result
    }

    @discardableResult
    public func reconcileAll() async throws -> [ProjectReconciliation] {
        var results: [ProjectReconciliation] = []
        for (projectId, _) in try await watchedProjects() {
            results.append(await reconcile(projectId: projectId))
        }
        return results
    }

    /// Starts FSEvents watching for all project folders plus periodic reconciliation.
    public func start(reconcileInterval: Duration = .seconds(300), debounce: Duration = .milliseconds(400)) async throws {
        stop()
        let projects = try await watchedProjects()
        roots = projects.map { ($0.0, FileSystem.realPath($0.1)) }
        if !projects.isEmpty {
            let watcher = RepositoryWatcher(paths: projects.map(\.1))
            try watcher.start()
            self.watcher = watcher
            let changes = watcher.changes
            tasks.append(Task { [weak self] in
                for await batch in changes {
                    await self?.handle(batch, debounce: debounce)
                }
            })
        }
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: reconcileInterval)
                if Task.isCancelled { break }
                _ = try? await self?.reconcileAll()
            }
        })
    }

    public func stop() {
        watcher?.stop()
        watcher = nil
        tasks.forEach { $0.cancel() }
        tasks = []
    }

    private func handle(_ batch: [RepositoryWatcher.Change], debounce: Duration) async {
        for change in batch {
            for root in roots where change.path == root.path || change.path.hasPrefix(root.path + "/") {
                // Only Markdown files, folders (moves) and rescan requests matter.
                let relevant = change.requiresRescan || change.path.hasSuffix(".md") || change.path == root.path
                    || FileSystem.isDirectory(URL(filePath: change.path)) || !FileSystem.exists(URL(filePath: change.path))
                if relevant, !change.path.contains("/.git/") { pending.insert(root.projectId) }
            }
        }
        guard !pending.isEmpty, !flushScheduled else { return }
        flushScheduled = true
        try? await Task.sleep(for: debounce)
        flushScheduled = false
        let projects = pending
        pending = []
        for projectId in projects.sorted(by: { $0.uuidString < $1.uuidString }) {
            await reconcile(projectId: projectId)
        }
    }
}
