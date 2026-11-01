import Foundation
import SoftwareRegisseurIPC
import Synchronization

/// XPC-Einstieg des Dienstes: beantwortet `ping`, `health` und `stop` immer selbst und leitet alle
/// anderen Befehle an die ``ServiceRuntime`` weiter, sobald diese gestartet ist (ADR-0020).
final class AgentServiceCore: ServiceRequestHandling {
    private let version: ServiceVersion
    private let processIdentifier: Int32
    private let startedAt: Date
    private let startInstant: ContinuousClock.Instant
    private let now: @Sendable () -> ContinuousClock.Instant
    private let stopHandler: @Sendable () -> Void
    private let state = Mutex<(runtime: ServiceRuntime?, startupError: String?)>((nil, nil))

    init(
        version: ServiceVersion,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        startedAt: Date = .now,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        stopHandler: @escaping @Sendable () -> Void
    ) {
        self.version = version
        self.processIdentifier = processIdentifier
        self.startedAt = startedAt
        self.now = now
        self.startInstant = now()
        self.stopHandler = stopHandler
    }

    var runtime: ServiceRuntime? { state.withLock { $0.runtime } }

    /// Verbindet die gestartete Laufzeit; erst danach werden Befehle ausgeführt.
    func attach(_ runtime: ServiceRuntime) {
        state.withLock { $0.runtime = runtime }
    }

    /// Start fehlgeschlagen (z. B. Datenbank nicht öffenbar): Befehle bekommen diese Meldung.
    func startupFailed(_ message: String) {
        state.withLock { $0.startupError = message }
    }

    func handle(_ request: ServiceRequest) async -> ServiceResponse {
        let (runtime, startupError) = state.withLock { ($0.runtime, $0.startupError) }
        switch request {
        case .ping:
            return .pong(version)
        case .stop:
            if let runtime { await runtime.stopLoops() }
            stopHandler()
            return .stopping
        case .health:
            if let runtime {
                var health = await runtime.health()
                health.uptimeSeconds = uptime()
                health.processIdentifier = processIdentifier
                return .health(health)
            }
            return .health(ServiceHealth(serviceVersion: version, processIdentifier: processIdentifier, startedAt: startedAt,
                                         uptimeSeconds: uptime(), runState: .running))
        default:
            guard let runtime else {
                return .failure(startupError ?? ServiceErrorText.message(for: ServiceError.notReady))
            }
            let response = await runtime.handle(request)
            if case .executeLocalDeletion = request, await runtime.isShutDownForDeletion {
                return await reopenAfterDeletion(replacing: runtime, response: response)
            }
            return response
        }
    }

    /// Nach einer lokalen Löschung (A34) war die Datenbank geschlossen: leer neu öffnen und die Laufzeit
    /// neu aufbauen (neue Host-Kennung, keine Stammordner), ohne den Prozess neu zu starten.
    private func reopenAfterDeletion(replacing old: ServiceRuntime, response: ServiceResponse) async -> ServiceResponse {
        var deps = old.deps
        let restartLoops = await old.loopsRanBeforeDeletion
        do {
            deps.database = try deps.openDatabase(deps.storage.databaseURL)
            let fresh = try await ServiceRuntime.make(deps)
            attach(fresh)
            if restartLoops { await fresh.startLoops() }
            ServiceLog.lifecycle.notice("Datenbank nach der Löschung leer neu geöffnet")
            return response
        } catch {
            let message = ServiceErrorText.message(for: error)
            state.withLock { $0.runtime = nil; $0.startupError = "Die Datenbank konnte nach dem Löschen nicht neu geöffnet werden: \(message). Bitte den Dienst neu starten." }
            ServiceLog.lifecycle.fault("Neuaufbau nach Löschung fehlgeschlagen: \(message, privacy: .private)")
            return .failure("Die Daten wurden gelöscht, aber die Datenbank konnte nicht neu geöffnet werden: \(message). Bitte den Dienst neu starten.")
        }
    }

    private func uptime() -> Double {
        let elapsed = startInstant.duration(to: now())
        return max(0, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    }
}
