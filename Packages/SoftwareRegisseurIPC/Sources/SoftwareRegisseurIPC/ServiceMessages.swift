import Foundation
import SoftwareRegisseurDomain

/// Version des Nachrichtenprotokolls zwischen macOS-UI und Agent Service.
///
/// Wird bei jeder inkompatiblen Änderung an ``ServiceRequest``, ``ServiceResponse`` oder einem
/// darin enthaltenen Typ erhöht. UI und Dienst prüfen die Version in jedem Umschlag, damit ein
/// veralteter Dienst nach einem App-Update erkannt wird (Recherche apple-platform.md §3.2/§3.4).
///
/// - 1: Ping, Gesundheitsstatus, Pause/Fortsetzen/Stopp (Grundgerüst).
/// - 2: Vollständiger Befehlssatz aller Mac-UI-Aktionen, Statusübersicht für die Menüleiste
///      (README.md in diesem Paket).
/// - 3: Schreibwege der Mac-UI für Aufgaben, KI-Entwürfe, ADRs, Projekt-/Global-/Diensteinstellungen,
///      Datenlöschung (A34) und Sync-Konflikte. Abwärtskompatibel: Clients mit Protokoll 2 werden weiter
///      bedient (gleiche Befehle, Antworten mit ihrer Versionsnummer).
/// - 4: „Mit KI besprechen“ am Mac: Gespräch speichern (`saveConversation`) und Vorschlag als Entwurfsversion mit
///      Kanal `conversation` anlegen, optional sofort übernehmen (`appendConversationDraft`). Rein additiv; Clients
///      mit Protokoll 2 und 3 werden weiter bedient. Außerdem gekürzte Freigaben (SR-SEC-08): Volltext abrufen
///      (`fullApprovalPreview`) und Entscheidung am Mac mit Bestätigung des Volltexts (`answerApprovalOnHost`).
public enum IPCProtocol {
    public static let version = 4
    /// Älteste Client-Version, die der Dienst noch bedient. Neue Befehle sind rein additiv.
    public static let minimumSupportedVersion = 2

    /// Bedient der Dienst einen Client mit dieser Protokollversion?
    public static func supports(clientVersion: Int) -> Bool {
        (minimumSupportedVersion...version).contains(clientVersion)
    }
}

/// Anfrage der UI an den Agent Service.
///
/// Lesezugriffe der UI auf Projekte, Aufgaben, Jobs, Reviews usw. laufen über eine eigene
/// Nur-Lese-Verbindung zur Datenbank (`AppDatabase.openReadOnly`, ADR-0019). Über XPC gehen nur
/// Befehle (alle Schreibvorgänge) und Daten, die ausschließlich im Dienstprozess existieren
/// (Statusübersicht, Vorschläge, Vorschauen, hostlokale Review-Pfade).
///
/// Fachliche Entscheidungen (Freigaben, Reviews, Integration, Erledigt) werden immer im Namen des
/// Mac-Benutzers ausgeführt (`EventActor.user` mit der Geräte-ID dieses Macs).
public enum ServiceRequest: Codable, Sendable, Hashable {
    // MARK: Dienst

    /// Erreichbarkeitsprüfung mit minimaler Antwort → ``ServiceResponse/pong(_:)``.
    case ping
    /// Vollständiger Gesundheitsstatus → ``ServiceResponse/health(_:)``.
    case health
    /// Übersicht für Menüleiste und Dashboard → ``ServiceResponse/statusSummary(_:)``.
    case statusSummary
    /// Dienst pausieren: keine neuen Agentenstarts. Laufende Jobs, Sync und Scanner laufen weiter.
    case pause
    /// Pausierten Dienst fortsetzen.
    case resume
    /// Dienstprozess beenden. launchd startet ihn bei der nächsten Verbindung oder Anmeldung neu.
    case stop
    /// Hostlokale Diensteinstellungen lesen → ``ServiceResult/serviceSettings(_:)``.
    case serviceSettings
    /// Hostlokale Diensteinstellungen speichern → ``ServiceResult/serviceSettings(_:)``.
    case updateServiceSettings(ServiceSettings)

    // MARK: iCloud-Synchronisierung

    /// CloudKit-Synchronisierung sofort anstoßen (Antwort nach Abschluss) → ``ServiceResult/syncFinished(_:)``.
    case syncNow
    /// Sync-Konflikt eines Datensatzes entscheiden (A24).
    case resolveSyncConflict(conflictId: UUID, choice: SyncConflictChoice)
    /// Mit dem neuen iCloud-Account fortfahren (lokale Daten bleiben erhalten).
    case acknowledgeAccountChange(uploadAllLocalData: Bool)
    /// Nach gelöschten iCloud-Daten die Zone neu anlegen und alles erneut hochladen.
    case recreateCloudZone

    // MARK: Stammordner, Scanner, Projekte

    /// Scanner sofort ausführen (Antwort nach Abschluss) → ``ServiceResult/scanFinished(_:)``.
    case refreshScanner
    /// Bestätigte Stammordner und Vorschlag → ``ServiceResult/rootFolders(_:)``.
    case rootFolders
    /// Stammordner bestätigen/hinzufügen (absoluter Pfad) → ``ServiceResult/rootFolders(_:)``.
    case addRootFolder(path: String)
    /// Stammordner entfernen; Projekte und Aufgaben bleiben erhalten → ``ServiceResult/rootFolders(_:)``.
    case removeRootFolder(path: String)
    /// Re-Link-Kandidaten eines nicht erreichbaren Projekts → ``ServiceResult/paths(_:)``.
    case relinkCandidates(projectId: ProjectID)
    /// Projekt mit einem (verschobenen) Ordner neu verknüpfen.
    case relinkProject(projectId: ProjectID, path: String, allowDifferentRepository: Bool)
    /// Markdown-Abgleich eines Projekts sofort ausführen.
    case reconcileProject(projectId: ProjectID)
    /// Projekt anlegen oder verknüpfen (gleicher Auftrag wie vom iPhone, E2).
    case submitProjectSetup(ProjectSetupCommand)
    /// Konflikt einer Request-Datei entscheiden (N2).
    case resolveFileConflict(conflictId: FileConflictID, resolution: FileConflictResolution)

    // MARK: AGENTS.md / CLAUDE.md (G)

    /// Offene Vorschläge (optional nur eines Projekts) → ``ServiceResult/instructionProposals(_:)``.
    case instructionProposals(projectId: ProjectID?)
    /// Vorschlag für ein Projekt neu berechnen → ``ServiceResult/instructionProposals(_:)``.
    case proposeInstructions(projectId: ProjectID, createClaudeFileIfMissing: Bool)
    /// Freigegebenen Vorschlag schreiben (nur nach ausdrücklicher Zustimmung in der UI).
    case applyInstructionProposal(proposalId: UUID)
    /// Vorschlag verwerfen.
    case rejectInstructionProposal(proposalId: UUID)

    // MARK: Ordnerstruktur (F2)

    /// Vorschau einer neuen Ordnerstruktur → ``ServiceResult/folderMigrationPlan(_:)``.
    case previewFolderMigration(projectId: ProjectID, layout: FolderLayoutPaths)
    /// Vorschau übernehmen (verschiebt Dateien, speichert Einstellungen).
    case applyFolderMigration(planId: UUID)
    /// Vorschau verwerfen.
    case discardFolderMigration(planId: UUID)

    // MARK: Agenten

    /// Agenten sofort neu erkennen (Antwort nach Abschluss) → ``ServiceResult/agents(_:)``.
    case redetectAgents

    // MARK: Jobs und Freigaben

    /// Neuen Agentenjob anlegen (J2a: Auftrag > Projekt > global > Anbieterstandard) → ``ServiceResult/job(_:)``.
    case requestJob(JobRequestCommand)
    /// Hostlokale Details eines Jobs → ``ServiceResult/jobStatus(_:)``.
    case jobStatus(jobId: JobID)
    /// Freigabeanfrage eines Agenten beantworten. Wird wie eine iPhone-Entscheidung synchronisiert
    /// und beim nächsten Durchlauf an den Agenten weitergegeben.
    case answerApproval(approvalId: PendingApprovalID, decision: ApprovalDecisionKind, message: String?)
    /// Seit Protokoll 4 (SR-SEC-08): vollständiger Text einer gekürzten Freigabevorschau → ``ServiceResult/approvalPreview(_:)``.
    case fullApprovalPreview(approvalId: PendingApprovalID)
    /// Seit Protokoll 4 (SR-SEC-08): Entscheidung am ausführenden Mac. Bei gekürzter Vorschau ist `allow` nur mit
    /// `fullTextConfirmed == true` möglich (Volltext angezeigt und Lesen bestätigt).
    case answerApprovalOnHost(approvalId: PendingApprovalID, decision: ApprovalDecisionKind, message: String?, fullTextConfirmed: Bool)
    case cancelJob(jobId: JobID)
    case pauseJob(jobId: JobID)
    case resumeJob(jobId: JobID)
    /// Neuer Lauf für einen beendeten Job; `idempotencyKey` pro Benutzeraktion einmal erzeugen.
    case retryJob(jobId: JobID, idempotencyKey: IdempotencyKey)
    case reprioritizeJob(jobId: JobID, priority: Priority)
    /// Modell/Effort eines noch nicht gestarteten Jobs ausdrücklich ersetzen (A40).
    case replaceJobConfiguration(jobId: JobID, model: ModelSelection?, effort: EffortLevel?)
    /// Entscheidung zu einem verpassten Termin (K3, Nachholregel `ask`).
    case resolveMissedRun(jobId: JobID, runNow: Bool)
    /// Benutzer erwartet den Kontingent-Reset zu diesem Zeitpunkt (K2).
    case setExpectedQuotaReset(jobId: JobID, at: Date)
    /// Nach einem Dienstneustart verwaisten Agentenprozess ausdrücklich beenden.
    case terminateOrphanedProcess(jobId: JobID)
    /// Worktree eines Jobs entfernen (Branch bleibt erhalten).
    case removeWorktree(jobId: JobID)

    // MARK: Review und Integration (M1)

    /// Review mit hostlokalen Pfaden, Commits und Dateien → ``ServiceResult/reviewDetails(_:)``.
    case reviewDetails(reviewId: ReviewID)
    case approveReview(reviewId: ReviewID)
    case requestChanges(reviewId: ReviewID)
    case rejectReview(reviewId: ReviewID)
    /// Freigegebenes Review integrieren (Projektstrategie, Standard Squash) → ``ServiceResult/integration(_:)``.
    case integrateReview(reviewId: ReviewID)
    /// Integrierte Aufgabe als erledigt markieren; die Datei wandert danach in den done-Ordner.
    case markDone(workItemId: WorkItemID)

    // MARK: GitHub (M3, ADR-0016)

    case gitHubAvailability
    case setGitHubEnabled(projectId: ProjectID, enabled: Bool)
    /// Issues für den Import-Dialog → ``ServiceResult/gitHubIssues(_:)``.
    case gitHubIssues(projectId: ProjectID, state: GitHubIssueStateFilter)
    case linkGitHubIssue(workItemId: WorkItemID, issueNumber: Int)
    /// Issue als neue Aufgabe importieren → ``ServiceResult/workItem(_:)``.
    case importGitHubIssue(projectId: ProjectID, issueNumber: Int)
    case exportToGitHub(workItemId: WorkItemID)
    case resolveGitHubDivergence(conflictId: FileConflictID, acceptGitHub: Bool)
    /// Abgleich sofort (alle aktivierten Projekte oder eines).
    case syncGitHub(projectId: ProjectID?)

    // MARK: KI-Ausarbeitung mit Repo-Kontext (H4)

    /// Ausarbeitung am Mac anstoßen; läuft im Hintergrund → ``ServiceResult/macAIElaboration(_:)``.
    case requestMacAIElaboration(MacAIElaborationCommand)
    /// Stand einer Ausarbeitung inklusive Kontext-Manifest → ``ServiceResult/macAIElaboration(_:)``.
    case macAIElaborationStatus(requestId: AIRequestID)

    // MARK: Aufgaben (seit Protokoll 3, H1, F1, ADR-0012, ADR-0018)

    /// Notiz/Aufgabe anlegen (idempotent über `workItemId`) → ``ServiceResult/workItemSaved(_:)``.
    case createWorkItem(CreateWorkItemCommand)
    /// Titel, Text, Priorität, Labels, Abhängigkeiten ändern (optimistische Revision) → ``ServiceResult/workItemSaved(_:)``.
    case updateWorkItem(WorkItemEditCommand)
    /// Manueller Statuswechsel; abgelehnt bei aktivem Job oder Sperre (ADR-0012) → ``ServiceResult/workItemSaved(_:)``.
    case changeWorkItemStatus(workItemId: WorkItemID, expectedRevision: Int, status: WorkItemStatus)
    /// Projekt zuweisen (`nil` = zurück in die Inbox); nur ohne menschenlesbare ID → ``ServiceResult/workItemSaved(_:)``.
    case assignWorkItem(workItemId: WorkItemID, expectedRevision: Int, projectId: ProjectID?)
    /// Archivieren/Wiederherstellen (kein Statuswechsel) → ``ServiceResult/workItemSaved(_:)``.
    case setWorkItemArchived(workItemId: WorkItemID, expectedRevision: Int, archived: Bool)
    /// Typ ändern; nur bevor der Mac eine menschenlesbare ID vergeben hat → ``ServiceResult/workItemSaved(_:)``.
    case reclassifyWorkItem(workItemId: WorkItemID, expectedRevision: Int, type: WorkItemType)
    /// Kopie mit neuer UUID, ohne ID, Jobs und Verlauf (idempotent über `newWorkItemId`) → ``ServiceResult/workItemSaved(_:)``.
    case duplicateWorkItem(workItemId: WorkItemID, newWorkItemId: WorkItemID)
    /// Endgültig löschen – nur, wenn nie eine Datei/ID/Job entstand; sonst archivieren.
    case deleteWorkItem(workItemId: WorkItemID, expectedRevision: Int)

    // MARK: KI-Entwürfe (seit Protokoll 3, H3/H4)

    /// Entwurf übernehmen: aktualisiert Titel/Inhalt/Priorität der Aufgabe, startet nie einen Agenten.
    /// `contentIndex` wählt den strukturierten Entwurf; `nil` bei reinen Textversionen → ``ServiceResult/workItemSaved(_:)``.
    case acceptDraftVersion(draftId: DraftVersionID, contentIndex: Int?, expectedRevision: Int)
    /// Entwurf verwerfen; wird als Verlaufseintrag (synchronisiert) festgehalten, die Aufgabe bleibt unverändert.
    case rejectDraftVersion(draftId: DraftVersionID)

    // MARK: „Mit KI besprechen“ (seit Protokoll 4, H3)

    /// Gespräch speichern bzw. fortschreiben (Upsert über die ID: Nachrichten, Kontextumfang, Nutzung); wird
    /// synchronisiert → ``ServiceResult/conversationSaved(_:)``.
    case saveConversation(AIConversation)
    /// Vorschlag als Entwurfsversion (Quelle `ai`, Kanal `conversation`) anlegen und nur bei `accept` mit
    /// optimistischer Revisionsprüfung übernehmen; startet nie einen Agenten → ``ServiceResult/conversationDraft(_:)``.
    case appendConversationDraft(ConversationDraftCommand)

    // MARK: ADRs (seit Protokoll 3, F4, ADR-0018, ADR-0024)

    /// Neuen ADR-Entwurf anlegen (Status `proposed`, nicht committet) → ``ServiceResult/adrCreated(_:)``.
    case createADR(CreateADRCommand)
    /// Status ausdrücklich ändern (`accepted`, `deprecated`, `superseded` mit `supersededBy`); ändert nur
    /// das Frontmatter der betroffenen Datei(en), nie committet.
    case changeADRStatus(adrId: ADRID, expectedRevision: Int, status: ADRStatus, supersededBy: Int?)

    // MARK: Einstellungen (seit Protokoll 3, F2, J1, J2a, L1, M3)

    /// Projekteinstellungen ohne Ordnerstruktur; Modell/Stufe gegen die Fähigkeitsmatrix geprüft.
    case updateProjectSettings(ProjectSettingsCommand)
    /// Ob GitHub für ein Projekt aktiv ist → ``ServiceResult/gitHubProjectState(_:)``.
    case gitHubProjectState(projectId: ProjectID)
    /// Synchronisierte Benutzer-Standards (`GlobalSettings`).
    case updateGlobalSettings(GlobalSettingsCommand)
    /// Globale Modell-/Stufenwahl eines Agenten; `model == nil && effort == nil` entfernt sie.
    case setGlobalModelPreference(AgentModelChoice)
    /// Programmpfad eines Agenten festlegen (`nil` = automatische Suche); wirkt sofort per Neuerkennung
    /// → ``ServiceResult/serviceSettings(_:)``.
    case setAgentExecutablePath(providerId: ProviderID, path: String?)

    // MARK: Datenlöschung (seit Protokoll 3, Q1, A34)

    /// Vorschau mit Bestätigungstoken → ``ServiceResult/localDeletionPreview(_:)``.
    case prepareLocalDeletion(LocalDeletionKind)
    /// Löscht genau die Einträge der Vorschau; Datenbank wird geschlossen und leer neu geöffnet
    /// → ``ServiceResult/localDeletionReport(_:)``.
    case executeLocalDeletion(planId: UUID, confirmationToken: String)
    /// Vorschau der iCloud-Löschung → ``ServiceResult/cloudDeletionPreview(_:)``.
    case prepareCloudDeletion
    /// iCloud-Daten löschen (Zone); Sync bleibt danach pausiert, bis `recreateCloudZone`.
    case confirmCloudDeletion(planId: UUID, confirmationToken: String)
    /// Noch nicht von iCloud bestätigte Löschung erneut senden.
    case retryCloudDeletion

    /// Empfohlene Mindest-Wartezeit des Clients auf die Antwort. Lange Vorgänge (Scan, Sync,
    /// Integration, Agentenerkennung) antworten erst nach Abschluss.
    public var minimumTimeout: Duration {
        switch self {
        case .syncNow, .refreshScanner, .redetectAgents, .integrateReview, .applyFolderMigration,
             .syncGitHub, .importGitHubIssue, .exportToGitHub, .gitHubIssues, .resolveGitHubDivergence,
             .acknowledgeAccountChange, .recreateCloudZone, .submitProjectSetup, .setAgentExecutablePath,
             .executeLocalDeletion, .confirmCloudDeletion, .retryCloudDeletion:
            .seconds(180)
        case .addRootFolder, .removeRootFolder, .relinkProject, .reconcileProject, .proposeInstructions,
             .applyInstructionProposal, .previewFolderMigration, .requestJob, .cancelJob, .pauseJob, .resumeJob,
             .retryJob, .replaceJobConfiguration, .reviewDetails, .approveReview, .requestChanges, .rejectReview,
             .markDone, .removeWorktree, .gitHubAvailability, .linkGitHubIssue, .answerApproval, .answerApprovalOnHost,
             .fullApprovalPreview,
             .resolveFileConflict, .instructionProposals, .createWorkItem, .updateWorkItem, .changeWorkItemStatus,
             .assignWorkItem, .setWorkItemArchived, .reclassifyWorkItem, .duplicateWorkItem, .deleteWorkItem,
             .acceptDraftVersion, .rejectDraftVersion, .saveConversation, .appendConversationDraft, .createADR, .changeADRStatus, .updateProjectSettings,
             .gitHubProjectState, .updateGlobalSettings, .setGlobalModelPreference, .prepareLocalDeletion,
             .prepareCloudDeletion:
            .seconds(60)
        default:
            .seconds(5)
        }
    }
}

/// Betriebszustand des Agent Service.
public enum ServiceRunState: String, Codable, Sendable, Hashable, CaseIterable {
    case running
    case paused
}

/// Version des Dienst-Bundles (aus dessen Info.plist).
public struct ServiceVersion: Codable, Sendable, Hashable {
    public var shortVersion: String
    public var build: String

    public init(shortVersion: String, build: String) {
        self.shortVersion = shortVersion
        self.build = build
    }

    /// Liest `CFBundleShortVersionString` und `CFBundleVersion`; fehlende Werte bleiben leer statt erfunden zu werden.
    public init(bundle: Bundle) {
        self.shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        self.build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }
}

/// Gesundheitsstatus, wie ihn der laufende Dienst selbst meldet.
public struct ServiceHealth: Codable, Sendable, Hashable {
    public var serviceVersion: ServiceVersion
    public var protocolVersion: Int
    public var processIdentifier: Int32
    public var startedAt: Date
    /// Laufzeit in Sekunden zum Zeitpunkt der Antwort (monoton gemessen).
    public var uptimeSeconds: Double
    public var runState: ServiceRunState

    public init(
        serviceVersion: ServiceVersion,
        protocolVersion: Int = IPCProtocol.version,
        processIdentifier: Int32,
        startedAt: Date,
        uptimeSeconds: Double,
        runState: ServiceRunState
    ) {
        self.serviceVersion = serviceVersion
        self.protocolVersion = protocolVersion
        self.processIdentifier = processIdentifier
        self.startedAt = startedAt
        self.uptimeSeconds = uptimeSeconds
        self.runState = runState
    }
}

/// Funktion, die in diesem Dienstprozess grundsätzlich nicht verfügbar ist.
public enum ServiceFeature: String, Codable, Sendable, Hashable, CaseIterable {
    /// Kein CloudKit: unsignierter Build, Platzhalter-Team oder fehlender Container.
    case cloudSync
    /// Noch kein bestätigter Stammordner.
    case repositoryScanner
}

/// Antwort des Agent Service.
public enum ServiceResponse: Codable, Sendable, Hashable {
    case pong(ServiceVersion)
    case health(ServiceHealth)
    /// Ergebnis von pause/resume: der nun tatsächlich gültige Zustand.
    case runState(ServiceRunState)
    /// Der Dienst beendet sich unmittelbar nach dieser Antwort.
    case stopping
    /// Die Funktion ist in diesem Dienstprozess nicht verfügbar. Keine stille Erfolgsmeldung.
    case notAvailable(ServiceFeature)
    /// Anfrage mit inkompatibler Protokollversion abgelehnt.
    case protocolMismatch(serviceVersion: Int, clientVersion: Int)
    /// Abgelehnt oder fehlgeschlagen; für Menschen lesbare deutsche Beschreibung (ohne Geheimnisse).
    case failure(String)
    /// Übersicht für Menüleiste und Dashboard (seit Protokoll 2).
    case statusSummary(ServiceStatusSummary)
    /// Ergebnis eines Befehls (seit Protokoll 2).
    case result(ServiceResult)
}

/// Umschlag jeder Anfrage über XPC.
public struct ServiceRequestEnvelope: Codable, Sendable, Hashable {
    public var protocolVersion: Int
    public var request: ServiceRequest

    public init(request: ServiceRequest, protocolVersion: Int = IPCProtocol.version) {
        self.protocolVersion = protocolVersion
        self.request = request
    }
}

/// Umschlag jeder Antwort über XPC.
public struct ServiceResponseEnvelope: Codable, Sendable, Hashable {
    public var protocolVersion: Int
    public var response: ServiceResponse

    public init(response: ServiceResponse, protocolVersion: Int = IPCProtocol.version) {
        self.protocolVersion = protocolVersion
        self.response = response
    }
}

/// Dienstseitige Verarbeitung einer einzelnen Anfrage.
///
/// Asynchron: die XPC-Antwort wird erst nach Abschluss gesendet. Implementierungen müssen
/// threadsicher sein (Aufruf aus beliebigen Tasks, auch parallel).
public protocol ServiceRequestHandling: Sendable {
    func handle(_ request: ServiceRequest) async -> ServiceResponse
}

/// Prüft die Protokollversion und leitet passende Anfragen an den Handler weiter.
///
/// Clients älterer, noch unterstützter Versionen (``IPCProtocol/minimumSupportedVersion``) werden bedient;
/// die Antwort trägt dann ihre Versionsnummer, damit ihre eigene Versionsprüfung besteht. Ältere Clients
/// können nur ihre Befehle senden und erhalten deshalb nur Ergebnisarten, die sie kennen.
public enum ServiceRequestDispatcher {
    public static func respond(
        to envelope: ServiceRequestEnvelope,
        using handler: some ServiceRequestHandling
    ) async -> ServiceResponseEnvelope {
        guard IPCProtocol.supports(clientVersion: envelope.protocolVersion) else {
            return ServiceResponseEnvelope(
                response: .protocolMismatch(serviceVersion: IPCProtocol.version, clientVersion: envelope.protocolVersion)
            )
        }
        return ServiceResponseEnvelope(response: await handler.handle(envelope.request), protocolVersion: envelope.protocolVersion)
    }
}
