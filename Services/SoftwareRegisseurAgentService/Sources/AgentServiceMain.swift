import Foundation
import os
import SoftwareRegisseurAgents
import SoftwareRegisseurDomain
import SoftwareRegisseurGit
import SoftwareRegisseurIPC
import SoftwareRegisseurJobs
import SoftwareRegisseurPersistence
import SoftwareRegisseurProcess
import SoftwareRegisseurSecrets
import SoftwareRegisseurSync
import SoftwareRegisseurWorkspace

/// Einstiegspunkt des Agent Service (LaunchAgent über `SMAppService.agent(plistName:)`, ADR-0020).
///
/// Läuft im Benutzerkontext ohne UI. launchd stellt den in der Plist deklarierten Mach-Service bereit;
/// der Dienst öffnet darauf einen `XPCListener` mit Peer-Prüfung auf dasselbe Team. Der XPC-Listener
/// startet vor der Datenbank, damit die UI „startet“ statt „nicht erreichbar“ sieht.
@main
enum AgentServiceMain {
    static func main() {
        let logger = ServiceLog.lifecycle

        let endpoint: ServiceEndpoint
        do {
            endpoint = try ServiceEndpoint(bundle: .main)
        } catch {
            logger.fault("Ungültige App-Group-Konfiguration im Dienst-Bundle: \(String(describing: error), privacy: .private)")
            exit(EX_CONFIG)
        }

        let version = ServiceVersion(bundle: .main)
        let core = AgentServiceCore(
            version: version,
            stopHandler: {
                // Antwort „stopping“ zuerst zustellen lassen, dann sauber beenden.
                // Exit-Code 0: launchd (KeepAlive.SuccessfulExit = false) startet nicht sofort neu.
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300)) {
                    logger.notice("Dienst auf Anforderung der UI beendet")
                    exit(EXIT_SUCCESS)
                }
            }
        )

        let server: ServiceXPCServer
        do {
            // SR-SEC-05: nur die eigene Mac-App (gleiches Team und Signing-Identifier) darf Befehle senden.
            let peerPolicy = ServicePeerPolicy.forService(bundle: .main)
            logger.notice("XPC-Peer-Prüfung: \(String(describing: peerPolicy), privacy: .public)")
            server = try ServiceXPCServer(endpoint: endpoint, peerRequirement: peerPolicy.requirement, handler: core)
        } catch {
            logger.fault("XPC-Listener für \(endpoint.machServiceName, privacy: .public) nicht startbar: \(String(describing: error), privacy: .private)")
            exit(EX_UNAVAILABLE)
        }

        Task {
            do {
                let runtime = try await ServiceRuntime.make(try makeDependencies(endpoint: endpoint, version: version))
                core.attach(runtime)
                await runtime.startLoops()
            } catch {
                let message = ServiceErrorText.message(for: error)
                core.startupFailed("Der Dienst konnte nicht starten: \(message)")
                logger.fault("Start fehlgeschlagen: \(message, privacy: .private)")
            }
        }

        logger.notice("Agent Service gestartet, Mach-Service \(endpoint.machServiceName, privacy: .public)")
        withExtendedLifetime(server) {
            dispatchMain()
        }
    }

    /// Produktionsabhängigkeiten: App-Group-Ablage, echte Agentenadapter, CloudKit nur in signierten Builds.
    private static func makeDependencies(endpoint: ServiceEndpoint, version: ServiceVersion) throws -> ServiceDependencies {
        guard let storage = ServiceStorageLayout(endpoint: endpoint) else {
            throw ServiceError.invalidPath("App-Group-Container \(endpoint.appGroupIdentifier)")
        }
        let database = try AppDatabase.openWriter(at: storage.databaseURL)
        let bundleConfiguration = ServiceBundleConfiguration(bundle: .main)
        let cloudSync: CloudSyncSetup = switch bundleConfiguration.cloudKit {
        case let .available(container):
            .available(CloudKitSyncEngineAdapter.factory(containerIdentifier: container), environment: bundleConfiguration.cloudKitEnvironment)
        case let .unavailable(reason): .unavailable(reason: reason)
        }
        let git = try? GitClient.locate()
        let shortVersion = version.shortVersion.isEmpty ? "1.0.0" : version.shortVersion
        return ServiceDependencies(
            database: database,
            storage: storage,
            version: version,
            hostName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            git: git,
            makeProviders: { hostId, detectionDirectory, overrides in
                AgentProviderRegistry(providers: [
                    CodexAgentProvider(configuration: .init(hostId: hostId, executableOverride: overrides[.codex],
                                                            clientVersion: shortVersion, detectionWorkingDirectory: detectionDirectory)),
                    ClaudeCodeAgentProvider(configuration: .init(hostId: hostId, executableOverride: overrides[.claudeCode],
                                                                 detectionWorkingDirectory: detectionDirectory)),
                ])
            },
            cloudSync: cloudSync,
            clock: SystemJobClock(),
            processInspector: DarwinProcessInspector(),
            keychain: SystemKeychainStore(configuration: .init(
                service: "SoftwareRegisseur.ProviderKeys", accessGroup: bundleConfiguration.keychainAccessGroup)),
            makeTextProvider: ServiceDependencies.keychainTextProvider,
            makeGitHub: { GitHubIssueService(environment: $0) },
            sleepAssertion: IOKitSleepAssertion(),
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            concurrencyLimits: ConcurrencyLimits()
        )
    }
}
