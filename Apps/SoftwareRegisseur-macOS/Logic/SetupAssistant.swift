import Foundation
import Observation

/// Fortschritt des Einrichtungsassistenten über App-Starts hinweg.
protocol SetupProgressStoring: AnyObject {
    var isSetupAssistantCompleted: Bool { get set }
    /// Zuletzt angezeigter Schritt nach dem Hintergrunddienst (Fortsetzen nach Beenden).
    var setupAssistantStep: String? { get set }
}

extension UserDefaultsOnboardingFlags: SetupProgressStoring {
    static let setupCompletedKey = "onboarding.setupAssistant.completed"
    static let setupStepKey = "onboarding.setupAssistant.step"

    var isSetupAssistantCompleted: Bool {
        get { defaults.bool(forKey: Self.setupCompletedKey) }
        set { defaults.set(newValue, forKey: Self.setupCompletedKey) }
    }

    var setupAssistantStep: String? {
        get { defaults.string(forKey: Self.setupStepKey) }
        set { defaults.set(newValue, forKey: Self.setupStepKey) }
    }
}

extension InMemoryOnboardingFlags: SetupProgressStoring {}

/// Einrichtungsassistent beim ersten Start: Willkommen → Hintergrunddienst → Git-Stammordner → Coding-Agenten →
/// iCloud & GitHub → Zusammenfassung (D3, E1, J1/J2, ADR-0006).
///
/// Q4 / App Review 5.1.1(iv): Vor und auf dem Dienstschritt gibt es nur „Weiter“, kein Zurück, Überspringen oder
/// Schließen; „Weiter“ auf dem Dienstschritt registriert sofort (``BackgroundServiceOnboarding``). Erst die Schritte
/// danach lassen sich überspringen, zurückblättern und später in den Einstellungen erneut öffnen.
@MainActor
@Observable
final class SetupAssistant {
    enum Step: String, CaseIterable, Identifiable, Sendable {
        case welcome
        case backgroundService
        case rootFolders
        case agents
        case connections
        case summary

        var id: Self { self }

        /// Schritte, die nach dem Dienst wieder geöffnet und fortgesetzt werden können.
        static let resumable: [Step] = [.rootFolders, .agents, .connections, .summary]
    }

    enum StepState: Equatable, Sendable {
        case done
        case current
        case upcoming
    }

    private(set) var step: Step
    private(set) var isCompleted: Bool
    /// Richtung des letzten Wechsels für die Übergangsanimation.
    private(set) var movedForward = true

    @ObservationIgnored let service: BackgroundServiceOnboarding
    @ObservationIgnored private let progress: any SetupProgressStoring

    init(service: BackgroundServiceOnboarding, progress: any SetupProgressStoring) {
        self.service = service
        self.progress = progress
        if progress.isSetupAssistantCompleted, !service.needsPresentation {
            isCompleted = true
            step = .summary
        } else if service.needsPresentation {
            isCompleted = false
            // Nach „Weiter“ auf dem Dienstschritt (Freigabe fehlt, Fehler) direkt dort fortsetzen.
            step = service.step == .explanation ? .welcome : .backgroundService
        } else {
            isCompleted = false
            step = progress.setupAssistantStep.flatMap(Step.init(rawValue:)).flatMap { Step.resumable.contains($0) ? $0 : nil }
                ?? .rootFolders
        }
    }

    /// Solange `true`, zeigen Hauptfenster und Menüleiste den Assistenten statt der normalen Oberfläche.
    var needsPresentation: Bool { !isCompleted }

    /// Willkommen und Dienstschritt dürfen nicht geschlossen werden (kein Aufschieben vor der Systemaktion).
    var blocksDismissal: Bool {
        switch step {
        case .welcome: true
        case .backgroundService: service.blocksDismissal
        default: false
        }
    }

    /// Die Menüleiste zeigt bis zum Ende des Dienstschritts nur die Einrichtung des Dienstes.
    var isInServicePhase: Bool { needsPresentation && (step == .welcome || step == .backgroundService) }

    var canGoBack: Bool {
        switch step {
        case .agents, .connections, .summary: true
        case .welcome, .backgroundService, .rootFolders: false
        }
    }

    /// Optionale Schritte bieten „Später festlegen“ an; vor dem Systemschritt nie.
    var canSkip: Bool {
        switch step {
        case .rootFolders, .agents, .connections: true
        case .welcome, .backgroundService, .summary: false
        }
    }

    func state(of candidate: Step) -> StepState {
        guard let current = Step.allCases.firstIndex(of: step), let index = Step.allCases.firstIndex(of: candidate) else {
            return .upcoming
        }
        if isCompleted || index < current { return .done }
        return index == current ? .current : .upcoming
    }

    /// Hauptaktion des Schritts. Auf dem Dienstschritt ist das die Aktion des Dienstablaufs.
    func advance() {
        switch step {
        case .welcome:
            move(to: .backgroundService)
        case .backgroundService:
            // Nur über `performService` – dort entscheidet das Registrierungsergebnis.
            break
        case .rootFolders:
            move(to: .agents)
        case .agents:
            move(to: .connections)
        case .connections:
            move(to: .summary)
        case .summary:
            finish()
        }
    }

    /// „Später festlegen“: wie Weiter, aber nur auf optionalen Schritten.
    func skip() {
        guard canSkip else { return }
        advance()
    }

    func goBack() {
        guard canGoBack, let index = Step.allCases.firstIndex(of: step) else { return }
        move(to: Step.allCases[index - 1], forward: false)
    }

    /// Aus der Zusammenfassung zu einem früheren optionalen Schritt springen.
    func revisit(_ target: Step) {
        guard !isCompleted, step != target, Step.resumable.contains(step), Step.resumable.contains(target) else { return }
        let forward = (Step.allCases.firstIndex(of: target) ?? 0) > (Step.allCases.firstIndex(of: step) ?? 0)
        move(to: target, forward: forward)
    }

    /// Aktionen des Dienstschritts. Sobald der Dienst fertig eingerichtet ist, geht es zu den Stammordnern.
    func performService(_ action: BackgroundServiceOnboarding.Action) {
        guard step == .welcome || step == .backgroundService else { return }
        // Die kompakte Menüleiste zeigt die Erklärung schon auf dem Willkommensschritt.
        if step == .welcome, action != .continueToRegistration { return }
        service.perform(action)
        if !service.needsPresentation {
            move(to: .rootFolders)
        } else if step == .welcome {
            move(to: .backgroundService)
        }
    }

    /// Beschriftung der Dienstaktionen im Assistenten: „Fertig“ mitten im Ablauf wäre missverständlich.
    func serviceTitle(for action: BackgroundServiceOnboarding.Action) -> String {
        if action == .finish, service.step == .requiresApproval { return String(localized: "Weiter") }
        return service.title(for: action)
    }

    func finish() {
        progress.isSetupAssistantCompleted = true
        progress.setupAssistantStep = nil
        isCompleted = true
        step = .summary
    }

    /// Aus den Einstellungen: Assistent ab den Stammordnern erneut zeigen (der Dienst bleibt eingerichtet).
    func reopen() {
        guard !service.needsPresentation else { return }
        progress.isSetupAssistantCompleted = false
        isCompleted = false
        move(to: .rootFolders)
    }

    private func move(to next: Step, forward: Bool = true) {
        movedForward = forward
        step = next
        if Step.resumable.contains(next) { progress.setupAssistantStep = next.rawValue }
    }
}
