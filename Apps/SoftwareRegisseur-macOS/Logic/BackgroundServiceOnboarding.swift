import Foundation
import Observation

/// Ergebnis der Registrierung des Hintergrunddienstes über `SMAppService` (ADR-0020), unabhängig vom Framework,
/// damit der Ablauf ohne Systemzugriff testbar ist.
enum BackgroundServiceRegistrationResult: Equatable, Sendable {
    case enabled
    /// Registriert, aber in den Systemeinstellungen unter „Anmeldeobjekte“ noch nicht freigegeben.
    case requiresApproval
    case notRegistered
    /// Dienst im App-Bundle nicht gefunden (z. B. unsignierter Build).
    case notFound
    /// Dem Build fehlt der Name der launchd-Konfiguration.
    case notConfigured
    /// Systemfehler beim Registrieren (geheimnisfreie Systemmeldung).
    case failed(String)
}

/// Status der Menüleisten-App als Anmeldeobjekt (`SMAppService.mainApp`, D3, A01).
enum AppLoginItemText {
    static func status(_ result: BackgroundServiceRegistrationResult) -> String {
        switch result {
        case .enabled:
            String(localized: "Aktiviert: Das Menüleistensymbol erscheint nach jeder Anmeldung, ohne Hauptfenster.")
        case .requiresApproval:
            String(localized: "Registriert, aber noch nicht freigegeben. Bitte in den Systemeinstellungen unter „Anmeldeobjekte“ freigeben.")
        case .notRegistered:
            String(localized: "Nicht aktiviert: Nach der Anmeldung läuft nur der Hintergrunddienst; das Menüleistensymbol erscheint erst, wenn Sie die App öffnen.")
        case .notFound, .notConfigured:
            String(localized: "Die App wurde nicht als Anmeldeobjekt gefunden. Sie muss signiert sein und im Ordner „Programme“ liegen.")
        case let .failed(message):
            String(localized: "Fehler: \(message)")
        }
    }
}

/// Systemzugriff für den Einrichtungsschritt. Die echte Umsetzung ist `LoginAgentController`; Bildschirmfotos und
/// Tests verwenden Ersatzobjekte, die nie registrieren.
@MainActor
protocol BackgroundServiceRegistering: AnyObject {
    /// Registriert den Dienst sofort (Start jetzt und bei jeder Anmeldung) und liefert den Status danach.
    func registerBackgroundService() -> BackgroundServiceRegistrationResult
    /// Liest den aktuellen Status, ohne etwas zu ändern.
    func backgroundServiceStatus() -> BackgroundServiceRegistrationResult
    /// Öffnet Systemeinstellungen › Allgemein › Anmeldeobjekte.
    func openLoginItemsSettings()
}

/// Persistiertes Merkmal „Einrichtung des Hintergrunddienstes abgeschlossen“.
protocol OnboardingFlagStoring: AnyObject {
    var isBackgroundServiceOnboardingCompleted: Bool { get set }
}

final class UserDefaultsOnboardingFlags: OnboardingFlagStoring {
    static let completedKey = "onboarding.backgroundService.completed"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isBackgroundServiceOnboardingCompleted: Bool {
        get { defaults.bool(forKey: Self.completedKey) }
        set { defaults.set(newValue, forKey: Self.completedKey) }
    }
}

final class InMemoryOnboardingFlags: OnboardingFlagStoring {
    var isBackgroundServiceOnboardingCompleted: Bool
    /// Fortschritt des Einrichtungsassistenten (`SetupProgressStoring`).
    var isSetupAssistantCompleted: Bool
    var setupAssistantStep: String?

    init(completed: Bool = false, setupCompleted: Bool? = nil) {
        isBackgroundServiceOnboardingCompleted = completed
        isSetupAssistantCompleted = setupCompleted ?? completed
    }
}

/// Erster Start: Erklärung des Hintergrunddienstes und des Starts bei der Anmeldung (D3, Q4, App Review 5.1.1(iv)).
///
/// Regeln: Der Erklärschritt hat genau eine neutrale Aktion („Weiter“), die die Registrierung sofort auslöst;
/// es gibt dort weder „Später“ noch Überspringen oder Schließen. Erst nach dem Systemschritt gibt es
/// „Anmeldeobjekte öffnen“, „Erneut versuchen“ bzw. „Fertig“; Abschalten liegt in den Einstellungen.
/// Solange die Einrichtung nicht abgeschlossen ist, zeigen Hauptfenster und Menüleiste nur diesen Ablauf.
@MainActor
@Observable
final class BackgroundServiceOnboarding {
    enum Step: Equatable {
        case explanation
        case registering
        /// Registriert, Freigabe in den Systemeinstellungen fehlt.
        case requiresApproval
        case failed(String)
        case finished
    }

    enum Action: Equatable, CaseIterable {
        /// „Weiter“ – löst die Registrierung sofort aus.
        case continueToRegistration
        case openLoginItems
        case recheck
        case retry
        case finish
    }

    private(set) var step: Step

    @ObservationIgnored private let registrar: any BackgroundServiceRegistering
    @ObservationIgnored private let flags: any OnboardingFlagStoring

    init(registrar: any BackgroundServiceRegistering, flags: any OnboardingFlagStoring) {
        self.registrar = registrar
        self.flags = flags
        step = flags.isBackgroundServiceOnboardingCompleted ? .finished : .explanation
    }

    /// Solange `true`, verdeckt der Ablauf jede andere Oberfläche (Hauptfenster, Menüleiste, Sprünge aus Menüs).
    var needsPresentation: Bool { step != .finished }

    /// Auf dem Erklärschritt darf das Fenster nicht geschlossen werden (kein Aufschieben vor der Systemaktion).
    var blocksDismissal: Bool { step == .explanation || step == .registering }

    /// Aktionen des aktuellen Schritts in Anzeigereihenfolge; die erste ist die Hauptaktion.
    var availableActions: [Action] {
        switch step {
        case .explanation: [.continueToRegistration]
        case .registering, .finished: []
        case .requiresApproval: [.openLoginItems, .recheck, .finish]
        case .failed: [.retry, .finish]
        }
    }

    func title(for action: Action) -> String {
        switch action {
        case .continueToRegistration: String(localized: "Weiter")
        case .openLoginItems: String(localized: "Anmeldeobjekte öffnen")
        case .recheck: String(localized: "Erneut prüfen")
        case .retry: String(localized: "Erneut versuchen")
        case .finish:
            step == .requiresApproval ? String(localized: "Fertig") : String(localized: "Ohne Hintergrunddienst fortfahren")
        }
    }

    /// Führt eine Aktion aus; Aktionen, die der aktuelle Schritt nicht anbietet, werden ignoriert.
    func perform(_ action: Action) {
        guard availableActions.contains(action) else { return }
        switch action {
        case .continueToRegistration, .retry:
            step = .registering
            apply(registrar.registerBackgroundService())
        case .openLoginItems:
            registrar.openLoginItemsSettings()
        case .recheck:
            let status = registrar.backgroundServiceStatus()
            if status != .requiresApproval { apply(status) }
        case .finish:
            complete()
        }
    }

    private func apply(_ result: BackgroundServiceRegistrationResult) {
        switch result {
        case .enabled:
            complete()
        case .requiresApproval:
            // Der Systemschritt ist erfolgt: beim nächsten Start nicht erneut fragen, sondern Einstellungen anbieten.
            flags.isBackgroundServiceOnboardingCompleted = true
            step = .requiresApproval
        case .notRegistered:
            step = .failed(String(localized: "Der Hintergrunddienst ist nicht registriert. Bitte versuchen Sie es erneut."))
        case .notFound:
            step = .failed(String(localized: "Der Hintergrunddienst wurde im App-Bundle nicht gefunden. Die App muss signiert sein und aus dem Programme-Ordner gestartet werden."))
        case .notConfigured:
            step = .failed(String(localized: "Diesem Build fehlt die Konfiguration des Hintergrunddienstes (launchd-Plist). Bitte installieren Sie eine signierte Version."))
        case let .failed(detail):
            step = .failed(String(localized: "Der Hintergrunddienst konnte nicht registriert werden: \(detail)"))
        }
    }

    private func complete() {
        flags.isBackgroundServiceOnboardingCompleted = true
        step = .finished
    }
}
