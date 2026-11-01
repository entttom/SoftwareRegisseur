import Foundation
import Observation

/// Progress of the iPhone/iPad onboarding across launches.
public protocol OnboardingProgressStoring: AnyObject {
    var isOnboardingCompleted: Bool { get set }
    /// Last step shown, so a relaunch continues there.
    var onboardingStep: String? { get set }
}

public final class UserDefaultsOnboardingProgress: OnboardingProgressStoring {
    public static let completedKey = "onboarding.mobile.completed"
    public static let stepKey = "onboarding.mobile.step"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isOnboardingCompleted: Bool {
        get { defaults.bool(forKey: Self.completedKey) }
        set { defaults.set(newValue, forKey: Self.completedKey) }
    }

    public var onboardingStep: String? {
        get { defaults.string(forKey: Self.stepKey) }
        set { defaults.set(newValue, forKey: Self.stepKey) }
    }
}

public final class InMemoryOnboardingProgress: OnboardingProgressStoring {
    public var isOnboardingCompleted: Bool
    public var onboardingStep: String?

    public init(completed: Bool = false, step: String? = nil) {
        isOnboardingCompleted = completed
        onboardingStep = step
    }
}

/// Onboarding on the first launch of the iPhone/iPad app: Willkommen → iCloud → Mac → Diktat →
/// KI-Schlüssel → Zusammenfassung (spec B, H2, I, N1, P).
///
/// No step asks for a system permission (spec Q4): microphone and speech recognition are requested
/// only when a dictation starts, through `PermissionFlow` and its own explanation screen. Every step
/// therefore offers „Weiter“ and, after the first, „Zurück“; the choices made here have defaults and
/// can be changed later in „Einstellungen“, where the onboarding can also be reopened.
@MainActor
@Observable
public final class MobileOnboarding {
    public enum Step: String, CaseIterable, Identifiable, Sendable {
        case welcome
        case sync
        case mac
        case dictation
        case keys
        case summary

        public var id: Self { self }

        /// Steps the summary links back to with „Ändern“.
        public static let revisitable: [Step] = [.sync, .mac, .dictation, .keys]
    }

    public enum StepState: Equatable, Sendable {
        case done
        case current
        case upcoming
    }

    public private(set) var step: Step
    public private(set) var isCompleted: Bool
    /// Direction of the last change, for the page transition.
    public private(set) var movedForward = true

    @ObservationIgnored private let progress: any OnboardingProgressStoring

    public init(progress: any OnboardingProgressStoring) {
        self.progress = progress
        isCompleted = progress.isOnboardingCompleted
        step = progress.isOnboardingCompleted ? .summary : progress.onboardingStep.flatMap(Step.init(rawValue:)) ?? .welcome
    }

    public var needsPresentation: Bool { !isCompleted }

    public var canGoBack: Bool { step != .welcome }

    public var isLastStep: Bool { step == .summary }

    /// 1-based position for „Schritt n von m“.
    public var position: Int { (Step.allCases.firstIndex(of: step) ?? 0) + 1 }

    public var stepCount: Int { Step.allCases.count }

    public func state(of candidate: Step) -> StepState {
        guard let current = Step.allCases.firstIndex(of: step), let index = Step.allCases.firstIndex(of: candidate) else {
            return .upcoming
        }
        if isCompleted || index < current { return .done }
        return index == current ? .current : .upcoming
    }

    /// „Weiter“; on the summary „Los geht’s“ finishes the onboarding.
    public func advance() {
        guard !isCompleted else { return }
        guard let index = Step.allCases.firstIndex(of: step), index + 1 < Step.allCases.count else {
            finish()
            return
        }
        move(to: Step.allCases[index + 1], forward: true)
    }

    public func goBack() {
        guard !isCompleted, canGoBack, let index = Step.allCases.firstIndex(of: step) else { return }
        move(to: Step.allCases[index - 1], forward: false)
    }

    /// „Ändern“ in the summary.
    public func revisit(_ target: Step) {
        guard !isCompleted, step == .summary, Step.revisitable.contains(target) else { return }
        move(to: target, forward: false)
    }

    public func finish() {
        progress.isOnboardingCompleted = true
        progress.onboardingStep = nil
        isCompleted = true
        step = .summary
    }

    /// „Einrichtung erneut ansehen“ in „Einstellungen“: starts again at the welcome page.
    public func reopen() {
        guard isCompleted else { return }
        progress.isOnboardingCompleted = false
        isCompleted = false
        move(to: .welcome, forward: true)
    }

    private func move(to next: Step, forward: Bool) {
        movedForward = forward
        step = next
        progress.onboardingStep = next.rawValue
    }
}
