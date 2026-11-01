import Foundation
import SoftwareRegisseurAgents
import SoftwareRegisseurDomain
import Synchronization

/// Hülle um einen Agentenanbieter, deren Inhalt der Dienst zur Laufzeit austauscht, wenn der Benutzer einen
/// eigenen Programmpfad festlegt (J1 „benutzerdefinierte Pfade“). Orchestrator und Registry halten die
/// Hülle; neue Erkennungen und Starts nutzen sofort den neuen Anbieter, ohne Dienstneustart. Bereits
/// laufende Sitzungen behalten ihren Prozess.
final class ReconfigurableAgentProvider: AgentProvider {
    let providerId: ProviderID
    let displayName: String
    private let current: Mutex<any AgentProvider>

    init(_ provider: any AgentProvider) {
        providerId = provider.providerId
        displayName = provider.displayName
        current = Mutex(provider)
    }

    var provider: any AgentProvider { current.withLock { $0 } }

    var isFullyImplemented: Bool { provider.isFullyImplemented }

    /// Ersetzt den Anbieter (gleiche `providerId`), z. B. mit neuem Programmpfad.
    func replace(with provider: any AgentProvider) {
        guard provider.providerId == providerId else { return }
        current.withLock { $0 = provider }
    }

    func detect(previous: AgentCapability?) async -> AgentDetectionReport {
        await provider.detect(previous: previous)
    }

    func prepareLaunch(snapshot: ConfigurationSnapshot, previous: AgentCapability?) async -> LaunchPreparation {
        await provider.prepareLaunch(snapshot: snapshot, previous: previous)
    }

    func startSession(plan: AgentLaunchPlan, request: AgentSessionRequest) async throws -> any AgentSession {
        try await provider.startSession(plan: plan, request: request)
    }
}
