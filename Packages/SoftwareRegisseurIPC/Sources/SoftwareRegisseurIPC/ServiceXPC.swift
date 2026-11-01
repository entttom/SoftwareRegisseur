#if os(macOS)
import Foundation
import XPC

/// Wen eine Seite als XPC-Gegenstelle akzeptiert (ADR-0020, Sicherheitsprüfung SR-SEC-05).
///
/// Standard ist „gleiches Team **und** erwarteter Signing-Identifier“: Der Dienst akzeptiert nur die Mac-App
/// (`SRMacAppBundleIdentifier` in seiner Info.plist), die App nur den Dienst (`SRAgentBundleIdentifier`).
/// Andere Programme desselben Teams (weitere Apps, Debug-Werkzeuge) werden abgelehnt.
///
/// Gelockert wird nur, wenn der Identifier im Bundle fehlt oder eine nicht aufgelöste Build-Variable ist
/// (unsignierte bzw. Entwicklungs-Builds ohne `Config/Local.xcconfig`): dann gilt „gleiches Team“.
/// Unsignierte Builds (`CODE_SIGNING_ALLOWED=NO`) erfüllen auch das absichtlich nicht und können sich nicht
/// verbinden.
public enum ServicePeerPolicy: Hashable, Sendable {
    case sameTeam
    case sameTeamAndSigningIdentifier(String)

    /// Info.plist-Schlüssel des Dienstes: Signing-Identifier der Mac-App.
    public static let macAppIdentifierKey = "SRMacAppBundleIdentifier"
    /// Info.plist-Schlüssel der Mac-App: Signing-Identifier des Dienstes.
    public static let agentIdentifierKey = "SRAgentBundleIdentifier"

    /// Policy aus einem Info.plist-Wert; leer oder `$(…)` → gelockert auf `sameTeam`.
    public static func from(signingIdentifier raw: String?) -> ServicePeerPolicy {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty, !value.contains("$("), !value.contains(" ") else { return .sameTeam }
        return .sameTeamAndSigningIdentifier(value)
    }

    /// Dienst: akzeptiert nur die Mac-App.
    public static func forService(bundle: Bundle) -> ServicePeerPolicy {
        from(signingIdentifier: bundle.object(forInfoDictionaryKey: macAppIdentifierKey) as? String)
    }

    /// Mac-App: spricht nur mit dem Dienst.
    public static func forClient(bundle: Bundle) -> ServicePeerPolicy {
        from(signingIdentifier: bundle.object(forInfoDictionaryKey: agentIdentifierKey) as? String)
    }

    public var requirement: XPCPeerRequirement {
        switch self {
        case .sameTeam: .isFromSameTeam()
        case let .sameTeamAndSigningIdentifier(identifier): .isFromSameTeam(andMatchesSigningIdentifier: identifier)
        }
    }
}

/// Peer-Anforderung für beide Richtungen (ADR-0020). Ohne Bundle-Angabe gilt „gleiches Team“; Produktion
/// nutzt ``ServicePeerPolicy/forService(bundle:)`` bzw. ``ServicePeerPolicy/forClient(bundle:)``.
public enum ServicePeerRequirement {
    public static var sameTeam: XPCPeerRequirement { .isFromSameTeam() }
}

/// XPC-Listener des Agent Service auf dem per launchd deklarierten Mach-Service.
public final class ServiceXPCServer: Sendable {
    private let listener: XPCListener

    /// Startet den Listener sofort. Anfragen von Peers, die `peerRequirement` nicht erfüllen,
    /// verwirft das System, bevor der Handler sie sieht.
    ///
    /// Jede Nachricht wird asynchron beantwortet: der Handler läuft in einem eigenen Task, die Antwort
    /// geht nach Abschluss über `XPCReceivedMessage.reply` zurück. Lange Befehle blockieren so weder
    /// die XPC-Queue noch andere Anfragen derselben Verbindung.
    public init(
        endpoint: ServiceEndpoint,
        peerRequirement: XPCPeerRequirement = ServicePeerRequirement.sameTeam,
        handler: some ServiceRequestHandling
    ) throws {
        listener = try XPCListener(
            service: endpoint.machServiceName,
            requirement: peerRequirement
        ) { request in
            request.accept { (message: XPCReceivedMessage) -> (any Encodable)? in
                let envelope: ServiceRequestEnvelope
                do {
                    envelope = try message.decode(as: ServiceRequestEnvelope.self)
                } catch {
                    // Unlesbarer Umschlag: meist eine ältere/neuere UI mit anderem Nachrichtenformat.
                    return ServiceResponseEnvelope(response: .protocolMismatch(serviceVersion: IPCProtocol.version, clientVersion: -1))
                }
                let reply = PendingReply(message: message)
                Task {
                    reply.send(await ServiceRequestDispatcher.respond(to: envelope, using: handler))
                }
                return nil
            }
        }
    }

    public func cancel() {
        listener.cancel()
    }
}

/// Hält eine empfangene Nachricht bis zur asynchronen Antwort. `XPCReceivedMessage` ist nicht als
/// `Sendable` markiert; libxpc erlaubt die Antwort aber von jedem Thread, genau einmal.
private struct PendingReply: @unchecked Sendable {
    let message: XPCReceivedMessage

    func send(_ envelope: ServiceResponseEnvelope) {
        message.reply(envelope)
    }
}

/// Fehler auf Client-Seite einer Dienstanfrage.
public enum ServiceClientError: Error, Sendable, Hashable {
    /// Verbindung nicht herstellbar oder vom System getrennt (Dienst nicht registriert, abgestürzt, Peer abgelehnt).
    case connectionFailed(String)
    /// Keine Antwort innerhalb der Frist.
    case timedOut
    /// Dienst spricht eine andere Protokollversion.
    case protocolMismatch(serviceVersion: Int, clientVersion: Int)
}

/// XPC-Client der macOS-UI. Hält höchstens eine Session und baut sie nach Fehlern neu auf.
public actor ServiceXPCClient {
    private let endpoint: ServiceEndpoint
    private let peerRequirement: XPCPeerRequirement
    private let timeout: Duration
    private var session: XPCSession?

    public init(
        endpoint: ServiceEndpoint,
        peerRequirement: XPCPeerRequirement = ServicePeerRequirement.sameTeam,
        timeout: Duration = .seconds(3)
    ) {
        self.endpoint = endpoint
        self.peerRequirement = peerRequirement
        self.timeout = timeout
    }

    /// Sendet eine Anfrage und liefert die Antwort des Dienstes.
    ///
    /// Achtung: Ist der Agent registriert, startet launchd ihn bei Bedarf über den Mach-Service.
    /// Eine Anfrage an einen gestoppten, aber registrierten Dienst startet ihn also wieder.
    ///
    /// Die Wartezeit ist das Maximum aus der Client-Frist und ``ServiceRequest/minimumTimeout``,
    /// damit lange Befehle (Scan, Sync, Integration) nicht vorzeitig als Zeitüberschreitung gelten.
    public func send(_ request: ServiceRequest) async throws(ServiceClientError) -> ServiceResponse {
        let envelope = ServiceRequestEnvelope(request: request)
        let reply: ServiceResponseEnvelope
        do {
            let session = try currentSession()
            reply = try await Self.exchange(envelope, over: session, timeout: max(timeout, request.minimumTimeout))
        } catch let error as ServiceClientError {
            invalidateSession()
            throw error
        } catch {
            invalidateSession()
            throw .connectionFailed(String(describing: error))
        }
        if case let .protocolMismatch(serviceVersion, clientVersion) = reply.response {
            throw .protocolMismatch(serviceVersion: serviceVersion, clientVersion: clientVersion)
        }
        guard reply.protocolVersion == IPCProtocol.version else {
            throw .protocolMismatch(serviceVersion: reply.protocolVersion, clientVersion: IPCProtocol.version)
        }
        return reply.response
    }

    /// Trennt die Verbindung ausdrücklich.
    public func disconnect() {
        invalidateSession()
    }

    private func currentSession() throws -> XPCSession {
        if let session { return session }
        let created = try XPCSession(
            machService: endpoint.machServiceName,
            requirement: peerRequirement,
            cancellationHandler: nil
        )
        session = created
        return created
    }

    private func invalidateSession() {
        session?.cancel(reason: "Verbindung zum Agent Service zurückgesetzt")
        session = nil
    }

    private static func exchange(
        _ envelope: ServiceRequestEnvelope,
        over session: XPCSession,
        timeout: Duration
    ) async throws -> ServiceResponseEnvelope {
        try await withThrowingTaskGroup(of: ServiceResponseEnvelope.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ServiceResponseEnvelope, any Error>) in
                        do {
                            try session.send(envelope) { (result: Result<ServiceResponseEnvelope, any Error>) in
                                continuation.resume(with: result)
                            }
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                } onCancel: {
                    // Bricht die ausstehende Antwort ab; XPC ruft den Reply-Handler dann mit Fehler auf.
                    session.cancel(reason: "Zeitüberschreitung")
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ServiceClientError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw ServiceClientError.timedOut }
            return first
        }
    }
}
#endif
