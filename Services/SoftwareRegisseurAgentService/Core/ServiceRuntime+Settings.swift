import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC
import SoftwareRegisseurPersistence
import SoftwareRegisseurWorkspace

/// Projekt-, Global- und Diensteinstellungen aus der Mac-UI (seit Protokoll 3; F2, J1, J2a, L1, M3, ADR-0006).
///
/// Modell/Stufe werden gegen die Fähigkeitsmatrix des ausführenden Macs geprüft; unzulässige Kombinationen
/// werden abgelehnt, nie still ersetzt. Synchronisierte Werte laufen über `ProjectRepository`,
/// `GlobalSettingsRepository` und `PreferenceRepository`.
extension ServiceRuntime {
    var knownProviderIds: Set<ProviderID> { Set(providers.providerIds + [.codex, .claudeCode]) }

    func updateProjectSettings(_ command: ProjectSettingsCommand) async throws {
        guard let project = try await database.projects.fetch(command.projectId) else { throw ServiceError.projectNotFound(command.projectId) }
        guard var settings = try await database.projects.settings(forProject: project.id) else {
            throw ServiceError.settingInvalid("Für dieses Projekt sind keine Einstellungen gespeichert.")
        }
        guard settings.revision == command.expectedRevision else {
            throw StoreError.revisionConflict(entity: .projectSettings, id: settings.id.uuidString, expected: command.expectedRevision,
                                              actual: settings.revision)
        }
        try validateParallelism(command.maxParallelJobs)
        if let agent = command.defaultAgentId, !knownProviderIds.contains(agent) { throw ServiceError.providerUnknown(agent) }
        let now = clock.now()
        var preferences: [ProviderID: AgentModelPreference] = [:]
        for choice in command.modelPreferences where !choice.inherits {
            guard preferences[choice.providerId] == nil else { throw ServiceError.settingInvalid("Agent doppelt angegeben.") }
            try await validate(choice, hostId: project.hostId ?? hostId)
            preferences[choice.providerId] = AgentModelPreference(
                scope: .project(project.id), providerId: choice.providerId, model: choice.model, effort: choice.effort, updatedAt: now)
        }
        settings.defaultAgentId = command.defaultAgentId
        settings.agentModelPreferencesByProvider = preferences
        settings.integrationStrategy = command.integrationStrategy
        settings.allowParallel = command.allowParallel
        settings.maxParallelJobs = command.maxParallelJobs
        settings.projectWideLock = command.projectWideLock
        settings.reviewPolicy = command.reviewPolicy
        settings.agentInstructionsPolicy = command.agentInstructionsPolicy
        _ = try await database.projects.saveSettings(settings, expectedRevision: command.expectedRevision, at: now)
        // Neue Werte gelten für neue Jobs (A38); bestehende Snapshots bleiben unverändert.
        jobsSignal.signal()
        sendSoon()
    }

    func gitHubProjectState(_ projectId: ProjectID) async throws -> GitHubProjectStateInfo {
        guard try await database.projects.fetch(projectId) != nil else { throw ServiceError.projectNotFound(projectId) }
        let enabled = try await gitHub.isEnabled(projectId: projectId)
        do {
            let repository = try await gitHub.repository(for: projectId)
            return GitHubProjectStateInfo(projectId: projectId, enabled: enabled, repository: repository, detail: nil)
        } catch {
            return GitHubProjectStateInfo(projectId: projectId, enabled: enabled, repository: nil, detail: ServiceErrorText.message(for: error))
        }
    }

    func updateGlobalSettings(_ command: GlobalSettingsCommand) async throws {
        let layout = FolderLayoutDefaults(
            adrPath: command.folderLayout.adrPath, requestsRoot: command.folderLayout.requestsRoot,
            openPath: command.folderLayout.openPath, activePath: command.folderLayout.activePath,
            reviewPath: command.folderLayout.reviewPath, donePath: command.folderLayout.donePath)
        guard layout.isValid else {
            throw ServiceError.settingInvalid("Die Standard-Ordnerstruktur braucht relative Pfade ohne „..“.")
        }
        let statusFolders = [layout.openPath, layout.activePath, layout.reviewPath, layout.donePath]
        guard Set(statusFolders).count == statusFolders.count else {
            throw ServiceError.settingInvalid("Die Statusordner müssen unterschiedlich sein.")
        }
        try validateParallelism(command.maxParallelJobs)
        if let agent = command.defaultAgentId, !knownProviderIds.contains(agent) { throw ServiceError.providerUnknown(agent) }
        var settings = try await database.globalSettings.fetch()
        settings.defaultAgentId = command.defaultAgentId
        settings.folderLayout = layout
        settings.workspace = WorkspaceDefaults(
            allowParallel: command.allowParallel, projectWideLock: command.projectWideLock, maxParallelJobs: command.maxParallelJobs,
            reviewPolicy: command.reviewPolicy, integrationStrategy: command.integrationStrategy,
            agentInstructionsPolicy: command.agentInstructionsPolicy, proposeGitInitForNewFolders: command.proposeGitInitForNewFolders)
        _ = try await database.globalSettings.save(settings, expectedRevision: command.expectedRevision, at: clock.now())
        sendSoon()
    }

    /// Globale Modell-/Stufenwahl (ADR-0006). Ohne Wahl wird die Voreinstellung entfernt (Anbieterstandard).
    func setGlobalModelPreference(_ choice: AgentModelChoice) async throws {
        guard knownProviderIds.contains(choice.providerId) else { throw ServiceError.providerUnknown(choice.providerId) }
        let now = clock.now()
        if choice.inherits {
            try await database.preferences.remove(scope: .global, providerId: choice.providerId, at: now)
        } else {
            try await validate(choice, hostId: hostId)
            try await database.preferences.save(AgentModelPreference(
                scope: .global, providerId: choice.providerId, model: choice.model, effort: choice.effort, updatedAt: now), at: now)
        }
        jobsSignal.signal()
        sendSoon()
    }

    /// Eigener Programmpfad eines Agenten (J1). Wirkt ohne Neustart: Anbieter neu aufbauen, neu erkennen.
    func setAgentExecutablePath(_ providerId: ProviderID, path: String?) async throws -> ServiceSettings {
        guard reconfigurableProviders.contains(where: { $0.providerId == providerId }) else { throw ServiceError.providerUnknown(providerId) }
        var updated = settings
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            updated.agentExecutablePaths[providerId.rawValue] = nil
        } else {
            var isDirectory: ObjCBool = false
            guard trimmed.hasPrefix("/"), FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDirectory),
                  !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: trimmed) else {
                throw ServiceError.executableInvalid(trimmed)
            }
            updated.agentExecutablePaths[providerId.rawValue] = trimmed
        }
        try await stateStore.saveSettings(updated)
        settings = updated.clamped
        reconfigureProviders()
        // Eine bereits laufende Erkennung nutzte noch den alten Pfad: abwarten und neu erkennen.
        if let detectionTask { _ = await detectionTask.value }
        _ = await detectAgents()
        return settings
    }

    /// Baut die Anbieter mit den aktuellen Programmpfaden neu und tauscht sie in den Hüllen aus.
    func reconfigureProviders() {
        let rebuilt = deps.makeProviders(hostId, deps.storage.detectionURL, Self.executableOverrides(settings))
        for wrapper in reconfigurableProviders {
            if let provider = rebuilt.provider(for: wrapper.providerId) { wrapper.replace(with: provider) }
        }
    }

    // MARK: Prüfungen

    func validate(_ choice: AgentModelChoice, hostId: HostID) async throws {
        guard let capability = try await database.capabilities.capability(hostId: hostId, providerId: choice.providerId) else {
            throw ServiceError.capabilityUnknown(choice.providerId)
        }
        let issues = ModelEffortResolver.validate(model: choice.model ?? .providerDefault, effort: choice.effort ?? .auto,
                                                  against: capability)
        guard issues.isEmpty else { throw ServiceError.configurationInvalid(issues) }
    }

    func validateParallelism(_ value: Int?) throws {
        guard let value else { return }
        let range = ProjectSettingsCommand.parallelJobsRange
        guard range.contains(value) else {
            throw ServiceError.settingInvalid("Höchstzahl paralleler Jobs muss zwischen \(range.lowerBound) und \(range.upperBound) liegen.")
        }
    }
}
