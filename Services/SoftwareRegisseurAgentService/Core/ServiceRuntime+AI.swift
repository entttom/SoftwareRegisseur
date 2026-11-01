import Foundation
import SoftwareRegisseurAI
import SoftwareRegisseurAppCore
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC
import SoftwareRegisseurPersistence
import SoftwareRegisseurWorkspace

/// KI-Ausarbeitung mit Repo-Kontext am Mac (Pflichtenheft H4, A11).
///
/// Quelle der Aufträge: `AIRequest` mit Modus `withRepositoryContext` und Zustand `pending` – vom
/// iPhone eingereiht („am Mac vertiefen“) oder über XPC aus der Mac-UI. Ablauf je Auftrag:
/// `RepoContextBuilder` (Geheimnisse ausgeschlossen, Budget), Schlüssel aus dem Mac-Schlüsselbund,
/// `DraftComposer`, neue synchronisierte `DraftVersion`. Ein Entwurf wird nie automatisch übernommen.
///
/// Transparenz: das Kontext-Manifest liegt hostlokal je Auftrag in `host_state` (XPC
/// `macAIElaborationStatus`) und als Verlaufseintrag (`comment`, synchronisiert) an der Aufgabe; dort
/// stehen auch deutsche Fehlermeldungen.
extension ServiceRuntime {
    static let aiEventType = "macAIElaboration"

    /// Legt einen Auftrag aus der Mac-UI an und startet ihn im Hintergrund.
    func requestMacAIElaboration(_ command: MacAIElaborationCommand) async throws -> MacAIElaborationInfo {
        guard let item = try await database.workItems.fetch(command.workItemId) else {
            throw ServiceError.workItemNotFound(command.workItemId)
        }
        guard let provider = SoftwareRegisseurDomain.AIProviderID(rawValue: command.providerId) else {
            throw ServiceError.invalidAIProvider(command.providerId)
        }
        guard let model = AIModelID(rawValue: command.modelId) else { throw ServiceError.invalidModel(command.modelId) }
        let now = clock.now()
        let request = AIRequest(itemId: item.uuid, provider: provider, model: model, mode: .withRepositoryContext,
                                inputVersion: item.revision, state: .pending, createdAt: now)
        try await database.aiRecords.saveRequest(request, at: now)
        let info = MacAIElaborationInfo(requestId: request.id, workItemId: item.uuid, state: .pending,
                                        providerId: command.providerId, modelId: command.modelId, updatedAt: now)
        try await stateStore.saveAIRecord(.init(mode: command.mode, selectedFiles: command.selectedFiles, info: info))
        sendSoon()
        pendingAIElaborations += 1
        Task { await self.elaborate(request) }
        return info
    }

    func macAIElaborationStatus(_ id: AIRequestID) async throws -> MacAIElaborationInfo {
        if let record = await stateStore.aiRecord(id) { return record.info }
        guard let request = try await database.aiRecords.request(id) else { throw ServiceError.aiRequestNotFound(id) }
        let state: MacAIElaborationInfo.State = switch request.state {
        case .pending: .pending
        case .running: .running
        case .completed: .completed
        case .failed, .cancelled: .failed
        }
        return MacAIElaborationInfo(requestId: id, workItemId: request.itemId, state: state, providerId: request.provider.rawValue,
                                    modelId: request.model.rawValue, draftVersion: request.draftVersion, updatedAt: request.createdAt)
    }

    /// Sucht eingereihte Aufträge der Projekte dieses Macs und arbeitet sie nacheinander ab.
    func processAIQueue() async {
        var pending: [AIRequest] = []
        for projectId in watchedProjects {
            guard let items = try? await database.workItems.list(WorkItemFilter(project: .project(projectId))) else { continue }
            for item in items {
                guard let requests = try? await database.aiRecords.requests(itemId: item.uuid) else { continue }
                pending += requests.filter { $0.mode == .withRepositoryContext && $0.state == .pending && !aiInFlight.contains($0.id) }
            }
        }
        pendingAIElaborations = pending.count
        for request in pending.sorted(by: { $0.createdAt < $1.createdAt }) {
            // Vom iPhone eingereihte Aufträge nur, wenn der Benutzer das am Mac nicht abgeschaltet hat.
            let fromMac = await stateStore.aiRecord(request.id) != nil
            guard fromMac || settings.processQueuedAIElaborations else { continue }
            await elaborate(request)
        }
    }

    /// Führt einen Auftrag aus. Fehler landen lesbar am Auftrag, nie als Absturz oder im Klartext-Log.
    func elaborate(_ request: AIRequest) async {
        guard !aiInFlight.contains(request.id) else { return }
        aiInFlight.insert(request.id)
        defer {
            aiInFlight.remove(request.id)
            pendingAIElaborations = max(0, pendingAIElaborations - 1)
        }
        let stored = await stateStore.aiRecord(request.id)
        let mode = DraftMode(rawValue: (stored?.mode ?? .ausfuehrlich).rawValue) ?? .ausfuehrlich
        var info = stored?.info ?? MacAIElaborationInfo(
            requestId: request.id, workItemId: request.itemId, state: .pending, providerId: request.provider.rawValue,
            modelId: request.model.rawValue, updatedAt: clock.now())
        var current = request
        current.state = .running
        try? await database.aiRecords.saveRequest(current, at: clock.now())
        info.state = .running
        info.updatedAt = clock.now()
        try? await stateStore.saveAIRecord(.init(mode: stored?.mode ?? .ausfuehrlich, selectedFiles: stored?.selectedFiles ?? [], info: info))

        do {
            guard let item = try await database.workItems.fetch(request.itemId) else { throw ServiceError.workItemNotFound(request.itemId) }
            guard let projectId = item.projectId else { throw JobOrchestratorErrorBridge.workItemWithoutProject }
            let root = try await environment.projectRoot(projectId)
            let layout = try await environment.layout(projectId)
            let context = RepoContextBuilder().build(root: root, layout: layout, selectedFiles: stored?.selectedFiles ?? [])
            info.included = context.manifest.included.map {
                .init(kind: $0.kind.rawValue, title: $0.title, path: $0.path, characterCount: $0.characterCount,
                      redactionCount: $0.redactionCount, truncated: $0.truncated)
            }
            info.excluded = context.manifest.excluded.map { .init(title: $0.title, path: $0.path, reason: $0.reason.description) }
            info.estimatedTokens = context.manifest.estimatedTokens

            let provider = try deps.makeTextProvider(SoftwareRegisseurAI.AIProviderID(request.provider.rawValue), deps.keychain)
            let composer = DraftComposer(provider: provider, model: request.model.rawValue)
            let drafts = DraftVersionStore(repository: database.draftVersions)
            let latestAI = try await drafts.versions(for: item.uuid).last { $0.source == .ai }?.contents.first
            let input = DraftInput(
                originalNote: item.originalNote.isEmpty ? item.title : item.originalNote, transcript: item.transcript,
                currentDraft: latestAI.map(DraftMapping.structuredDraft), projectContext: context.items)
            let composition = try await composer.compose(try composer.prepare(input, mode: mode))

            let now = clock.now()
            try await drafts.recordText(item.originalNote, source: .original, for: item.uuid, at: now)
            if let transcript = item.transcript { try await drafts.recordText(transcript, source: .transcript, for: item.uuid, at: now) }
            let version = try await drafts.append(
                for: item.uuid, source: .composer, mode: mode, provider: composition.provider.rawValue, model: composition.model,
                drafts: composition.drafts, usage: composition.usage, at: now)
            current.state = .completed
            current.draftVersion = version.version
            current.usage = TokenUsage(inputTokens: composition.usage.inputTokens, outputTokens: composition.usage.outputTokens)
            try await database.aiRecords.saveRequest(current, at: now)
            info.state = .completed
            info.draftVersion = version.version
            info.errorMessage = nil
            info.updatedAt = now
            ServiceLog.ai.notice("KI-Ausarbeitung \(request.id.shortString, privacy: .public) fertig: Entwurf v\(version.version, privacy: .public), \(info.included.count, privacy: .public) Kontextteile")
        } catch {
            let now = clock.now()
            current.state = .failed
            try? await database.aiRecords.saveRequest(current, at: now)
            info.state = .failed
            info.errorMessage = Self.aiErrorMessage(error)
            info.updatedAt = now
            ServiceLog.ai.error("KI-Ausarbeitung \(request.id.shortString, privacy: .public) fehlgeschlagen: \(info.errorMessage ?? "", privacy: .private)")
        }
        try? await stateStore.saveAIRecord(.init(mode: stored?.mode ?? .ausfuehrlich, selectedFiles: stored?.selectedFiles ?? [], info: info))
        await recordAIEvent(info)
        sendSoon()
    }

    static func aiErrorMessage(_ error: any Error) -> String {
        if case JobOrchestratorErrorBridge.workItemWithoutProject = error {
            return "Die Aufgabe gehört zu keinem Projekt; ohne Repository gibt es keinen Mac-Kontext."
        }
        return ServiceErrorText.message(for: error)
    }

    /// Synchronisierter Verlaufseintrag: was übermittelt wurde (Pfade, Umfang) oder warum es scheiterte.
    private func recordAIEvent(_ info: MacAIElaborationInfo) async {
        guard let item = try? await database.workItems.fetch(info.workItemId) else { return }
        var payload: [String: String] = [
            "type": Self.aiEventType,
            "aiRequestId": info.requestId.uuidString,
            "state": info.state.rawValue,
            "provider": info.providerId,
            "model": info.modelId,
            "includedCount": String(info.included.count),
            "excludedCount": String(info.excluded.count),
            "estimatedTokens": String(info.estimatedTokens),
        ]
        let paths = info.included.compactMap(\.path).prefix(40)
        if !paths.isEmpty { payload["includedPaths"] = ServiceLog.redact(paths.joined(separator: "\n"), limit: 4_000) }
        if let version = info.draftVersion { payload["draftVersion"] = String(version) }
        if let message = info.errorMessage { payload["error"] = message }
        let event = TaskEvent(workItemId: item.uuid, kind: .comment, actor: hostActor, timestamp: clock.now(),
                              payload: payload, sourceRevision: item.revision)
        do {
            try await database.events.append(event)
        } catch {
            ServiceLog.ai.error("Verlaufseintrag nicht gespeichert: \(ServiceLog.redact(error), privacy: .private)")
        }
    }
}

/// Interne Fehler der KI-Ausarbeitung ohne eigenes Fehlerpaket.
enum JobOrchestratorErrorBridge: Error {
    case workItemWithoutProject
}
