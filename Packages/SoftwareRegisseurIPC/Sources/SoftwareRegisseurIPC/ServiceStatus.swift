import Foundation
import SoftwareRegisseurDomain

/// Übersicht für Menüleiste und Dashboard (Pflichtenheft D1). Jede Zahl stammt aus einer echten
/// Prüfung im Dienst; nichts wird geschätzt oder „grün“ angenommen.
public struct ServiceStatusSummary: Codable, Sendable, Hashable {
    public var generatedAt: Date
    public var serviceVersion: ServiceVersion
    public var protocolVersion: Int
    public var runState: ServiceRunState
    /// „Mac bereit / pausiert / eingeschränkt“ aus Sicht des Dienstes. „Offline“ kann nur die UI
    /// feststellen (Dienst nicht erreichbar).
    public var macState: MacState
    public var hostId: HostID?
    public var hostName: String
    public var startedAt: Date
    public var sync: SyncSummary
    /// Je Agentenanbieter: Erkennung und aktive Läufe auf diesem Mac.
    public var agents: [AgentProviderSummary]
    public var queue: QueueSummary
    public var workspace: WorkspaceSummary
    /// Deutsche Hinweise, die Aufmerksamkeit brauchen (Stammordner fehlt, iCloud-Account gewechselt …).
    public var problems: [String]

    public init(generatedAt: Date, serviceVersion: ServiceVersion, protocolVersion: Int = IPCProtocol.version,
                runState: ServiceRunState, macState: MacState, hostId: HostID?, hostName: String, startedAt: Date,
                sync: SyncSummary, agents: [AgentProviderSummary], queue: QueueSummary, workspace: WorkspaceSummary,
                problems: [String]) {
        self.generatedAt = generatedAt
        self.serviceVersion = serviceVersion
        self.protocolVersion = protocolVersion
        self.runState = runState
        self.macState = macState
        self.hostId = hostId
        self.hostName = hostName
        self.startedAt = startedAt
        self.sync = sync
        self.agents = agents
        self.queue = queue
        self.workspace = workspace
        self.problems = problems
    }

    /// Zustand des Macs als Ausführungshost.
    public enum MacState: String, Codable, Sendable, Hashable {
        /// Dienst läuft, nimmt Jobs an.
        case ready
        /// Vom Benutzer pausiert: keine neuen Starts.
        case paused
        /// Dienst läuft, aber etwas Wesentliches fehlt (z. B. kein Stammordner, kein einsatzbereiter Agent).
        case degraded
        /// Dienst startet noch (Datenbank, Wiederherstellung).
        case starting
    }

    /// Anzahl aktiver Läufe aller Anbieter.
    public var activeAgentCount: Int { agents.reduce(0) { $0 + $1.activeJobs } }
}

public struct SyncSummary: Codable, Sendable, Hashable {
    public enum State: String, Codable, Sendable, Hashable {
        /// CloudKit in diesem Build nicht verfügbar (siehe `unavailableReason`).
        case unavailable
        case idle
        case syncing
        /// Wegen iCloud-Account oder gelöschter Zone pausiert; Entscheidung nötig.
        case paused
        /// Letzter Lauf fehlgeschlagen; nächster Versuch mit Backoff.
        case failed
    }

    public enum AccountState: String, Codable, Sendable, Hashable {
        case unknown, available, signedOut, switched, temporarilyUnavailable
    }

    public var state: State
    public var unavailableReason: String?
    public var accountState: AccountState
    public var lastSuccessfulFetch: Date?
    public var lastSuccessfulSend: Date?
    public var pendingChanges: Int
    public var openConflicts: Int
    public var lastError: String?
    /// Deutsche Hinweise der Sync-Schicht (Account, Zone, Konflikte, blockierte Geheimnisse …).
    public var attention: [String]
    public var retryNotBefore: Date?
    /// Vom Benutzer ausgelöste Löschung der iCloud-Daten (A34, seit Protokoll 3). Solange gesetzt, ist der
    /// Sync pausiert: `deleted` → „Wieder mit iCloud synchronisieren“ (`recreateCloudZone`), `pending` →
    /// `retryCloudDeletion`.
    public var cloudDataDeletion: CloudDataDeletionState?

    /// Zustand einer vom Benutzer ausgelösten iCloud-Löschung.
    public enum CloudDataDeletionState: String, Codable, Sendable, Hashable {
        /// Von iCloud bestätigt gelöscht.
        case deleted
        /// Bestätigt, aber noch nicht bei iCloud angekommen (z. B. offline).
        case pending
    }

    public init(state: State, unavailableReason: String? = nil, accountState: AccountState = .unknown,
                lastSuccessfulFetch: Date? = nil, lastSuccessfulSend: Date? = nil, pendingChanges: Int = 0,
                openConflicts: Int = 0, lastError: String? = nil, attention: [String] = [], retryNotBefore: Date? = nil,
                cloudDataDeletion: CloudDataDeletionState? = nil) {
        self.state = state
        self.unavailableReason = unavailableReason
        self.accountState = accountState
        self.lastSuccessfulFetch = lastSuccessfulFetch
        self.lastSuccessfulSend = lastSuccessfulSend
        self.pendingChanges = pendingChanges
        self.openConflicts = openConflicts
        self.lastError = lastError
        self.attention = attention
        self.retryNotBefore = retryNotBefore
        self.cloudDataDeletion = cloudDataDeletion
    }

    /// Letzter erfolgreicher Kontakt (Abruf oder Senden).
    public var lastSync: Date? {
        [lastSuccessfulFetch, lastSuccessfulSend].compactMap { $0 }.max()
    }
}

public struct AgentProviderSummary: Codable, Sendable, Hashable {
    public var providerId: ProviderID
    public var displayName: String
    public var installed: Bool
    public var authenticated: Bool
    /// Nur „einsatzbereit“, wenn die Erkennung es tatsächlich belegt (J1).
    public var ready: Bool
    public var version: String?
    public var checkedAt: Date?
    public var diagnostic: String?
    /// Aktive Läufe auf diesem Mac (zugelassen, startend, laufend, wartet auf Freigabe).
    public var activeJobs: Int

    public init(providerId: ProviderID, displayName: String, installed: Bool, authenticated: Bool, ready: Bool,
                version: String?, checkedAt: Date?, diagnostic: String?, activeJobs: Int) {
        self.providerId = providerId
        self.displayName = displayName
        self.installed = installed
        self.authenticated = authenticated
        self.ready = ready
        self.version = version
        self.checkedAt = checkedAt
        self.diagnostic = diagnostic
        self.activeJobs = activeJobs
    }
}

public struct QueueSummary: Codable, Sendable, Hashable {
    /// Angefordert, noch nicht vom Mac übernommen (`requested`, `pendingMac`).
    public var waiting: Int
    /// Übernommen und wartend auf Startzeit, Limit oder Kontingent (`scheduled`, `waiting_quota`).
    public var scheduled: Int
    /// Frühester geplanter Start eines wartenden Jobs.
    public var nextPlannedStart: Date?
    public var waitingQuota: Int
    public var waitingApproval: Int
    public var openApprovals: Int
    public var paused: Int
    /// Aufgaben im Status `blocked` (u. a. `needs_configuration`).
    public var blocked: Int
    /// Aufgaben im Status `failed`.
    public var failed: Int
    /// Aufgaben im Status `review`.
    public var reviewsPending: Int
    /// Vom Dienst gemeldete Start-Hindernisse (deutsch), je Job.
    public var admissionBlocks: [JobID: String]

    public init(waiting: Int = 0, scheduled: Int = 0, nextPlannedStart: Date? = nil, waitingQuota: Int = 0, waitingApproval: Int = 0,
                openApprovals: Int = 0, paused: Int = 0, blocked: Int = 0, failed: Int = 0, reviewsPending: Int = 0,
                admissionBlocks: [JobID: String] = [:]) {
        self.waiting = waiting
        self.scheduled = scheduled
        self.nextPlannedStart = nextPlannedStart
        self.waitingQuota = waitingQuota
        self.waitingApproval = waitingApproval
        self.openApprovals = openApprovals
        self.paused = paused
        self.blocked = blocked
        self.failed = failed
        self.reviewsPending = reviewsPending
        self.admissionBlocks = admissionBlocks
    }
}

public struct WorkspaceSummary: Codable, Sendable, Hashable {
    public var rootFolders: [String]
    public var projectsReady: Int
    public var projectsUnavailable: Int
    public var projectsNeedingAttention: Int
    public var projectsPendingSetup: Int
    public var lastScanAt: Date?
    public var lastScanError: String?
    public var isScanning: Bool
    public var openFileConflicts: Int
    public var pendingInstructionProposals: Int
    public var pendingAIElaborations: Int
    public var gitHubAvailable: Bool?

    public init(rootFolders: [String] = [], projectsReady: Int = 0, projectsUnavailable: Int = 0, projectsNeedingAttention: Int = 0,
                projectsPendingSetup: Int = 0, lastScanAt: Date? = nil, lastScanError: String? = nil, isScanning: Bool = false,
                openFileConflicts: Int = 0, pendingInstructionProposals: Int = 0, pendingAIElaborations: Int = 0,
                gitHubAvailable: Bool? = nil) {
        self.rootFolders = rootFolders
        self.projectsReady = projectsReady
        self.projectsUnavailable = projectsUnavailable
        self.projectsNeedingAttention = projectsNeedingAttention
        self.projectsPendingSetup = projectsPendingSetup
        self.lastScanAt = lastScanAt
        self.lastScanError = lastScanError
        self.isScanning = isScanning
        self.openFileConflicts = openFileConflicts
        self.pendingInstructionProposals = pendingInstructionProposals
        self.pendingAIElaborations = pendingAIElaborations
        self.gitHubAvailable = gitHubAvailable
    }
}
