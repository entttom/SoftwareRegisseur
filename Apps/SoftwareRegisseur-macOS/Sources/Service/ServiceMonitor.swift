import Foundation
import Observation
import SoftwareRegisseurIPC

/// Transport zum Agent Service. In der App immer `ServiceXPCClient`; Vorschauen nutzen einen Ersatz.
protocol ServiceSending: Sendable {
    func send(_ request: ServiceRequest) async throws(ServiceClientError) -> ServiceResponse
}

extension ServiceXPCClient: ServiceSending {}

/// Verbindungszustand zum Agent Service, ausschließlich aus echten XPC-Antworten abgeleitet.
enum ServiceConnectionState: Equatable {
    /// Noch keine Antwort erhalten.
    case checking
    case reachable(ServiceHealth)
    case unreachable(ServiceClientError)
    /// Vom Nutzer in dieser Sitzung gestoppt; es wird nicht automatisch neu verbunden,
    /// weil jede Anfrage den registrierten Dienst über launchd wieder starten würde.
    case stoppedByUser
    /// Info.plist enthält keine gültige App-Group-Kennung.
    case misconfigured(ServiceEndpointError)
}

/// Fragt den Agent Service regelmäßig per XPC ab (Gesundheit und Statusübersicht, IPC-README: 5–10 s)
/// und stellt den Transport für Befehle bereit.
@MainActor
@Observable
final class ServiceMonitor {
    private(set) var state: ServiceConnectionState = .checking
    /// Letzte Statusübersicht (Menüleiste, Dashboard). Bleibt nach Verbindungsverlust als „zuletzt bekannt“ erhalten.
    private(set) var summary: ServiceStatusSummary?
    private(set) var lastCheck: Date?
    /// Letzte Rückmeldung auf einen Steuerbefehl, die nicht in `state` steckt (z. B. Dienstfehler).
    private(set) var commandMessage: String?
    private(set) var isBusy = false

    @ObservationIgnored private let client: (any ServiceSending)?
    @ObservationIgnored private var xpcClient: ServiceXPCClient?
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private var monitorTask: Task<Void, Never>?

    init(configuration: AppConfiguration, pollInterval: Duration = .seconds(8)) {
        self.pollInterval = pollInterval
        switch configuration.endpoint {
        case let .success(endpoint):
            // SR-SEC-05: nur der eingebettete Dienst (gleiches Team und Signing-Identifier).
            let xpc = ServiceXPCClient(endpoint: endpoint, peerRequirement: ServicePeerPolicy.forClient(bundle: .main).requirement)
            client = xpc
            xpcClient = xpc
        case let .failure(error):
            client = nil
            state = .misconfigured(error)
        }
    }

    /// Für Vorschauen und Bildschirmfotos mit einem Ersatztransport.
    init(client: any ServiceSending, pollInterval: Duration = .seconds(8)) {
        self.client = client
        self.pollInterval = pollInterval
    }

    var isConfigured: Bool { client != nil }

    /// `true`/`false` nach einer echten Antwort bzw. einem Fehler; `nil` solange unbekannt.
    var isReachable: Bool? {
        switch state {
        case .checking: nil
        case .reachable: true
        case .unreachable, .stoppedByUser, .misconfigured: false
        }
    }

    /// Statusübersicht nur, solange der Dienst erreichbar ist (sonst nicht als aktuell ausgeben).
    var currentSummary: ServiceStatusSummary? {
        isReachable == true ? summary : nil
    }

    /// Startet die periodische Statusabfrage (idempotent).
    func startMonitoring() {
        guard monitorTask == nil, client != nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.state != .stoppedByUser {
                    await self.refresh()
                }
                try? await Task.sleep(for: self.pollInterval)
            }
        }
    }

    func refresh() async {
        guard let client else { return }
        do {
            let response = try await client.send(.health)
            apply(response)
            if case .reachable = state {
                let summaryResponse = try await client.send(.statusSummary)
                if case let .statusSummary(summary) = summaryResponse {
                    self.summary = summary
                }
            }
        } catch {
            state = .unreachable(error)
        }
        lastCheck = .now
    }

    /// Sendet einen Befehl. Verbindungsfehler fließen in den Zustand ein; ein gestoppter Dienst wird
    /// durch eine ausdrückliche Benutzeraktion über launchd wieder gestartet.
    func send(_ request: ServiceRequest) async -> Result<ServiceResponse, ServiceClientError> {
        guard let client else { return .failure(.connectionFailed("misconfigured")) }
        do {
            let response = try await client.send(request)
            if state == .stoppedByUser { state = .checking }
            return .success(response)
        } catch {
            state = .unreachable(error)
            return .failure(error)
        }
    }

    func pause() async { await command(.pause) }
    func resume() async { await command(.resume) }

    func stop() async {
        await command(.stop)
    }

    /// Hebt den Stopp auf. Die nächste Anfrage startet den registrierten Dienst über launchd.
    func start() async {
        state = .checking
        await refresh()
    }

    private func command(_ request: ServiceRequest) async {
        guard let client, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        commandMessage = nil
        do {
            let response = try await client.send(request)
            apply(response)
            if case .runState = response {
                await refresh()
            }
        } catch {
            state = .unreachable(error)
        }
    }

    private func apply(_ response: ServiceResponse) {
        switch response {
        case let .health(health):
            state = .reachable(health)
        case let .runState(runState):
            if case var .reachable(health) = state {
                health.runState = runState
                state = .reachable(health)
            }
        case .stopping:
            state = .stoppedByUser
            summary = nil
            let xpc = xpcClient
            Task { await xpc?.disconnect() }
        case let .statusSummary(summary):
            self.summary = summary
        case .pong:
            break
        case let .failure(message):
            commandMessage = message
        case let .notAvailable(feature):
            commandMessage = String(localized: "Diese Funktion ist im Dienst nicht verfügbar: \(feature.localizedName)")
        case let .protocolMismatch(serviceVersion, clientVersion):
            state = .unreachable(.protocolMismatch(serviceVersion: serviceVersion, clientVersion: clientVersion))
        case let .result(result):
            switch result {
            case let .done(message?), let .accepted(message?):
                commandMessage = message
            default:
                break
            }
        }
    }
}
