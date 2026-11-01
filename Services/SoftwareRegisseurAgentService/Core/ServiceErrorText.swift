import Foundation
import SoftwareRegisseurAI
import SoftwareRegisseurDomain
import SoftwareRegisseurGit
import SoftwareRegisseurJobs
import SoftwareRegisseurMarkdown
import SoftwareRegisseurPersistence
import SoftwareRegisseurPortability
import SoftwareRegisseurSync
import SoftwareRegisseurWorkspace

/// Fehler des Dienstes selbst (Befehle, Konfiguration).
enum ServiceError: Error, Hashable, Sendable {
    case notReady
    case gitUnavailable
    case cloudSyncUnavailable(String)
    case invalidPath(String)
    case rootFolderMissing(String)
    case rootFolderOverlapsServiceStorage(String)
    case rootFolderUnknown(String)
    case noRootFolders
    case projectNotFound(ProjectID)
    case projectNotOnThisMac(ProjectID)
    case workItemNotFound(WorkItemID)
    case jobNotFound(JobID)
    case approvalNotFound(PendingApprovalID)
    case approvalClosed
    case decisionNotAllowed(ApprovalDecisionKind)
    case proposalNotFound(UUID)
    case migrationPlanNotFound(UUID)
    case reviewDetailsUnavailable(ReviewID)
    case capabilityUnknown(ProviderID)
    case invalidAIProvider(String)
    case invalidModel(String)
    case aiRequestNotFound(AIRequestID)
    case gitHubUnavailable(String)
    case configurationInvalid([ConfigurationIssue])

    // Seit Protokoll 3
    case titleMissing
    case manualStatusNotAllowed(SoftwareRegisseurDomain.WorkItemStatus)
    case useMarkDone
    case workItemLocked(LockScope)
    case workItemAlreadyMaterialized
    case workItemNumbered(SoftwareRegisseurDomain.HumanID)
    case dependencyInvalid
    case projectNotUsable(ProjectID)
    case draftNotFound(DraftVersionID)
    case draftContentMissing
    case draftIdInUse
    case conversationMismatch
    case conversationDiverged
    case approvalNeedsFullText
    case adrNotFound(ADRID)
    case adrFileMissing(String)
    case adrWithoutFrontmatter(String)
    case adrTransitionNotAllowed(from: SoftwareRegisseurDomain.ADRStatus, to: SoftwareRegisseurDomain.ADRStatus)
    case adrSupersedingMissing(Int)
    case adrStatusRequiresCommand(SoftwareRegisseurDomain.ADRStatus)
    case settingInvalid(String)
    case providerUnknown(ProviderID)
    case executableInvalid(String)
    case deletionPlanNotFound
    case agentsRunning(Int)
    case shutDownForDeletion
}

/// Deutsche, geheimnisfreie Fehlermeldungen für die UI (Pflichtenheft P, Q1).
enum ServiceErrorText {
    static func message(for error: any Error) -> String {
        ServiceLog.redact(text(for: error))
    }

    private static func text(for error: any Error) -> String {
        switch error {
        case let error as ServiceError: return text(error)
        case let error as JobOrchestratorError: return text(error)
        case let error as WorkspaceError: return error.description
        case let error as GitHubIssueError: return error.description
        case let error as AIProviderError: return error.userMessage()
        case let error as StoreError: return text(error)
        case let error as ProjectSetupFailure: return "Projekt konnte nicht eingerichtet werden: \(error.message)"
        case let error as GitError: return "Git-Fehler: \(String(describing: error))"
        case let error as DeletionError: return error.userMessage
        case let error as CloudDataDeletionError: return error.userMessage
        case let error as FrontmatterError:
            return "Das Frontmatter der Datei kann nicht sicher geändert werden (\(String(describing: error))). Bitte die Datei im Editor prüfen."
        default: return "Unerwarteter Fehler: \(String(describing: error))"
        }
    }

    private static func text(_ error: ServiceError) -> String {
        switch error {
        case .notReady: "Der Dienst startet noch. Bitte gleich erneut versuchen."
        case .gitUnavailable: "Git wurde auf diesem Mac nicht gefunden. Bitte die Xcode-Befehlszeilenwerkzeuge installieren."
        case let .cloudSyncUnavailable(reason): "iCloud-Synchronisierung nicht verfügbar: \(reason)"
        case let .invalidPath(path): "Ungültiger Pfad: \(path)"
        case let .rootFolderMissing(path): "Der Ordner \(path) existiert nicht."
        case let .rootFolderOverlapsServiceStorage(path):
            "Der Ordner \(path) enthält die Arbeitsordner von Software Regisseur und kann kein Stammordner sein."
        case let .rootFolderUnknown(path): "\(path) ist kein bestätigter Stammordner."
        case .noRootFolders: "Noch kein Stammordner bestätigt. Bitte in den Einstellungen einen Git-Stammordner wählen."
        case .projectNotFound: "Projekt nicht gefunden."
        case .projectNotOnThisMac: "Dieses Projekt wird auf einem anderen Mac ausgeführt."
        case .workItemNotFound: "Aufgabe nicht gefunden."
        case .jobNotFound: "Auftrag nicht gefunden."
        case .approvalNotFound: "Freigabeanfrage nicht gefunden."
        case .approvalClosed: "Die Freigabeanfrage ist bereits beantwortet, abgelaufen oder zurückgezogen."
        case let .decisionNotAllowed(kind): "Diese Entscheidung (\(kind.rawValue)) ist für die Anfrage nicht vorgesehen."
        case .proposalNotFound: "Der Vorschlag ist nicht mehr vorhanden. Bitte neu berechnen."
        case .migrationPlanNotFound: "Die Vorschau ist nicht mehr vorhanden. Bitte neu erstellen."
        case .reviewDetailsUnavailable: "Für dieses Review liegen auf diesem Mac keine Details vor."
        case let .capabilityUnknown(provider): "Agent \(provider.rawValue) wurde auf diesem Mac nicht erkannt."
        case let .invalidAIProvider(provider): "Unbekannter KI-Anbieter: \(provider)"
        case let .invalidModel(model): "Ungültige Modellkennung: \(model)"
        case .aiRequestNotFound: "KI-Ausarbeitung nicht gefunden."
        case let .gitHubUnavailable(detail): "GitHub nicht verfügbar: \(detail)"
        case let .configurationInvalid(issues): issues.map(\.germanDescription).joined(separator: " ")
        case .titleMissing: "Bitte einen Titel eingeben."
        case let .manualStatusNotAllowed(status):
            "Den Status „\(status.germanDisplayName)“ setzt nur der Dienst aus einem Agentenjob bzw. nach der Integration (ADR-0012)."
        case .useMarkDone:
            "Integrierte Aufgaben bitte mit „Als erledigt markieren“ abschließen; die Datei wandert dann in den done-Ordner."
        case let .workItemLocked(scope):
            "Die Aufgabe ist gesperrt (\(scope == .project ? "projektweite Sperre" : "Aufgabensperre")): Ein Agentenjob arbeitet daran. Statuswechsel erst nach Ende des Jobs (ADR-0012)."
        case .workItemAlreadyMaterialized:
            "Diese Aufgabe kann nicht gelöscht werden: Für sie gibt es bereits eine Request-Datei, eine Nummer oder Agentenjobs. Bitte stattdessen archivieren – so bleiben Verlauf und Verweise erhalten."
        case let .workItemNumbered(id):
            "Die Aufgabe hat bereits die Nummer \(id.formatted) in ihrem Repository (ADR-0018). Das Projekt lässt sich nicht mehr ändern; bitte duplizieren und die Kopie zuordnen."
        case .dependencyInvalid: "Abhängigkeiten müssen auf andere, vorhandene Aufgaben verweisen."
        case .projectNotUsable: "Das Projekt ist archiviert oder nicht vorhanden."
        case .draftNotFound: "Der KI-Entwurf ist nicht mehr vorhanden."
        case .draftContentMissing: "Der KI-Entwurf enthält keinen übernehmbaren Inhalt."
        case .draftIdInUse: "Diese Entwurfs-ID gehört bereits zu einem anderen Entwurf. Bitte den Vorschlag erneut übernehmen."
        case .conversationMismatch: "Das Gespräch gehört zu einer anderen Aufgabe."
        case .approvalNeedsFullText:
            "Die Vorschau dieser Freigabe ist gekürzt. Erlauben ist erst möglich, nachdem Sie den vollständigen Text am Mac angesehen und das Lesen bestätigt haben."
        case .conversationDiverged:
            "Das Gespräch wurde inzwischen an anderer Stelle fortgesetzt. Bitte das Gespräch schließen und neu öffnen."
        case .adrNotFound: "ADR nicht gefunden."
        case let .adrFileMissing(path): "Die ADR-Datei \(path) ist auf diesem Mac nicht vorhanden. Bitte zuerst mit der Datei abgleichen."
        case let .adrWithoutFrontmatter(path):
            "\(path) hat kein YAML-Frontmatter. Den Status dieser Datei ändern Sie bitte im Editor; der Dienst übernimmt ihn beim Abgleich."
        case let .adrTransitionNotAllowed(from, to): "Ein ADR mit Status „\(from.rawValue)“ kann nicht „\(to.rawValue)“ werden."
        case let .adrSupersedingMissing(number): "ADR \(ADRNumbering.format(number)) existiert in diesem Projekt nicht."
        case let .adrStatusRequiresCommand(status):
            "Für den Status „\(status.rawValue)“ muss der ersetzende ADR angegeben werden."
        case let .settingInvalid(detail): "Ungültige Einstellung: \(detail)"
        case let .providerUnknown(provider): "Unbekannter Coding-Agent: \(provider.rawValue)"
        case let .executableInvalid(path): "\(path) ist keine ausführbare Datei. Bitte den vollständigen Pfad zum Programm angeben."
        case .deletionPlanNotFound: "Die Löschvorschau ist nicht mehr gültig. Bitte eine neue Vorschau erstellen."
        case let .agentsRunning(count): "Es laufen noch \(count) Agentenjob(s). Bitte erst beenden oder abbrechen, dann löschen."
        case .shutDownForDeletion: "Die Datenbank wird gerade gelöscht und neu angelegt. Bitte gleich erneut versuchen."
        }
    }

    private static func text(_ error: WorkItemStatusChangeError) -> String {
        switch error {
        case let .activeJobConflict(current, requested):
            "Ein Agentenjob ist aktiv (Status „\(current.germanDisplayName)“). „\(requested.germanDisplayName)“ kann erst nach Ende des Jobs gesetzt werden (ADR-0012)."
        case let .invalidTransition(transition):
            "Statuswechsel „\(transition.from.germanDisplayName)“ → „\(transition.to.germanDisplayName)“ ist nicht zulässig."
        }
    }

    private static func text(_ error: JobOrchestratorError) -> String {
        switch error {
        case .jobNotFound: "Auftrag nicht gefunden."
        case .workItemNotFound: "Aufgabe nicht gefunden."
        case .projectNotFound: "Projekt nicht gefunden."
        case .reviewNotFound: "Review nicht gefunden."
        case .workItemWithoutProject: "Die Aufgabe gehört zu keinem Projekt."
        case .userDecisionRequired: "Diese Aktion braucht eine ausdrückliche Benutzerentscheidung."
        case .notExecutionHost: "Dieser Mac ist nicht der Ausführungshost des Projekts."
        case let .capabilityUnknown(provider): "Agent \(provider.rawValue) wurde auf diesem Mac nicht erkannt."
        case let .configurationInvalid(issues): issues.map(\.germanDescription).joined(separator: " ")
        case let .invalidState(_, state): "Aktion im Auftragsstatus „\(state.rawValue)“ nicht möglich."
        case .noLiveSession: "Für diesen Auftrag läuft keine verbundene Agentensitzung."
        case .unknownApproval: "Unbekannte oder bereits beantwortete Freigabe."
        case .decisionNotAvailable: "Diese Entscheidung bietet der Agent nicht an."
        case .approvalPending: "Es ist noch eine Freigabe offen."
        case .orphanProcessRunning: "Ein Agentenprozess dieses Auftrags läuft noch."
        case .noMissedRunPending: "Für diesen Auftrag steht keine Entscheidung zu einem verpassten Termin aus."
        case let .reviewNotApproved(decision): "Das Review ist nicht freigegeben (\(decision.rawValue))."
        case let .alreadyIntegrated(commit): "Bereits integriert (\(commit.prefix(10)))."
        case let .workItemNotInReview(status): "Die Aufgabe ist nicht im Review (Status „\(status.rawValue)“)."
        case let .notIntegrated(status): "Die Änderung ist noch nicht integriert (Status „\(status.rawValue)“)."
        case let .integrationCommitNotInDefaultBranch(commit): "Commit \(commit.prefix(10)) ist nicht im Default-Branch."
        case let .integrationConflict(files): "Integration nicht möglich: Konflikte in \(files.count) Datei(en): \(files.prefix(5).joined(separator: ", "))"
        case let .integrationRefused(reason): "Integration abgelehnt: \(reason)"
        case .reviewDataUnavailable: "Review-Daten dieses Auftrags fehlen auf diesem Mac."
        case .repositoryUnavailable: "Repository auf diesem Mac nicht gefunden."
        }
    }

    private static func text(_ error: StoreError) -> String {
        switch error {
        case .readOnlyDatabase: "Datenbank ist schreibgeschützt geöffnet."
        case .schemaNotReady: "Datenbank ist noch nicht eingerichtet."
        case .schemaTooNew: "Die Datenbank stammt von einer neueren Version von Software Regisseur."
        case .notFound: "Eintrag nicht gefunden."
        case .revisionConflict: "Der Eintrag wurde inzwischen geändert. Bitte neu laden und erneut versuchen."
        case let .activeJobExists(_, jobId): "Für diese Aufgabe läuft bereits ein Auftrag (\(jobId.shortString))."
        case let .lockHeld(lock, _): "Aufgabe ist gesperrt (\(lock.shortString))."
        case .approvalClosed: "Die Freigabeanfrage ist bereits beantwortet, abgelaufen oder zurückgezogen."
        case let .approvalDecisionNotAllowed(_, kind): "Diese Entscheidung (\(kind.rawValue)) ist für die Anfrage nicht vorgesehen."
        case let .invalidSettings(detail): "Ungültige Einstellung: \(detail)"
        case let .workItemStatusChange(change): text(change)
        case let .invalidWorkItemTransition(transition):
            "Statuswechsel „\(transition.from.germanDisplayName)“ → „\(transition.to.germanDisplayName)“ ist nicht zulässig."
        case let .reclassificationRefused(.typeChangeAfterHumanID(id)):
            "Der Typ kann nicht mehr geändert werden: Der Mac hat bereits die Nummer \(id.formatted) vergeben (ADR-0018). Bitte duplizieren und die Kopie umklassifizieren."
        case .reclassificationRefused(.typeChangeDuringActiveJob):
            "Während ein Agentenjob läuft, kann der Typ nicht geändert werden (ADR-0012)."
        case .humanIDChangeNotAllowed: "Die menschenlesbare ID einer Aufgabe ändert sich nie (ADR-0018)."
        case let .identityFieldChanged(_, field) where field == "projectId":
            "Die Aufgabe hat bereits eine Nummer in ihrem Repository (ADR-0018); die Projektzuordnung lässt sich nicht mehr ändern."
        case let .invalidADRTransition(transition):
            "Ein ADR mit Status „\(transition.from.rawValue)“ kann nicht „\(transition.to.rawValue)“ werden."
        case .alreadyExists: "Der Eintrag existiert bereits."
        default: "Datenbankfehler: \(String(describing: error))"
        }
    }
}
