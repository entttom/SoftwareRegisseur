import SwiftUI
import SoftwareRegisseurIPC

/// Texte und Symbole für den Dienststatus. Grün/„läuft“ nur nach echter Antwort des Dienstes (D1).
extension ServiceConnectionState {
    var symbolName: String {
        switch self {
        case .checking: "circle.dotted"
        case let .reachable(health): health.runState == .paused ? "pause.circle" : "checkmark.circle"
        case .unreachable: "exclamationmark.triangle"
        case .stoppedByUser: "stop.circle"
        case .misconfigured: "xmark.octagon"
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .checking: "Dienststatus wird geprüft …"
        case let .reachable(health): health.runState == .paused ? "Dienst pausiert" : "Dienst läuft"
        case .unreachable: "Dienst nicht erreichbar"
        case .stoppedByUser: "Dienst gestoppt"
        case .misconfigured: "Konfigurationsfehler"
        }
    }

    var detail: LocalizedStringResource? {
        switch self {
        case .checking:
            return nil
        case let .reachable(health):
            let uptime = Duration.seconds(health.uptimeSeconds)
                .formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
            return "Version \(health.serviceVersion.shortVersion) (\(health.serviceVersion.build)) · Laufzeit \(uptime)"
        case let .unreachable(error):
            switch error {
            case .connectionFailed:
                return "Keine Verbindung. Der Hintergrunddienst ist nicht aktiviert, nicht freigegeben oder die App ist nicht mit dem eigenen Team signiert."
            case .timedOut:
                return "Der Dienst hat nicht rechtzeitig geantwortet."
            case let .protocolMismatch(serviceVersion, clientVersion):
                return "Dienst und App sprechen unterschiedliche Protokollversionen (Dienst \(serviceVersion), App \(clientVersion)). Dienst stoppen und neu starten."
            }
        case .stoppedByUser:
            return "Er startet wieder bei der nächsten Anmeldung, beim nächsten Start dieser App oder über „Dienst starten“."
        case .misconfigured:
            return "Die App-Group-Kennung fehlt in der Info.plist. Config/Local.xcconfig prüfen und neu bauen."
        }
    }

    var tint: Color {
        switch self {
        case .checking: .secondary
        case let .reachable(health): health.runState == .paused ? .orange : .green
        case .unreachable, .misconfigured: .red
        case .stoppedByUser: .secondary
        }
    }

    var isReachable: Bool {
        if case .reachable = self { return true }
        return false
    }

    var runState: ServiceRunState? {
        if case let .reachable(health) = self { return health.runState }
        return nil
    }

    /// Menüleisten-Symbol: das App-Logo, solange nichts Aufmerksamkeit braucht; sonst das Statussymbol (D1).
    var menuBarImage: Image {
        switch self {
        case .checking:
            Image(.menuBarIcon)
        case let .reachable(health) where health.runState != .paused:
            Image(.menuBarIcon)
        default:
            Image(systemName: symbolName)
        }
    }
}

/// Zeile mit Symbol, Titel und Detail des Dienststatus.
struct ServiceStatusRow: View {
    @Environment(ServiceMonitor.self) private var monitor

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: monitor.state.symbolName)
                .font(.title2)
                .foregroundStyle(monitor.state.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(monitor.state.title)
                    .font(.headline)
                if let detail = monitor.state.detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let lastCheck = monitor.lastCheck {
                    Text("Zuletzt geprüft: \(lastCheck, style: .time)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if let message = monitor.commandMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Steuerbefehle, die nur angeboten werden, wenn sie im aktuellen Zustand tatsächlich wirken.
struct ServiceControls: View {
    @Environment(ServiceMonitor.self) private var monitor

    var body: some View {
        HStack {
            switch monitor.state {
            case let .reachable(health):
                if health.runState == .paused {
                    Button("Dienst fortsetzen") { Task { await monitor.resume() } }
                } else {
                    Button("Dienst pausieren") { Task { await monitor.pause() } }
                }
                Button("Status prüfen") { Task { await monitor.refresh() } }
            case .unreachable:
                Button("Erneut prüfen") { Task { await monitor.refresh() } }
            case .stoppedByUser:
                Button("Dienst starten") { Task { await monitor.start() } }
            case .checking, .misconfigured:
                EmptyView()
            }
        }
        .disabled(monitor.isBusy)
    }
}

/// Registrierung als Login-Agent und Start der Menüleisten-App bei der Anmeldung, jeweils mit echtem SMAppService-Status.
struct LoginAgentSection: View {
    @Environment(LoginAgentController.self) private var loginAgent
    @Environment(ServiceMonitor.self) private var monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if loginAgent.isConfigured {
                Toggle("Hintergrunddienst bei Anmeldung starten", isOn: Binding(
                    get: { loginAgent.isRegistered },
                    set: { register in
                        loginAgent.setRegistered(register)
                        Task { await monitor.start() }
                    }
                ))
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if loginAgent.status == .requiresApproval {
                    Button("Anmeldeobjekte öffnen") { loginAgent.openLoginItemsSettings() }
                }
            } else {
                Text("Der Name der launchd-Konfiguration fehlt in der Info.plist. Config/Local.xcconfig prüfen und neu bauen.")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Toggle("Menüleisten-App beim Anmelden öffnen", isOn: Binding(
                get: { loginAgent.opensAppAtLogin },
                set: { loginAgent.setOpensAppAtLogin($0) }
            ))
            Text(AppLoginItemText.status(LoginAgentController.result(for: loginAgent.appStatus)))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if loginAgent.appStatus == .requiresApproval {
                Button("Anmeldeobjekte öffnen") { loginAgent.openLoginItemsSettings() }
            }
            if let error = loginAgent.lastError {
                Text("Fehler: \(error)")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { loginAgent.refresh() }
    }

    private var statusText: LocalizedStringResource {
        switch loginAgent.status {
        case .enabled:
            "Aktiviert: Der Dienst startet bei jeder Anmeldung."
        case .requiresApproval:
            "Registriert, aber noch nicht freigegeben. Bitte in den Systemeinstellungen unter „Anmeldeobjekte“ freigeben."
        case .notRegistered:
            "Nicht aktiviert: Der Dienst startet nicht automatisch."
        case .notFound:
            "Dienst nicht gefunden. Die App muss signiert sein und die launchd-Konfiguration im App-Bundle enthalten."
        @unknown default:
            "Unbekannter Status der Anmeldeobjekte."
        }
    }
}
