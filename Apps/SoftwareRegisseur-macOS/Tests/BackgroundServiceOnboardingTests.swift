import Foundation
import Testing

/// Ersatz für `SMAppService`; zählt Aufrufe.
@MainActor
final class RecordingRegistrar: BackgroundServiceRegistering {
    var registerResults: [BackgroundServiceRegistrationResult]
    var status: BackgroundServiceRegistrationResult
    private(set) var registerCalls = 0
    private(set) var openLoginItemsCalls = 0

    init(register: [BackgroundServiceRegistrationResult], status: BackgroundServiceRegistrationResult = .notRegistered) {
        registerResults = register
        self.status = status
    }

    func registerBackgroundService() -> BackgroundServiceRegistrationResult {
        registerCalls += 1
        let result = registerResults.isEmpty ? status : registerResults.removeFirst()
        status = result
        return result
    }

    func backgroundServiceStatus() -> BackgroundServiceRegistrationResult { status }
    func openLoginItemsSettings() { openLoginItemsCalls += 1 }
}

/// Erster Start (D3, Q4, App Review 5.1.1(iv)): nur „Weiter“, „Weiter“ registriert sofort, kein Überspringen.
@MainActor
@Suite("Einrichtung des Hintergrunddienstes beim ersten Start")
struct BackgroundServiceOnboardingTests {
    @Test func explanationStepOffersOnlyANeutralWeiter() {
        let registrar = RecordingRegistrar(register: [.enabled])
        let onboarding = BackgroundServiceOnboarding(registrar: registrar, flags: InMemoryOnboardingFlags())
        #expect(onboarding.step == .explanation)
        #expect(onboarding.needsPresentation)
        #expect(onboarding.blocksDismissal)
        #expect(onboarding.availableActions == [.continueToRegistration])
        let titles = onboarding.availableActions.map { onboarding.title(for: $0) }
        #expect(titles == ["Weiter"])
        for forbidden in ["Später", "Nicht jetzt", "Überspringen", "Erlauben", "Zugriff", "Aktivieren", "Schließen"] {
            #expect(!titles.contains { $0.localizedCaseInsensitiveContains(forbidden) })
        }
        #expect(registrar.registerCalls == 0)
    }

    @Test func weiterRegistersImmediatelyAndEnabledFinishes() {
        let registrar = RecordingRegistrar(register: [.enabled])
        let flags = InMemoryOnboardingFlags()
        let onboarding = BackgroundServiceOnboarding(registrar: registrar, flags: flags)
        onboarding.perform(.continueToRegistration)
        #expect(registrar.registerCalls == 1)
        #expect(onboarding.step == .finished)
        #expect(!onboarding.needsPresentation)
        #expect(flags.isBackgroundServiceOnboardingCompleted)
    }

    @Test func explanationStepHasNoSkipOrPostponePath() {
        let registrar = RecordingRegistrar(register: [.enabled])
        let flags = InMemoryOnboardingFlags()
        let onboarding = BackgroundServiceOnboarding(registrar: registrar, flags: flags)
        for action in BackgroundServiceOnboarding.Action.allCases where action != .continueToRegistration {
            onboarding.perform(action)
            #expect(onboarding.step == .explanation, "\(action) darf den Erklärschritt nicht verlassen")
        }
        #expect(registrar.registerCalls == 0)
        #expect(registrar.openLoginItemsCalls == 0)
        #expect(!flags.isBackgroundServiceOnboardingCompleted)
        #expect(onboarding.needsPresentation)
    }

    @Test func requiresApprovalExplainsAndOffersLoginItemsAfterTheSystemStep() {
        let registrar = RecordingRegistrar(register: [.requiresApproval], status: .requiresApproval)
        let flags = InMemoryOnboardingFlags()
        let onboarding = BackgroundServiceOnboarding(registrar: registrar, flags: flags)
        onboarding.perform(.continueToRegistration)
        #expect(registrar.registerCalls == 1)
        #expect(onboarding.step == .requiresApproval)
        #expect(!onboarding.blocksDismissal)
        #expect(onboarding.availableActions == [.openLoginItems, .recheck, .finish])
        #expect(onboarding.title(for: .openLoginItems) == "Anmeldeobjekte öffnen")
        // Systemschritt erfolgt: beim nächsten Start nicht erneut fragen.
        #expect(flags.isBackgroundServiceOnboardingCompleted)

        onboarding.perform(.openLoginItems)
        #expect(registrar.openLoginItemsCalls == 1)
        onboarding.perform(.recheck)
        #expect(onboarding.step == .requiresApproval)

        registrar.status = .enabled
        onboarding.perform(.recheck)
        #expect(onboarding.step == .finished)
        #expect(registrar.registerCalls == 1, "Erneut prüfen fragt nicht erneut")

        let nextLaunch = BackgroundServiceOnboarding(registrar: registrar, flags: flags)
        #expect(nextLaunch.step == .finished)
    }

    @Test func requiresApprovalCanBeFinishedAndLaterChangedInSettings() {
        let registrar = RecordingRegistrar(register: [.requiresApproval], status: .requiresApproval)
        let onboarding = BackgroundServiceOnboarding(registrar: registrar, flags: InMemoryOnboardingFlags())
        onboarding.perform(.continueToRegistration)
        #expect(onboarding.title(for: .finish) == "Fertig")
        onboarding.perform(.finish)
        #expect(onboarding.step == .finished)
    }

    @Test func errorExplainsInGermanAndRetryRegistersAgain() {
        let registrar = RecordingRegistrar(register: [.failed("Vorgang nicht erlaubt"), .enabled])
        let flags = InMemoryOnboardingFlags()
        let onboarding = BackgroundServiceOnboarding(registrar: registrar, flags: flags)
        onboarding.perform(.continueToRegistration)
        guard case let .failed(message) = onboarding.step else {
            Issue.record("Fehlerschritt erwartet")
            return
        }
        #expect(message.contains("konnte nicht registriert werden"))
        #expect(message.contains("Vorgang nicht erlaubt"))
        #expect(onboarding.availableActions.first == .retry)
        #expect(!flags.isBackgroundServiceOnboardingCompleted)

        onboarding.perform(.retry)
        #expect(registrar.registerCalls == 2)
        #expect(onboarding.step == .finished)
    }

    @Test func missingConfigurationIsExplainedNotHidden() {
        let registrar = RecordingRegistrar(register: [.notConfigured])
        let onboarding = BackgroundServiceOnboarding(registrar: registrar, flags: InMemoryOnboardingFlags())
        onboarding.perform(.continueToRegistration)
        guard case let .failed(message) = onboarding.step else {
            Issue.record("Fehlerschritt erwartet")
            return
        }
        #expect(message.contains("launchd"))
        #expect(onboarding.title(for: .finish) == "Ohne Hintergrunddienst fortfahren")
    }

    @Test func completedSetupIsNotShownAgainAndNeverRegistersOnLaunch() {
        let registrar = RecordingRegistrar(register: [.enabled])
        let onboarding = BackgroundServiceOnboarding(registrar: registrar, flags: InMemoryOnboardingFlags(completed: true))
        #expect(onboarding.step == .finished)
        #expect(!onboarding.needsPresentation)
        #expect(onboarding.availableActions.isEmpty)
        #expect(registrar.registerCalls == 0)
    }

    @Test func flagPersistsInUserDefaults() throws {
        let suite = "onboarding-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let flags = UserDefaultsOnboardingFlags(defaults: defaults)
        #expect(!flags.isBackgroundServiceOnboardingCompleted)
        flags.isBackgroundServiceOnboardingCompleted = true
        #expect(UserDefaultsOnboardingFlags(defaults: defaults).isBackgroundServiceOnboardingCompleted)
    }
}

/// Menüleisten-App als Anmeldeobjekt (D3, A01): jeder SMAppService-Zustand hat einen ehrlichen deutschen Text.
@Suite("Menüleisten-App beim Anmelden öffnen")
struct AppLoginItemTextTests {
    @Test func everyStateExplainsWhatHappensAfterLogin() {
        #expect(AppLoginItemText.status(.enabled).contains("nach jeder Anmeldung"))
        #expect(AppLoginItemText.status(.requiresApproval).contains("Anmeldeobjekte"))
        #expect(AppLoginItemText.status(.notRegistered).contains("nur der Hintergrunddienst"))
        #expect(AppLoginItemText.status(.notFound).contains("signiert"))
        #expect(AppLoginItemText.status(.notConfigured) == AppLoginItemText.status(.notFound))
        #expect(AppLoginItemText.status(.failed("Vorgang nicht erlaubt")) == "Fehler: Vorgang nicht erlaubt")
    }

    @Test func onlyEnabledClaimsTheIconAppears() {
        let others: [BackgroundServiceRegistrationResult] = [.requiresApproval, .notRegistered, .notFound, .notConfigured, .failed("x")]
        for result in others {
            #expect(!AppLoginItemText.status(result).hasPrefix("Aktiviert"))
        }
    }
}

@Suite("Dienst nach einem Update neu registrieren (Spike S3)")
struct ServiceReregistrationPolicyTests {
    @Test func reregistersOnceAfterAnUpdateWhenEnabled() {
        // Registriert von einer Version vor diesem Fix (kein gespeicherter Build) oder einem älteren Build.
        #expect(ServiceReregistrationPolicy.needsReregistration(registeredBuild: nil, currentBuild: "3", isEnabled: true))
        #expect(ServiceReregistrationPolicy.needsReregistration(registeredBuild: "2", currentBuild: "3", isEnabled: true))
        // Danach nicht mehr.
        #expect(!ServiceReregistrationPolicy.needsReregistration(registeredBuild: "3", currentBuild: "3", isEnabled: true))
    }

    @Test func neverRegistersAServiceTheUserDidNotEnable() {
        #expect(!ServiceReregistrationPolicy.needsReregistration(registeredBuild: nil, currentBuild: "3", isEnabled: false))
        #expect(!ServiceReregistrationPolicy.needsReregistration(registeredBuild: "2", currentBuild: "3", isEnabled: false))
        // Ohne lesbare Build-Nummer lieber nichts tun.
        #expect(!ServiceReregistrationPolicy.needsReregistration(registeredBuild: "2", currentBuild: "", isEnabled: true))
    }
}
