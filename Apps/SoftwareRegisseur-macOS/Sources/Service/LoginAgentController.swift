import Foundation
import Observation
import ServiceManagement

/// Registrierung des Agent Service als LaunchAgent über `SMAppService.agent(plistName:)` (ADR-0020) und der
/// Menüleisten-App als Anmeldeobjekt über `SMAppService.mainApp` (D3, A01).
///
/// Der Status wird immer direkt von `SMAppService` gelesen, nie angenommen.
/// Hinweis: SMAppService verlangt eine signierte App; unsignierte Builds melden Fehler.
@MainActor
@Observable
final class LoginAgentController {
    private(set) var status: SMAppService.Status = .notFound
    /// Start der Menüleisten-App bei der Anmeldung.
    private(set) var appStatus: SMAppService.Status = .notRegistered
    private(set) var lastError: String?

    @ObservationIgnored private let service: SMAppService?
    @ObservationIgnored private let app = SMAppService.mainApp

    init(configuration: AppConfiguration) {
        service = configuration.agentPlistName.map { SMAppService.agent(plistName: $0) }
        refresh()
    }

    var isConfigured: Bool { service != nil }

    /// Registriert (ja) oder deregistriert (nein). Registrierung startet den Dienst sofort und bei jeder Anmeldung;
    /// Deregistrierung beendet einen laufenden Dienst.
    var isRegistered: Bool {
        status == .enabled || status == .requiresApproval
    }

    var opensAppAtLogin: Bool {
        appStatus == .enabled || appStatus == .requiresApproval
    }

    func refresh() {
        appStatus = app.status
        guard let service else {
            status = .notFound
            return
        }
        status = service.status
    }

    /// Menüleisten-App bei der Anmeldung öffnen (ja) oder nicht (nein). Wirkt erst bei der nächsten Anmeldung.
    func setOpensAppAtLogin(_ open: Bool) {
        lastError = nil
        do {
            if open {
                try app.register()
            } else {
                try app.unregister()
            }
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func setRegistered(_ register: Bool) {
        guard let service else { return }
        lastError = nil
        do {
            if register {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    /// Nach `requiresApproval`: Systemeinstellungen öffnen statt erneut zu fragen (Q4).
    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Einrichtung beim ersten Start (BackgroundServiceOnboarding): „Weiter“ registriert sofort.
extension LoginAgentController: BackgroundServiceRegistering {
    func registerBackgroundService() -> BackgroundServiceRegistrationResult {
        guard let service else { return .notConfigured }
        lastError = nil
        do {
            try service.register()
        } catch {
            refresh()
            // Ohne Freigabe meldet das System einen Fehler, obwohl der Dienst registriert ist.
            if status == .requiresApproval {
                openAppAtLoginAfterConsent()
                return .requiresApproval
            }
            lastError = error.localizedDescription
            return .failed(error.localizedDescription)
        }
        refresh()
        if status == .enabled || status == .requiresApproval { openAppAtLoginAfterConsent() }
        return Self.result(for: status)
    }

    /// Die Zustimmung in der Einrichtung gilt auch für das Menüleistensymbol (D3: Default nach Zustimmung aktiv;
    /// der Erklärtext nennt es). Abschaltbar in den Einstellungen unter „Dienst“.
    private func openAppAtLoginAfterConsent() {
        guard app.status != .enabled else { return }
        do {
            try app.register()
        } catch {
            lastError = error.localizedDescription
        }
        appStatus = app.status
    }

    func backgroundServiceStatus() -> BackgroundServiceRegistrationResult {
        guard service != nil else { return .notConfigured }
        refresh()
        return Self.result(for: status)
    }

    static func result(for status: SMAppService.Status) -> BackgroundServiceRegistrationResult {
        switch status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }
}
