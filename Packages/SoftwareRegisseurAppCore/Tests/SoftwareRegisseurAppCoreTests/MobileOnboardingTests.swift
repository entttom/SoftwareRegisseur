import Foundation
import Testing
import SoftwareRegisseurAppCore

@Suite("Onboarding on iPhone and iPad")
@MainActor
struct MobileOnboardingTests {
    @Test func firstLaunchStartsWithWelcomeAndWalksThroughEveryStep() {
        let progress = InMemoryOnboardingProgress()
        let onboarding = MobileOnboarding(progress: progress)
        #expect(onboarding.needsPresentation)
        #expect(onboarding.step == .welcome)
        #expect(!onboarding.canGoBack)
        #expect(onboarding.position == 1)
        #expect(onboarding.stepCount == 6)

        var visited: [MobileOnboarding.Step] = [onboarding.step]
        while !onboarding.isLastStep {
            onboarding.advance()
            visited.append(onboarding.step)
        }
        #expect(visited == MobileOnboarding.Step.allCases)
        #expect(onboarding.needsPresentation)
        #expect(progress.onboardingStep == "summary")
    }

    @Test func backGoesOneStepAndWelcomeHasNoBack() {
        let onboarding = MobileOnboarding(progress: InMemoryOnboardingProgress())
        onboarding.goBack()
        #expect(onboarding.step == .welcome)
        onboarding.advance()
        onboarding.advance()
        #expect(onboarding.step == .mac)
        #expect(onboarding.canGoBack)
        onboarding.goBack()
        #expect(onboarding.step == .sync)
        #expect(!onboarding.movedForward)
    }

    @Test func sidebarAndProgressStatesFollowTheCurrentStep() {
        let onboarding = MobileOnboarding(progress: InMemoryOnboardingProgress())
        onboarding.advance()
        onboarding.advance()
        #expect(onboarding.state(of: .welcome) == .done)
        #expect(onboarding.state(of: .sync) == .done)
        #expect(onboarding.state(of: .mac) == .current)
        #expect(onboarding.state(of: .summary) == .upcoming)
        #expect(onboarding.position == 3)
    }

    @Test func summaryRevisitsOnlyEditableStepsAndFinishPersists() {
        let progress = InMemoryOnboardingProgress()
        let onboarding = MobileOnboarding(progress: progress)
        // „Ändern“ exists only on the summary.
        onboarding.revisit(.keys)
        #expect(onboarding.step == .welcome)
        while !onboarding.isLastStep { onboarding.advance() }
        onboarding.revisit(.welcome)
        #expect(onboarding.step == .summary)
        onboarding.revisit(.dictation)
        #expect(onboarding.step == .dictation)
        while !onboarding.isLastStep { onboarding.advance() }

        onboarding.advance()
        #expect(!onboarding.needsPresentation)
        #expect(progress.isOnboardingCompleted)
        #expect(progress.onboardingStep == nil)
        #expect(MobileOnboarding.Step.allCases.allSatisfy { onboarding.state(of: $0) == .done })
        // Finished: navigation does nothing.
        onboarding.goBack()
        onboarding.advance()
        #expect(onboarding.step == .summary)
        #expect(!MobileOnboarding(progress: progress).needsPresentation)
    }

    @Test func relaunchContinuesAtTheLastStep() {
        let progress = InMemoryOnboardingProgress(step: "dictation")
        #expect(MobileOnboarding(progress: progress).step == .dictation)
        let unknown = InMemoryOnboardingProgress(step: "removedStep")
        #expect(MobileOnboarding(progress: unknown).step == .welcome)
    }

    @Test func reopenFromSettingsStartsAtWelcome() {
        let progress = InMemoryOnboardingProgress(completed: true)
        let onboarding = MobileOnboarding(progress: progress)
        #expect(!onboarding.needsPresentation)
        onboarding.reopen()
        #expect(onboarding.needsPresentation)
        #expect(onboarding.step == .welcome)
        #expect(!progress.isOnboardingCompleted)
    }

    @Test func userDefaultsStoreRoundTrips() throws {
        let suite = "MobileOnboardingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsOnboardingProgress(defaults: defaults)
        let onboarding = MobileOnboarding(progress: store)
        onboarding.advance()
        #expect(MobileOnboarding(progress: UserDefaultsOnboardingProgress(defaults: defaults)).step == .sync)
        onboarding.finish()
        #expect(!MobileOnboarding(progress: UserDefaultsOnboardingProgress(defaults: defaults)).needsPresentation)
    }
}
