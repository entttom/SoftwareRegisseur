import Foundation
import SoftwareRegisseurDomain
import Testing
@testable import SoftwareRegisseurIPC

private let sampleVersion = ServiceVersion(shortVersion: "1.0.0", build: "42")
private let sampleHealth = ServiceHealth(
    serviceVersion: sampleVersion,
    processIdentifier: 4711,
    startedAt: Date(timeIntervalSince1970: 1_793_000_000),
    uptimeSeconds: 3_725.5,
    runState: .paused
)

private let allResponses: [ServiceResponse] = [
    .pong(sampleVersion),
    .health(sampleHealth),
    .runState(.running),
    .runState(.paused),
    .stopping,
    .notAvailable(.cloudSync),
    .notAvailable(.repositoryScanner),
    .protocolMismatch(serviceVersion: 1, clientVersion: 2),
    .failure("Datenbank gesperrt"),
    .statusSummary(IPCSamples.summary),
] + IPCSamples.results.map(ServiceResponse.result)

private func roundTripJSON<T: Codable & Equatable>(_ value: T) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
}

private func roundTripPlist<T: Codable & Equatable>(_ value: T) throws -> T {
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    return try PropertyListDecoder().decode(T.self, from: encoder.encode(value))
}

@Suite("IPC-Nachrichten: Codable-Rundreise (ADR-0020)")
struct ServiceMessageCodingTests {
    @Test(arguments: IPCSamples.requests)
    func requestEnvelopeRoundTrips(_ request: ServiceRequest) throws {
        let envelope = ServiceRequestEnvelope(request: request)
        #expect(try roundTripJSON(envelope) == envelope)
        #expect(try roundTripPlist(envelope) == envelope)
        #expect(envelope.protocolVersion == IPCProtocol.version)
    }

    @Test(arguments: allResponses)
    func responseEnvelopeRoundTrips(_ response: ServiceResponse) throws {
        let envelope = ServiceResponseEnvelope(response: response)
        #expect(try roundTripJSON(envelope) == envelope)
        #expect(try roundTripPlist(envelope) == envelope)
    }

    @Test func healthKeepsAllFields() throws {
        let decoded = try roundTripJSON(sampleHealth)
        #expect(decoded.serviceVersion == sampleVersion)
        #expect(decoded.processIdentifier == 4711)
        #expect(decoded.uptimeSeconds == 3_725.5)
        #expect(decoded.runState == .paused)
        #expect(decoded.startedAt == Date(timeIntervalSince1970: 1_793_000_000))
        #expect(decoded.protocolVersion == IPCProtocol.version)
    }

    @Test func everyRequestKindHasASample() {
        // Neue Befehle müssen in IPCSamples.requests ergänzt werden (Rundreise-Abdeckung).
        let covered = Set(IPCSamples.requests.map(IPCSamples.kindIndex))
        #expect(covered == Set(0..<IPCSamples.requestKindCount))
    }

    @Test func protocolVersionIsFourAndStillServesTwoAndThree() {
        #expect(IPCProtocol.version == 4)
        #expect(IPCProtocol.minimumSupportedVersion == 2)
        #expect(IPCProtocol.supports(clientVersion: 2))
        #expect(IPCProtocol.supports(clientVersion: 3))
        #expect(IPCProtocol.supports(clientVersion: 4))
        #expect(!IPCProtocol.supports(clientVersion: 1))
        #expect(!IPCProtocol.supports(clientVersion: 5))
    }

    @Test(arguments: IPCSamples.v4Requests)
    func v4RequestsRoundTripAndGetCommandTimeouts(_ request: ServiceRequest) throws {
        let envelope = ServiceRequestEnvelope(request: request)
        #expect(try roundTripJSON(envelope) == envelope)
        #expect(try roundTripPlist(envelope) == envelope)
        #expect(request.minimumTimeout >= .seconds(60))
    }

    @Test func savedConversationKeepsMessagesScopeAndUsage() throws {
        guard case let .saveConversation(decoded) = try roundTripJSON(ServiceRequestEnvelope(request: .saveConversation(IPCSamples.conversation))).request else {
            Issue.record("saveConversation erwartet")
            return
        }
        #expect(decoded.messages.map(\.text) == ["Bitte Kopfzeile ergänzen", "Vorschlag anbei."])
        #expect(decoded.messages.map(\.role) == [.user, .assistant])
        #expect(decoded.contextScope == .project(IPCSamples.project))
        #expect(decoded.usage == TokenUsage(inputTokens: 120, outputTokens: 40))
        #expect(decoded.proposedDraftVersion == 4)
        #expect(decoded.updatedAt == IPCSamples.date.addingTimeInterval(3))
    }

    @Test func reviewDetailsWithoutExcludedSecretsStayCompatible() throws {
        guard case let .reviewDetails(details) = try #require(IPCSamples.results.first(where: {
            if case .reviewDetails = $0 { true } else { false }
        })) else { return }
        #expect(try roundTripJSON(details).excludedSecretPaths == [".env.local"])
        var old = details
        old.excludedSecretPaths = nil
        let data = try JSONEncoder().encode(old)
        #expect(!String(decoding: data, as: UTF8.self).contains("excludedSecretPaths"))
        #expect(try JSONDecoder().decode(ReviewDetailsInfo.self, from: data).excludedSecretPaths == nil)
    }

    @Test func v3EnvelopeOfAnOldClientStillDecodes() throws {
        // So sendet eine App mit Protokoll 3 einen unveränderten Befehl an einen Dienst mit Protokoll 4.
        let draft = DraftVersionID()
        let json = Data(#"{"protocolVersion":3,"request":{"rejectDraftVersion":{"draftId":"\#(draft.uuidString)"}}}"#.utf8)
        let envelope = try JSONDecoder().decode(ServiceRequestEnvelope.self, from: json)
        #expect(envelope.protocolVersion == 3)
        #expect(envelope.request == .rejectDraftVersion(draftId: draft))
        #expect(IPCProtocol.supports(clientVersion: envelope.protocolVersion))
    }

    @Test(arguments: IPCSamples.v3Requests)
    func v3RequestsRoundTripAndGetCommandTimeouts(_ request: ServiceRequest) throws {
        let envelope = ServiceRequestEnvelope(request: request)
        #expect(try roundTripJSON(envelope) == envelope)
        #expect(try roundTripPlist(envelope) == envelope)
        // Schreibbefehle warten nie nur 5 s (Abfrage-Frist).
        #expect(request.minimumTimeout >= .seconds(60))
    }

    @Test func v2EnvelopeOfAnOldClientStillDecodes() throws {
        // So sendet eine App mit Protokoll 2 einen unveränderten Befehl.
        let json = Data(#"{"protocolVersion":2,"request":{"reconcileProject":{"projectId":"\#(IPCSamples.project.uuidString)"}}}"#.utf8)
        let envelope = try JSONDecoder().decode(ServiceRequestEnvelope.self, from: json)
        #expect(envelope.protocolVersion == 2)
        #expect(envelope.request == .reconcileProject(projectId: IPCSamples.project))
    }

    @Test func storedV2SettingsWithoutNewFieldsDecodeWithDefaults() throws {
        let json = Data(#"{"syncPollInterval":120,"syncMaxBackoff":1800,"workspaceScanInterval":900,"reconcileInterval":300,"agentDetectionInterval":1800,"gitHubSyncInterval":900,"jobsIdleInterval":60,"preventIdleSleepWhileAgentsRun":true,"processQueuedAIElaborations":false}"#.utf8)
        let settings = try JSONDecoder().decode(ServiceSettings.self, from: json)
        #expect(settings.syncPollInterval == 120)
        #expect(settings.preventIdleSleepWhileAgentsRun)
        #expect(!settings.processQueuedAIElaborations)
        #expect(settings.agentExecutablePaths.isEmpty)
        #expect(settings.folderScanDepth == 1)
        #expect(try roundTripJSON(ServiceSettings(folderScanDepth: 3)).folderScanDepth == 3)
        let withPath = ServiceSettings(agentExecutablePaths: ["codex": "/usr/local/bin/codex"])
        #expect(try roundTripJSON(withPath).executablePath(for: .codex) == "/usr/local/bin/codex")
    }

    @Test func v2ClientIgnoresNewSummaryFields() throws {
        // Ein Client mit Protokoll 2 kennt `cloudDataDeletion` nicht; das Feld ist optional und additiv.
        var summary = IPCSamples.summary.sync
        summary.cloudDataDeletion = nil
        let data = try JSONEncoder().encode(summary)
        #expect(!String(decoding: data, as: UTF8.self).contains("cloudDataDeletion"))
        #expect(try roundTripJSON(IPCSamples.summary.sync).cloudDataDeletion == .deleted)
    }

    @Test func manualStatusTargetsExcludeHostOnlyStatuses() {
        let fromOpen = WorkItemCommandRules.manualTargets(from: .open)
        #expect(fromOpen.contains(.cancelled))
        #expect(fromOpen.contains(.done))
        #expect(!fromOpen.contains(.queued))
        #expect(!WorkItemCommandRules.manualTargets(from: .review).contains(.integrated))
        #expect(WorkItemCommandRules.normalizedLabels([" a ", "", "b", "a"]) == ["a", "b"])
    }

    @Test func longCommandsGetLongerTimeouts() {
        #expect(ServiceRequest.ping.minimumTimeout == .seconds(5))
        #expect(ServiceRequest.syncNow.minimumTimeout >= .seconds(120))
        #expect(ServiceRequest.integrateReview(reviewId: ReviewID()).minimumTimeout >= .seconds(120))
    }

    @Test func settingsAreClampedToSaneMinimums() {
        let clamped = ServiceSettings(syncPollInterval: 1, workspaceScanInterval: 1, jobsIdleInterval: 0).clamped
        #expect(clamped.syncPollInterval == 15)
        #expect(clamped.workspaceScanInterval == 60)
        #expect(clamped.jobsIdleInterval == 5)
        #expect(ServiceSettings(folderScanDepth: 0).clamped.folderScanDepth == 1)
        #expect(ServiceSettings(folderScanDepth: 20).clamped.folderScanDepth == 8)
    }

    @Test func storageLayoutDerivesAllPathsFromOneRoot() {
        let layout = ServiceStorageLayout(rootURL: URL(filePath: "/tmp/sr", directoryHint: .isDirectory))
        #expect(layout.databaseURL.path(percentEncoded: false) == "/tmp/sr/Database/SoftwareRegisseur.sqlite")
        #expect(layout.worktreesURL.path(percentEncoded: false).hasPrefix("/tmp/sr/"))
        #expect(layout.runtimeURL != layout.worktreesURL)
    }

    @Test func unknownRequestIsRejectedByDecoder() throws {
        let json = Data(#"{"protocolVersion":2,"request":{"launchMissiles":{}}}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ServiceRequestEnvelope.self, from: json)
        }
    }

    @Test func runStateRawValuesAreStable() {
        // Rohwerte werden persistiert (Pause überdauert Dienstneustart) – nicht umbenennen.
        #expect(ServiceRunState.running.rawValue == "running")
        #expect(ServiceRunState.paused.rawValue == "paused")
    }
}

private struct RecordingHandler: ServiceRequestHandling {
    func handle(_ request: ServiceRequest) async -> ServiceResponse {
        switch request {
        case .ping: .pong(sampleVersion)
        default: .failure("nicht erwartet")
        }
    }
}

@Suite("Protokollversion im Dispatcher")
struct ServiceRequestDispatcherTests {
    @Test func matchingVersionReachesHandler() async {
        let reply = await ServiceRequestDispatcher.respond(to: ServiceRequestEnvelope(request: .ping), using: RecordingHandler())
        #expect(reply == ServiceResponseEnvelope(response: .pong(sampleVersion)))
    }

    @Test func v3ClientIsServedWithItsOwnVersion() async {
        let envelope = ServiceRequestEnvelope(request: .ping, protocolVersion: 3)
        let reply = await ServiceRequestDispatcher.respond(to: envelope, using: RecordingHandler())
        #expect(reply.response == .pong(sampleVersion))
        #expect(reply.protocolVersion == 3)
    }

    @Test func olderSupportedClientIsServedWithItsOwnVersion() async {
        let envelope = ServiceRequestEnvelope(request: .ping, protocolVersion: 2)
        let reply = await ServiceRequestDispatcher.respond(to: envelope, using: RecordingHandler())
        #expect(reply.response == .pong(sampleVersion))
        // Der v2-Client prüft `reply.protocolVersion == 2`.
        #expect(reply.protocolVersion == 2)
    }

    @Test func tooOldClientIsRejected() async {
        let envelope = ServiceRequestEnvelope(request: .ping, protocolVersion: 1)
        let reply = await ServiceRequestDispatcher.respond(to: envelope, using: RecordingHandler())
        #expect(reply.response == .protocolMismatch(serviceVersion: IPCProtocol.version, clientVersion: 1))
    }

    @Test func mismatchingVersionIsRejectedWithoutCallingHandler() async {
        let envelope = ServiceRequestEnvelope(request: .ping, protocolVersion: IPCProtocol.version + 1)
        let reply = await ServiceRequestDispatcher.respond(to: envelope, using: RecordingHandler())
        #expect(reply.response == .protocolMismatch(serviceVersion: IPCProtocol.version, clientVersion: IPCProtocol.version + 1))
    }
}

@Suite("Mach-Service-Name aus App Group (ADR-0020)")
struct ServiceEndpointTests {
    @Test func machServiceNameCarriesAppGroupPrefix() throws {
        let endpoint = try ServiceEndpoint(appGroupIdentifier: "ABCDE12345.at.beispiel.SoftwareRegisseur")
        #expect(endpoint.machServiceName == "ABCDE12345.at.beispiel.SoftwareRegisseur.agent")
        #expect(endpoint.machServiceName.hasPrefix(endpoint.appGroupIdentifier + "."))
    }

    @Test func whitespaceIsTrimmed() throws {
        let endpoint = try ServiceEndpoint(appGroupIdentifier: "  ABCDE12345.at.beispiel.SoftwareRegisseur\n")
        #expect(endpoint.appGroupIdentifier == "ABCDE12345.at.beispiel.SoftwareRegisseur")
    }

    @Test func emptyAppGroupIsRejected() {
        #expect(throws: ServiceEndpointError.missingAppGroup) { try ServiceEndpoint(appGroupIdentifier: "  ") }
    }

    @Test func unresolvedBuildSettingIsRejected() {
        #expect(throws: ServiceEndpointError.unresolvedBuildSetting("$(SR_APP_GROUP_MAC)")) {
            try ServiceEndpoint(appGroupIdentifier: "$(SR_APP_GROUP_MAC)")
        }
    }

    @Test(arguments: ["SoftwareRegisseur", "ABCDE12345..x", "group.at.beispiel.SoftwareRegisseur", ".x"])
    func malformedAppGroupIsRejected(_ value: String) {
        #expect(throws: ServiceEndpointError.malformedAppGroup(value)) { try ServiceEndpoint(appGroupIdentifier: value) }
    }

    @Test func bundleWithoutKeyIsRejected() {
        // Das Test-Bundle hat keinen SRAppGroupIdentifier-Eintrag.
        #expect(throws: ServiceEndpointError.missingAppGroup) { try ServiceEndpoint(bundle: Bundle(for: BundleMarker.self)) }
    }
}

private final class BundleMarker {}

@Suite("XPC-Peer-Prüfung mit Signing-Identifier (SR-SEC-05)")
struct ServicePeerPolicyTests {
    @Test func configuredIdentifierRestrictsToThatPeer() {
        #expect(ServicePeerPolicy.from(signingIdentifier: "at.beispiel.SoftwareRegisseur")
                == .sameTeamAndSigningIdentifier("at.beispiel.SoftwareRegisseur"))
        #expect(ServicePeerPolicy.from(signingIdentifier: "  at.beispiel.Agent\n") == .sameTeamAndSigningIdentifier("at.beispiel.Agent"))
    }

    @Test(arguments: [nil, "", "  ", "$(SR_MAC_BUNDLE_ID)", "a b"])
    func missingOrUnresolvedIdentifierFallsBackToSameTeam(_ value: String?) {
        #expect(ServicePeerPolicy.from(signingIdentifier: value) == .sameTeam)
    }

    @Test func bothSidesReadTheirOwnInfoPlistKey() {
        // Das Test-Bundle hat keine der Angaben: dokumentierte Lockerung auf „gleiches Team“.
        let bundle = Bundle(for: PeerBundleMarker.self)
        #expect(ServicePeerPolicy.forService(bundle: bundle) == .sameTeam)
        #expect(ServicePeerPolicy.forClient(bundle: bundle) == .sameTeam)
        #expect(ServicePeerPolicy.macAppIdentifierKey != ServicePeerPolicy.agentIdentifierKey)
        _ = ServicePeerPolicy.sameTeamAndSigningIdentifier("x").requirement
    }
}

private final class PeerBundleMarker {}
