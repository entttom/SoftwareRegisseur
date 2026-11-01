import AppKit
import Foundation
import Observation
import OSLog
import Security
import Sparkle
import SwiftUI

// Sparkle-2-Anbindung der Mac-App (ADR-0017, Pflichtenheft Q3).
//
// Bewusst in einer Datei gekapselt: Die Einbindung in die UI besteht nur aus
// `SoftwareUpdater` (einmal pro App), `CheckForUpdatesButton` (Menüleiste) und
// `SoftwareUpdateCommands` (App-Menü). Beim Umbau der Oberfläche diese drei Stellen mitnehmen.
//
// Die App läuft ohne App Sandbox (ADR-0020); Sparkle braucht daher weder
// Installer-XPC-Entitlements noch `SUEnableInstallerLauncherService`.
//
// Offen (Spike S3, ADR-0017/0020): Sparkle ersetzt das ganze Bundle inklusive
// Agent Service, startet den laufenden Dienst aber nicht nachweislich neu und pausiert
// keine laufenden Agentenjobs. Der Handshake (Service erkennt veraltete Version, pausiert
// Jobs, beendet sich; launchd startet die neue Binary) gehört zum Agent Service und ist
// hier nicht umgesetzt. Einstiegspunkt dafür: `willInstallUpdate`. Siehe docs/release/README.md.

/// Ergebnis der Konfigurationsprüfung für Sparkle (rein, ohne Seiteneffekte).
enum SoftwareUpdateAvailability: Equatable, Sendable {
    case enabled
    case disabled(reason: String)

    static let placeholderFeedMarker = "github.com/OWNER/REPO"
    static let placeholderPublicKey = "PUBLIC_KEY_BASE64"

    /// Prüft Info.plist-Werte. Platzhalter oder ungültige Werte schalten Updates ab,
    /// damit nie gegen eine erfundene Adresse oder ohne gültigen Schlüssel geprüft wird.
    static func evaluate(
        feedURL: String?,
        publicEDKey: String?,
        requiresSignedFeed: Bool,
        isDebugBuild: Bool,
        teamIdentifier: String?
    ) -> SoftwareUpdateAvailability {
        if isDebugBuild {
            return .disabled(reason: "Automatische Updates sind nur in Release-Builds aktiv. Dieser Debug-Build wird nicht ersetzt.")
        }
        guard teamIdentifier != nil else {
            return .disabled(reason: "Dieser Build ist nicht mit einer Team-ID signiert. Updates sind nur in Developer-ID-signierten Release-Builds möglich.")
        }
        guard let feedURL, !feedURL.isEmpty, !feedURL.contains("$("),
              !feedURL.contains(placeholderFeedMarker) else {
            return .disabled(reason: "Updates sind deaktiviert: Die Update-Adresse (SR_SPARKLE_FEED_URL) ist noch nicht eingerichtet. Neue Versionen bitte manuell installieren.")
        }
        guard let url = URL(string: feedURL), url.scheme?.lowercased() == "https", url.host() != nil else {
            return .disabled(reason: "Updates sind deaktiviert: Die Update-Adresse muss eine gültige HTTPS-Adresse sein.")
        }
        guard let publicEDKey, publicEDKey != placeholderPublicKey,
              let keyData = Data(base64Encoded: publicEDKey), keyData.count == 32 else {
            return .disabled(reason: "Updates sind deaktiviert: Der öffentliche Update-Schlüssel (SR_SPARKLE_PUBLIC_ED_KEY) fehlt oder ist ungültig.")
        }
        guard requiresSignedFeed else {
            return .disabled(reason: "Updates sind deaktiviert: Der Appcast muss signiert sein (SURequireSignedFeed).")
        }
        return .enabled
    }

    static func evaluate(bundle: Bundle) -> SoftwareUpdateAvailability {
        #if DEBUG
        let isDebugBuild = true
        #else
        let isDebugBuild = false
        #endif
        return evaluate(
            feedURL: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            publicEDKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
            requiresSignedFeed: (bundle.object(forInfoDictionaryKey: "SURequireSignedFeed") as? Bool) ?? false,
            isDebugBuild: isDebugBuild,
            teamIdentifier: currentTeamIdentifier()
        )
    }

    /// Team-ID aus der eigenen Codesignatur; nil bei unsignierten oder ad-hoc-signierten Builds.
    private static func currentTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

/// Besitzt den `SPUStandardUpdaterController` und stellt den Zustand für die UI bereit.
@MainActor
@Observable
final class SoftwareUpdater: NSObject {
    let availability: SoftwareUpdateAvailability
    private(set) var canCheckForUpdates = false
    /// Gentle Reminder (Menüleisten-App): Version eines geplant gefundenen, noch nicht angesehenen Updates.
    private(set) var pendingUpdateVersion: String?

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?
    @ObservationIgnored private let logger = Logger(subsystem: "SoftwareRegisseur", category: "Update")

    init(bundle: Bundle = .main) {
        availability = SoftwareUpdateAvailability.evaluate(bundle: bundle)
        super.init()

        guard availability == .enabled else {
            if case .disabled(let reason) = availability {
                logger.notice("Sparkle deaktiviert: \(reason, privacy: .public)")
            }
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        self.controller = controller
        // Sparkle meldet KVO-Änderungen auf dem Main Thread (SPUUpdater ist UI-Actor-gebunden).
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
        controller.startUpdater()
    }

    var isEnabled: Bool { availability == .enabled }

    /// Vom Benutzer ausgelöste Prüfung. Holt auch einen wartenden Gentle Reminder in den Vordergrund.
    func checkForUpdates() {
        guard let controller else { return }
        NSApplication.shared.activate()
        controller.checkForUpdates(nil)
    }
}

extension SoftwareUpdater: SPUUpdaterDelegate {
    /// Einstiegspunkt für den Service-Handshake (Spike S3) – derzeit nur protokolliert.
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        logger.notice("Update auf \(item.displayVersionString, privacy: .public) (\(item.versionString, privacy: .public)) wird installiert. Agent Service wird dabei nicht koordiniert neu gestartet (Spike S3 offen).")
    }
}

extension SoftwareUpdater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Geplante Funde nur sofort zeigen, wenn die App ohnehin im Fokus ist; sonst Hinweis in der Menüleiste.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !state.userInitiated {
            pendingUpdateVersion = update.displayVersionString
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        pendingUpdateVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        pendingUpdateVersion = nil
    }
}

/// „Nach Updates suchen …“ für das Menüleisten-Fenster. Erwartet `SoftwareUpdater` in der Environment.
struct CheckForUpdatesButton: View {
    @Environment(SoftwareUpdater.self) private var updater

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let version = updater.pendingUpdateVersion {
                Button("Update auf Version \(version) ansehen …") { updater.checkForUpdates() }
            } else {
                Button("Nach Updates suchen …") { updater.checkForUpdates() }
                    .disabled(!updater.isEnabled || !updater.canCheckForUpdates)
            }
            if case .disabled(let reason) = updater.availability {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Menüeintrag im App-Menü (sichtbar, solange ein Fenster der App aktiv ist).
struct SoftwareUpdateCommands: Commands {
    let updater: SoftwareUpdater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Nach Updates suchen …") { updater.checkForUpdates() }
                .disabled(!updater.isEnabled || !updater.canCheckForUpdates)
        }
    }
}
