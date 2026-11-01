import Foundation
import Observation

/// System permissions the iPhone app asks for (spec H2, Q4). Notifications are deliberately absent:
/// the app never asks for push permission (ADR-0011).
public enum PermissionKind: String, Hashable, Sendable, CaseIterable {
    case microphone
    case speechRecognition
}

public enum PermissionStatus: Hashable, Sendable {
    case notDetermined
    case granted
    case denied
    /// Blocked by device management / parental controls; treated like a denial (settings link, no re-ask).
    case restricted
}

/// Reads and requests system permissions. The app implements it with AVAudioApplication / SFSpeechRecognizer.
public protocol PermissionAuthorizing: Sendable {
    func status(of kind: PermissionKind) -> PermissionStatus
    /// Shows the system prompt. Must only be called directly after the user tapped „Weiter“.
    func request(_ kind: PermissionKind) async -> PermissionStatus
}

/// Steps of the permission flow (spec Q4, App Review 5.1.1(iv)).
public enum PermissionStep: Hashable, Sendable {
    case idle
    /// Own explanation screen. The only action is the neutral „Weiter“; there is no skip, later or close.
    case explaining(PermissionKind)
    /// „Weiter“ was tapped and the system prompt is on screen.
    case requesting(PermissionKind)
    /// The permission was refused (now or earlier). Shows what does not work and a link to Settings;
    /// the app never asks again.
    case denied(PermissionKind)
    /// Every required permission is granted; the feature may start.
    case granted
}

/// Actions a screen in a given step may offer. Used by the view so the screen cannot show more than this.
public enum PermissionScreenAction: Hashable, Sendable {
    case continueToSystemPrompt
    case openSettings
    case close
}

/// State machine for permission explanation screens (spec Q4).
///
/// - Every path that needs a permission calls `begin()`; there is no other way to reach `.granted`.
/// - A not yet decided permission always shows `.explaining` first, whose only action is „Weiter“.
/// - „Weiter“ calls the system prompt immediately (no intermediate step).
/// - After a denial the flow shows `.denied` with a Settings link and never requests again.
@MainActor
@Observable
public final class PermissionFlow {
    public let required: [PermissionKind]
    public private(set) var step: PermissionStep = .idle
    /// Number of system prompts shown by this flow (tests, diagnostics).
    public private(set) var systemPromptCount = 0

    private let authorizer: any PermissionAuthorizing

    public init(required: [PermissionKind], authorizer: any PermissionAuthorizing) {
        self.required = required
        self.authorizer = authorizer
    }

    public var availableActions: Set<PermissionScreenAction> {
        switch step {
        case .explaining: [.continueToSystemPrompt]
        case .requesting, .granted, .idle: []
        case .denied: [.openSettings, .close]
        }
    }

    /// Evaluates the current permissions and moves to the next required step.
    public func begin() {
        for kind in required {
            switch authorizer.status(of: kind) {
            case .granted:
                continue
            case .notDetermined:
                step = .explaining(kind)
                return
            case .denied, .restricted:
                step = .denied(kind)
                return
            }
        }
        step = .granted
    }

    /// „Weiter“ on the explanation screen: shows the system prompt right away.
    public func continueTapped() async {
        guard case let .explaining(kind) = step else { return }
        step = .requesting(kind)
        systemPromptCount += 1
        let result = await authorizer.request(kind)
        switch result {
        case .granted:
            begin()
        case .denied, .restricted, .notDetermined:
            step = .denied(kind)
        }
    }

    /// Closing is only possible after the system prompt was answered (denied state).
    public func close() {
        guard case .denied = step else { return }
        step = .idle
    }

    /// Resets after the feature finished, so the next use re-checks the permissions.
    public func reset() {
        guard step == .granted else { return }
        step = .idle
    }
}
