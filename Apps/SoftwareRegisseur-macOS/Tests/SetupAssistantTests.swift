import Foundation
import Testing

/// Einrichtungsassistent (D3, E1, J1/J2, Q4): vor und auf dem Dienstschritt kein Zurück/Überspringen/Schließen,
/// „Weiter“ registriert sofort; danach optionale Schritte, Fortsetzen nach Neustart und erneutes Öffnen.
@MainActor
@Suite("Einrichtungsassistent beim ersten Start")
struct SetupAssistantTests {
    private func makeAssistant(register: [BackgroundServiceRegistrationResult] = [.enabled],
                               flags: InMemoryOnboardingFlags = InMemoryOnboardingFlags())
        -> (SetupAssistant, RecordingRegistrar, InMemoryOnboardingFlags) {
        let registrar = RecordingRegistrar(register: register)
        let service = BackgroundServiceOnboarding(registrar: registrar, flags: flags)
        return (SetupAssistant(service: service, progress: flags), registrar, flags)
    }

    @Test func firstLaunchStartsWithWelcomeWithoutAnyWayToPostpone() {
        let (setup, registrar, _) = makeAssistant()
        #expect(setup.step == .welcome)
        #expect(setup.needsPresentation)
        #expect(setup.isInServicePhase)
        #expect(setup.blocksDismissal)
        #expect(!setup.canGoBack)
        #expect(!setup.canSkip)
        setup.skip()
        #expect(setup.step == .welcome)
        #expect(registrar.registerCalls == 0)
    }

    @Test func serviceStepOffersOnlyWeiterAndRegistersImmediately() {
        let (setup, registrar, flags) = makeAssistant(register: [.enabled])
        setup.advance()
        #expect(setup.step == .backgroundService)
        #expect(setup.blocksDismissal)
        #expect(!setup.canGoBack)
        #expect(!setup.canSkip)
        #expect(setup.service.availableActions == [.continueToRegistration])
        #expect(setup.serviceTitle(for: .continueToRegistration) == "Weiter")
        // „Weiter“ des Assistenten umgeht die Registrierung nicht.
        setup.advance()
        #expect(setup.step == .backgroundService)
        #expect(registrar.registerCalls == 0)

        setup.performService(.continueToRegistration)
        #expect(registrar.registerCalls == 1)
        #expect(setup.step == .rootFolders)
        #expect(!setup.isInServicePhase)
        #expect(!setup.blocksDismissal)
        #expect(flags.isBackgroundServiceOnboardingCompleted)
        #expect(!flags.isSetupAssistantCompleted)
        #expect(flags.setupAssistantStep == "rootFolders")
    }

    /// Kompakte Menüleiste: Die Erklärung erscheint schon auf dem Willkommensschritt; „Weiter“ registriert sofort.
    @Test func menuBarWeiterOnWelcomeRegistersImmediately() {
        let (setup, registrar, _) = makeAssistant(register: [.enabled])
        setup.performService(.finish)
        #expect(registrar.registerCalls == 0)
        setup.performService(.continueToRegistration)
        #expect(registrar.registerCalls == 1)
        #expect(setup.step == .rootFolders)
    }

    @Test func approvalStepContinuesWithNeutralWeiterAfterSystemStep() {
        let (setup, registrar, _) = makeAssistant(register: [.requiresApproval])
        setup.advance()
        setup.performService(.continueToRegistration)
        #expect(setup.step == .backgroundService)
        #expect(setup.service.step == .requiresApproval)
        #expect(!setup.blocksDismissal)
        #expect(setup.serviceTitle(for: .finish) == "Weiter")
        setup.performService(.openLoginItems)
        #expect(registrar.openLoginItemsCalls == 1)
        setup.performService(.finish)
        #expect(setup.step == .rootFolders)
    }

    @Test func failedRegistrationCanContinueWithoutService() {
        let (setup, _, _) = makeAssistant(register: [.notFound])
        setup.advance()
        setup.performService(.continueToRegistration)
        guard case .failed = setup.service.step else {
            Issue.record("Fehlerschritt erwartet")
            return
        }
        #expect(setup.serviceTitle(for: .finish) == "Ohne Hintergrunddienst fortfahren")
        setup.performService(.finish)
        #expect(setup.step == .rootFolders)
    }

    @Test func optionalStepsCanBeSkippedAndRevisited() {
        let (setup, _, flags) = makeAssistant()
        setup.advance()
        setup.performService(.continueToRegistration)
        #expect(setup.canSkip)
        #expect(!setup.canGoBack)
        setup.skip()
        #expect(setup.step == .agents)
        #expect(setup.canGoBack)
        setup.goBack()
        #expect(setup.step == .rootFolders)
        #expect(!setup.movedForward)
        setup.advance()
        setup.advance()
        #expect(setup.step == .connections)
        setup.advance()
        #expect(setup.step == .summary)
        #expect(!setup.canSkip)
        setup.revisit(.rootFolders)
        #expect(setup.step == .rootFolders)
        #expect(flags.setupAssistantStep == "rootFolders")
        // Zum Dienst führt kein Weg zurück.
        setup.revisit(.backgroundService)
        #expect(setup.step == .rootFolders)
    }

    @Test func sidebarStatesFollowTheCurrentStep() {
        let (setup, _, _) = makeAssistant()
        setup.advance()
        setup.performService(.continueToRegistration)
        setup.advance()
        #expect(setup.state(of: .welcome) == .done)
        #expect(setup.state(of: .rootFolders) == .done)
        #expect(setup.state(of: .agents) == .current)
        #expect(setup.state(of: .summary) == .upcoming)
    }

    @Test func finishingPersistsAndHidesTheAssistant() {
        let (setup, _, flags) = makeAssistant()
        setup.advance()
        setup.performService(.continueToRegistration)
        for _ in 0..<4 { setup.advance() }
        #expect(!setup.needsPresentation)
        #expect(flags.isSetupAssistantCompleted)
        #expect(flags.setupAssistantStep == nil)
        #expect(SetupAssistant.Step.allCases.allSatisfy { setup.state(of: $0) == .done })

        let (relaunched, _, _) = makeAssistant(flags: flags)
        #expect(!relaunched.needsPresentation)
    }

    @Test func relaunchResumesAtTheLastStepAfterTheService() {
        let flags = InMemoryOnboardingFlags(completed: true, setupCompleted: false)
        flags.setupAssistantStep = "connections"
        let (setup, registrar, _) = makeAssistant(flags: flags)
        #expect(setup.step == .connections)
        #expect(setup.needsPresentation)
        #expect(!setup.isInServicePhase)
        #expect(registrar.registerCalls == 0)
    }

    /// Bestehende Installation mit erledigtem Dienstschritt: der Assistent beginnt bei den Stammordnern.
    @Test func existingServiceSetupStartsAtRootFolders() {
        let flags = InMemoryOnboardingFlags(completed: true, setupCompleted: false)
        flags.setupAssistantStep = "welcome"
        let (setup, _, _) = makeAssistant(flags: flags)
        #expect(setup.step == .rootFolders)
    }

    /// Nach Neustart auf der Freigabe-Seite (Dienstflag gesetzt, Freigabe fehlt) direkt bei den Stammordnern;
    /// unvollständige Dienstregistrierung ohne Flag beginnt erneut mit der Erklärung.
    @Test func serviceNotCompletedAlwaysStartsBeforeTheSystemStep() {
        let flags = InMemoryOnboardingFlags(completed: false, setupCompleted: true)
        let (setup, _, _) = makeAssistant(flags: flags)
        #expect(setup.step == .welcome)
        #expect(setup.needsPresentation)
    }

    @Test func reopenFromSettingsStartsAtRootFoldersWithoutTouchingTheService() {
        let flags = InMemoryOnboardingFlags(completed: true, setupCompleted: true)
        let (setup, registrar, _) = makeAssistant(flags: flags)
        #expect(!setup.needsPresentation)
        setup.reopen()
        #expect(setup.needsPresentation)
        #expect(setup.step == .rootFolders)
        #expect(!flags.isSetupAssistantCompleted)
        #expect(registrar.registerCalls == 0)
    }
}
