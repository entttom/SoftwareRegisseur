import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC
import SoftwareRegisseurPersistence
import Synchronization
import Testing

/// Simuliert den XPC-Transport im Prozess: Umschläge werden wie auf dem Draht kodiert und dekodiert.
private func roundTrip(_ request: ServiceRequest, through core: AgentServiceCore,
                       protocolVersion: Int = IPCProtocol.version) async throws -> ServiceResponse {
    let wire = try PropertyListEncoder().encode(ServiceRequestEnvelope(request: request, protocolVersion: protocolVersion))
    let envelope = try PropertyListDecoder().decode(ServiceRequestEnvelope.self, from: wire)
    let reply = await ServiceRequestDispatcher.respond(to: envelope, using: core)
    let decoded = try PropertyListDecoder().decode(ServiceResponseEnvelope.self, from: PropertyListEncoder().encode(reply))
    #expect(decoded.protocolVersion == IPCProtocol.version)
    return decoded.response
}

private final class ManualInstant: Sendable {
    private let instant = Mutex(ContinuousClock.now)
    func now() -> ContinuousClock.Instant { instant.withLock { $0 } }
    func advance(by duration: Duration) { instant.withLock { $0 = $0.advanced(by: duration) } }
}

private let version = ServiceVersion(shortVersion: "1.0.0", build: "7")

@Suite("Agent Service: XPC-Befehle Ende-zu-Ende im Prozess (ADR-0020)", .serialized)
struct AgentServiceCoreTests {
    @Test func pingAndHealthWorkBeforeStartup() async throws {
        let clock = ManualInstant()
        let core = AgentServiceCore(version: version, processIdentifier: 99, startedAt: Date(timeIntervalSince1970: 0),
                                    now: { clock.now() }, stopHandler: {})
        #expect(try await roundTrip(.ping, through: core) == .pong(version))
        clock.advance(by: .seconds(90) + .milliseconds(500))
        guard case let .health(health) = try await roundTrip(.health, through: core) else {
            Issue.record("health erwartet")
            return
        }
        #expect(health.uptimeSeconds == 90.5)
        #expect(health.processIdentifier == 99)
        #expect(health.protocolVersion == IPCProtocol.version)
        // Befehle vor dem Start: ehrliche Ablehnung statt stiller Erfolgsmeldung.
        guard case let .failure(message) = try await roundTrip(.statusSummary, through: core) else {
            Issue.record("failure erwartet")
            return
        }
        #expect(message.contains("startet"))
    }

    @Test func startupFailureIsReported() async throws {
        let core = AgentServiceCore(version: version, stopHandler: {})
        core.startupFailed("Der Dienst konnte nicht starten: Datenbank gesperrt")
        #expect(try await roundTrip(.pause, through: core) == .failure("Der Dienst konnte nicht starten: Datenbank gesperrt"))
    }

    @Test func stopCallsHandler() async throws {
        let stopped = Mutex(false)
        let core = AgentServiceCore(version: version, stopHandler: { stopped.withLock { $0 = true } })
        #expect(try await roundTrip(.stop, through: core) == .stopping)
        #expect(stopped.withLock { $0 })
    }

    @Test func oldClientIsRejectedWithProtocolMismatch() async throws {
        let core = AgentServiceCore(version: version, stopHandler: {})
        let response = try await roundTrip(.ping, through: core, protocolVersion: 1)
        #expect(response == .protocolMismatch(serviceVersion: IPCProtocol.version, clientVersion: 1))
    }

    @Test func commandsReachTheRuntimeEndToEnd() async throws {
        let harness = try await ServiceTestHarness()
        let runtime = try await harness.makeRuntime()
        let core = AgentServiceCore(version: version, stopHandler: {})
        core.attach(runtime)

        let path = harness.developerPath
        guard case let .result(.rootFolders(state)) = try await roundTrip(.addRootFolder(path: path), through: core) else {
            Issue.record("rootFolders erwartet")
            return
        }
        #expect(state.folders.map(\.path) == [path])
        guard case let .result(.scanFinished(scan)) = try await roundTrip(.refreshScanner, through: core) else {
            Issue.record("scanFinished erwartet")
            return
        }
        #expect(scan.createdProjects == 1)
        guard case let .result(.agents(agents)) = try await roundTrip(.redetectAgents, through: core) else {
            Issue.record("agents erwartet")
            return
        }
        #expect(agents.contains { $0.providerId == .codex && $0.ready })

        #expect(try await roundTrip(.pause, through: core) == .runState(.paused))
        guard case let .health(health) = try await roundTrip(.health, through: core) else {
            Issue.record("health erwartet")
            return
        }
        #expect(health.runState == .paused)
        guard case let .statusSummary(summary) = try await roundTrip(.statusSummary, through: core) else {
            Issue.record("statusSummary erwartet")
            return
        }
        #expect(summary.macState == .paused)
        #expect(summary.workspace.projectsReady == 1)
        #expect(try await roundTrip(.resume, through: core) == .runState(.running))

        // Ohne CloudKit ehrlich „nicht verfügbar“.
        #expect(try await roundTrip(.syncNow, through: core) == .notAvailable(.cloudSync))

        // Einstellungen werden begrenzt gespeichert und überstehen einen Neustart.
        guard case let .result(.serviceSettings(saved)) = try await roundTrip(
            .updateServiceSettings(ServiceSettings(syncPollInterval: 1, preventIdleSleepWhileAgentsRun: true)), through: core) else {
            Issue.record("serviceSettings erwartet")
            return
        }
        #expect(saved.syncPollInterval == 15)
        let restarted = try await harness.makeRuntime()
        #expect(await restarted.settings.preventIdleSleepWhileAgentsRun)

        // Unbekannte IDs: deutsche Fehlermeldung.
        guard case let .failure(message) = try await roundTrip(.cancelJob(jobId: JobID()), through: core) else {
            Issue.record("failure erwartet")
            return
        }
        #expect(message.contains("nicht gefunden"))
    }
}

@Suite("Agent Service: Bausteine")
struct ServiceBuildingBlockTests {
    @Test func wakeSignalEndsWaitEarlyAndRemembersPendingSignal() async {
        let signal = WakeSignal()
        signal.signal()
        let start = ContinuousClock.now
        await signal.wait(timeout: .seconds(30))
        #expect(ContinuousClock.now - start < .seconds(5))

        Task {
            try? await Task.sleep(for: .milliseconds(50))
            signal.signal()
        }
        let second = ContinuousClock.now
        await signal.wait(timeout: .seconds(30))
        #expect(ContinuousClock.now - second < .seconds(5))

        let third = ContinuousClock.now
        await signal.wait(timeout: .milliseconds(50))
        #expect(ContinuousClock.now - third >= .milliseconds(40))
    }

    @Test func admissionGateHidesOnlyTheAdmissionQuery() async throws {
        let database = try AppDatabase.inMemory()
        let hostId = HostID()
        let gate = AdmissionGate(isOpen: false)
        let repository = AdmissionGatedJobRepository(base: database.jobs, gate: gate, hostId: hostId)
        // Die Zulassungsabfrage ist leer, andere Abfragen laufen weiter.
        #expect(try await repository.jobs(inStates: [.scheduled, .waitingQuota], hostId: hostId, limit: nil).isEmpty)
        _ = try await repository.jobs(inStates: [.requested, .pendingMac], hostId: nil, limit: nil)
        gate.set(open: true)
        #expect(gate.isOpen)
    }

    @Test func cloudKitOnlyForSignedBuildsWithRealTeam() {
        let unsigned = ServiceBundleConfiguration(values: ["SRCodeSigningAllowed": "NO", "SRDevelopmentTeam": "ABCDE12345",
                                                           "SRCloudKitContainerIdentifier": "iCloud.at.beispiel.SR"])
        guard case .unavailable = unsigned.cloudKit else {
            Issue.record("unsigniert darf kein CloudKit nutzen")
            return
        }
        let placeholder = ServiceBundleConfiguration(values: ["SRDevelopmentTeam": "XXXXXXXXXX", "SRTemplateTeamPlaceholder": "XXXXXXXXXX",
                                                              "SRCloudKitContainerIdentifier": "iCloud.at.beispiel.SR"])
        guard case .unavailable = placeholder.cloudKit else {
            Issue.record("Platzhalter-Team darf kein CloudKit nutzen")
            return
        }
        let signed = ServiceBundleConfiguration(values: [
            "SRCodeSigningAllowed": "YES", "SRDevelopmentTeam": "ABCDE12345", "SRTemplateTeamPlaceholder": "XXXXXXXXXX",
            "SRCloudKitContainerIdentifier": "iCloud.at.beispiel.SR", "SRKeychainSharedGroup": "ABCDE12345.at.beispiel.SR.shared-keys",
        ])
        #expect(signed.cloudKit == .available(container: "iCloud.at.beispiel.SR"))
        #expect(signed.keychainAccessGroup == "ABCDE12345.at.beispiel.SR.shared-keys")
        #expect(signed.cloudKitEnvironment == nil)
    }

    @Test func folderScanDepthLimitsTheCatalogScan() {
        let storage = ServiceStorageLayout(rootURL: URL(filePath: "/tmp/sr", directoryHint: .isDirectory))
        let roots = [ServiceStateStore.RootFolder(path: "/Users/me/Developer", addedAt: .now)]
        #expect(ServiceRuntime.catalogConfiguration(roots: roots, storage: storage, scanDepth: 1).options.maxDepth == 1)
        #expect(ServiceRuntime.catalogConfiguration(roots: roots, storage: storage, scanDepth: 4).options.maxDepth == 4)
        #expect(ServiceSettings().folderScanDepth == 1)
    }

    @Test func cloudKitEnvironmentComesFromInfoPlist() {
        let production = ServiceBundleConfiguration(values: ["SRCloudKitEnvironment": "Production"])
        #expect(production.cloudKitEnvironment == "Production")
        let unsubstituted = ServiceBundleConfiguration(values: ["SRCloudKitEnvironment": "$(SR_CLOUDKIT_ENVIRONMENT)"])
        #expect(unsubstituted.cloudKitEnvironment == nil)
    }

    @Test func logRedactionRemovesSecrets() {
        let redacted = ServiceLog.redact("git clone https://user:ghp_abcdefghijklmnopqrstuvwxyz0123456789@github.com/x/y")
        #expect(!redacted.contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
    }
}
