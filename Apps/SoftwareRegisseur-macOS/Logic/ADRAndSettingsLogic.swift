import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC

// MARK: - ADR-Statuswechsel (F4)

/// Ausdrückliche ADR-Entscheidungen. Nur Übergänge der Zustandsmaschine; „ersetzt“ braucht den ersetzenden ADR.
enum ADRStatusAction: Hashable, Sendable, Identifiable {
    case accept
    case deprecate
    case supersede(by: ADRNumber)

    var id: String {
        switch self {
        case .accept: "accept"
        case .deprecate: "deprecate"
        case let .supersede(number): "supersede-\(number.value)"
        }
    }

    var targetStatus: ADRStatus {
        switch self {
        case .accept: .accepted
        case .deprecate: .deprecated
        case .supersede: .superseded
        }
    }

    var supersededBy: Int? {
        if case let .supersede(number) = self { return number.value }
        return nil
    }

    var title: String {
        switch self {
        case .accept: String(localized: "Annehmen")
        case .deprecate: String(localized: "Als veraltet markieren")
        case let .supersede(number): String(localized: "Ersetzt durch ADR-\(number.formatted)")
        }
    }

    var confirmation: String {
        switch self {
        case .accept:
            String(localized: "Der ADR wird angenommen: Im Frontmatter der Datei wird nur „status“ geändert. Software Regisseur committet nicht (ADR-0024).")
        case .deprecate:
            String(localized: "Der ADR wird als veraltet markiert: Im Frontmatter der Datei wird nur „status“ geändert. Es wird nichts committet.")
        case let .supersede(number):
            String(localized: "Der ADR wird als ersetzt markiert; ADR-\(number.formatted) erhält einen „supersedes“-Eintrag. Nur das Frontmatter beider Dateien ändert sich, es wird nichts committet.")
        }
    }

    func request(for adr: ADR) -> ServiceRequest {
        .changeADRStatus(adrId: adr.uuid, expectedRevision: adr.revision, status: targetStatus, supersededBy: supersededBy)
    }

    /// Mögliche Aktionen für `adr`; Ersetzen durch jeden anderen nicht veralteten/ersetzten ADR des Projekts.
    static func actions(for adr: ADR, in projectADRs: [ADR]) -> [ADRStatusAction] {
        var result: [ADRStatusAction] = []
        if adr.status.canTransition(to: .accepted) { result.append(.accept) }
        if adr.status.canTransition(to: .deprecated) { result.append(.deprecate) }
        if adr.status.canTransition(to: .superseded) {
            result += projectADRs
                .filter { $0.uuid != adr.uuid && ($0.status == .proposed || $0.status == .accepted) }
                .sorted { $0.decisionNumber > $1.decisionNumber }
                .map { .supersede(by: $0.decisionNumber) }
        }
        return result
    }
}

/// Eingaben eines neuen ADR-Entwurfs; Nummer und Datei erzeugt der Dienst (ADR-0018, ADR-0024).
struct ADRCreateForm: Hashable, Sendable {
    var title = ""
    var context = ""
    var decision = ""
    var alternatives = ""
    var consequences = ""
    var supersedesText = ""

    var isValid: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var supersedes: [Int] {
        supersedesText.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int($0) }.filter { $0 > 0 }
    }

    func command(projectId: ProjectID) -> CreateADRCommand {
        CreateADRCommand(projectId: projectId, title: title, context: context, decision: decision, alternatives: alternatives,
                         consequences: consequences, supersedes: supersedes)
    }
}

// MARK: - Modell/Stufe (ADR-0006)

/// Auswahl für Modell und Stufe eines Agenten, nur mit Werten aus der Fähigkeitsmatrix. Eine Kombination,
/// die der Agent nicht meldet, wird nie angeboten (keine stillen Fallbacks).
struct ModelChoiceOptions: Hashable, Sendable {
    let capability: AgentCapability

    /// Modellwahl: `nil` = erben, `.providerDefault`, dann die verfügbaren Modelle.
    var models: [ModelSelection] {
        guard capability.supportsModelSelection else { return [.providerDefault] }
        return [.providerDefault] + capability.modelCatalog.filter { $0.availability == .available }.map { .model($0.modelId) }
    }

    /// Stufen, die zur Modellwahl passen (`nil` Modell = Anbieterstandard).
    func efforts(for model: ModelSelection?) -> [EffortLevel] {
        var levels = EffortLevel.knownLevels
        for entry in capability.modelCatalog {
            for level in entry.supportedEffortIds where !levels.contains(level) { levels.append(level) }
        }
        return levels.filter { isValid(model: model, effort: $0) }
    }

    func isValid(model: ModelSelection?, effort: EffortLevel?) -> Bool {
        ModelEffortResolver.validate(model: model ?? .providerDefault, effort: effort ?? .auto, against: capability).isEmpty
    }
}

/// Bearbeitbare Projekteinstellungen (J2a, L1, ADR-0015) ohne Ordnerstruktur.
struct ProjectSettingsForm: Hashable, Sendable {
    let projectId: ProjectID
    let baseRevision: Int
    var defaultAgentId: ProviderID?
    var choices: [ProviderID: AgentModelChoice]
    var integrationStrategy: IntegrationStrategy
    var allowParallel: Bool
    var limitParallelJobs: Bool
    var maxParallelJobs: Int
    var projectWideLock: Bool
    var reviewPolicy: ReviewPolicy
    var agentInstructionsPolicy: AgentInstructionsPolicy

    init(projectId: ProjectID, settings: ProjectSettings) {
        self.projectId = projectId
        baseRevision = settings.revision
        defaultAgentId = settings.defaultAgentId
        choices = settings.agentModelPreferencesByProvider.mapValues {
            AgentModelChoice(providerId: $0.providerId, model: $0.inheritsDefault ? nil : $0.model, effort: $0.inheritsDefault ? nil : $0.effort)
        }
        integrationStrategy = settings.integrationStrategy
        allowParallel = settings.allowParallel
        limitParallelJobs = settings.maxParallelJobs != nil
        maxParallelJobs = settings.maxParallelJobs ?? 2
        projectWideLock = settings.projectWideLock
        reviewPolicy = settings.reviewPolicy
        agentInstructionsPolicy = settings.agentInstructionsPolicy
    }

    func choice(for provider: ProviderID) -> AgentModelChoice {
        choices[provider] ?? AgentModelChoice(providerId: provider)
    }

    /// Gegen die Fähigkeiten geprüfte Probleme (deutsch); leer = speicherbar.
    func problems(capabilities: [AgentCapability]) -> [String] {
        var result: [String] = []
        for choice in choices.values where !choice.inherits {
            guard let capability = capabilities.first(where: { $0.providerId == choice.providerId }) else {
                result.append(String(localized: "\(ProviderNames.displayName(choice.providerId)) wurde auf diesem Mac nicht erkannt; Modell/Stufe können nicht geprüft werden."))
                continue
            }
            if !ModelChoiceOptions(capability: capability).isValid(model: choice.model, effort: choice.effort) {
                result.append(String(localized: "Diese Modell-/Stufenkombination meldet \(ProviderNames.displayName(choice.providerId)) nicht."))
            }
        }
        if limitParallelJobs, !ProjectSettingsCommand.parallelJobsRange.contains(maxParallelJobs) {
            result.append(String(localized: "Höchstzahl paralleler Jobs: 1 bis 16."))
        }
        return result
    }

    var command: ProjectSettingsCommand {
        ProjectSettingsCommand(
            projectId: projectId, expectedRevision: baseRevision, defaultAgentId: defaultAgentId,
            modelPreferences: choices.values.filter { !$0.inherits }.sorted { $0.providerId < $1.providerId },
            integrationStrategy: integrationStrategy, allowParallel: allowParallel,
            maxParallelJobs: limitParallelJobs ? maxParallelJobs : nil, projectWideLock: projectWideLock,
            reviewPolicy: reviewPolicy, agentInstructionsPolicy: agentInstructionsPolicy)
    }
}

/// Synchronisierte Benutzer-Standards (GlobalSettings, F2/J2).
struct GlobalDefaultsForm: Hashable, Sendable {
    let baseRevision: Int
    var defaultAgentId: ProviderID?
    var layout: FolderLayoutForm
    var allowParallel: Bool
    var projectWideLock: Bool
    var limitParallelJobs: Bool
    var maxParallelJobs: Int
    var reviewPolicy: ReviewPolicy
    var integrationStrategy: IntegrationStrategy
    var agentInstructionsPolicy: AgentInstructionsPolicy
    var proposeGitInitForNewFolders: Bool

    init(_ settings: GlobalSettings) {
        baseRevision = settings.revision
        defaultAgentId = settings.defaultAgentId
        let folders = settings.folderLayout
        layout = FolderLayoutForm(adrPath: folders.adrPath, requestsRoot: folders.requestsRoot, openPath: folders.openPath,
                                  activePath: folders.activePath, reviewPath: folders.reviewPath, donePath: folders.donePath)
        allowParallel = settings.workspace.allowParallel
        projectWideLock = settings.workspace.projectWideLock
        limitParallelJobs = settings.workspace.maxParallelJobs != nil
        maxParallelJobs = settings.workspace.maxParallelJobs ?? 2
        reviewPolicy = settings.workspace.reviewPolicy
        integrationStrategy = settings.workspace.integrationStrategy
        agentInstructionsPolicy = settings.workspace.agentInstructionsPolicy
        proposeGitInitForNewFolders = settings.workspace.proposeGitInitForNewFolders
    }

    var problems: [String] {
        var result = layout.problems
        if limitParallelJobs, !ProjectSettingsCommand.parallelJobsRange.contains(maxParallelJobs) {
            result.append(String(localized: "Höchstzahl paralleler Jobs: 1 bis 16."))
        }
        return result
    }

    var command: GlobalSettingsCommand {
        GlobalSettingsCommand(
            expectedRevision: baseRevision, defaultAgentId: defaultAgentId,
            folderLayout: FolderLayoutPaths(adrPath: layout.adrPath, requestsRoot: layout.requestsRoot, openPath: layout.openPath,
                                            activePath: layout.activePath, reviewPath: layout.reviewPath, donePath: layout.donePath),
            allowParallel: allowParallel, projectWideLock: projectWideLock, maxParallelJobs: limitParallelJobs ? maxParallelJobs : nil,
            reviewPolicy: reviewPolicy, integrationStrategy: integrationStrategy, agentInstructionsPolicy: agentInstructionsPolicy,
            proposeGitInitForNewFolders: proposeGitInitForNewFolders)
    }
}

// MARK: - Datenlöschung (A34)

/// Zweistufige Bestätigung: Vorschau ansehen, ausdrücklich bestätigen, dann löschen.
struct DeletionConfirmation: Hashable, Sendable {
    var confirmed = false

    func canExecute(preview: LocalDeletionPreviewInfo?, now: Date) -> Bool {
        guard let preview, !preview.isEmpty else { return false }
        return confirmed && now <= preview.expiresAt
    }

    func canConfirmCloud(preview: CloudDeletionPreviewInfo?, now: Date) -> Bool {
        guard let preview else { return false }
        return confirmed && now <= preview.expiresAt
    }

    static func summary(_ report: LocalDeletionReportInfo) -> String {
        var text = String(localized: "\(report.deleted.count) Einträge gelöscht")
        if !report.alreadyMissing.isEmpty { text += ", " + String(localized: "\(report.alreadyMissing.count) waren schon entfernt") }
        if !report.failed.isEmpty { text += ", " + String(localized: "\(report.failed.count) fehlgeschlagen") }
        text += "."
        if report.databaseReopened {
            text += " " + String(localized: "Die Datenbank wurde leer neu angelegt; bitte Stammordner neu bestätigen.")
        }
        return text
    }
}

extension LocalDeletionKind {
    var title: String {
        switch self {
        case .localDatabase: String(localized: "Lokale Datenbank und Zwischenspeicher")
        case .apiKeys: String(localized: "API-Schlüssel der KI-Anbieter")
        case .everythingLocal: String(localized: "Alle lokalen Daten des Dienstes")
        }
    }
}
