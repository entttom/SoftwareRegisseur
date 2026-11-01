import Foundation
import os
import SoftwareRegisseurProcess

/// Protokollierung des Dienstes (os.Logger, Q1).
///
/// Regeln: Pfade, Befehle, Fehlermeldungen und alles Benutzerbezogene gehen nur über
/// ``redact(_:)`` und mit `privacy: .private` ins Log; öffentlich sind nur Zähler, Zustände und
/// Kennungen ohne Personenbezug. API-Schlüssel und Tokens werden nie protokolliert.
enum ServiceLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "SoftwareRegisseurAgentService"

    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    static let jobs = Logger(subsystem: subsystem, category: "jobs")
    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let workspace = Logger(subsystem: subsystem, category: "workspace")
    static let agents = Logger(subsystem: subsystem, category: "agents")
    static let ai = Logger(subsystem: subsystem, category: "ai")
    static let ipc = Logger(subsystem: subsystem, category: "ipc")
    static let power = Logger(subsystem: subsystem, category: "power")

    /// Entfernt Geheimnisse (Tokens, Schlüssel, Passwörter in URLs) aus Text, der Pfade, Befehle oder
    /// Fehlermeldungen enthalten kann, und kürzt ihn.
    static func redact(_ text: String, limit: Int = 600) -> String {
        let redacted = SecretRedactor.standard.redact(text)
        return redacted.count > limit ? String(redacted.prefix(limit)) + "…" : redacted
    }

    static func redact(_ error: any Error) -> String {
        redact(String(describing: error))
    }
}
