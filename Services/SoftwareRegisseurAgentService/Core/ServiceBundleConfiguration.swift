import Foundation

/// Werte aus der Info.plist des Dienst-Bundles (Build-Variablen aus `Config/*.xcconfig`, ADR-0013).
struct ServiceBundleConfiguration: Sendable, Hashable {
    enum CloudKit: Sendable, Hashable {
        case available(container: String)
        case unavailable(reason: String)
    }

    var cloudKit: CloudKit
    /// Gemeinsame Schlüsselbund-Gruppe für API-Schlüssel (UI schreibt, Dienst liest), falls gesetzt.
    var keychainAccessGroup: String?

    init(values: [String: String]) {
        func value(_ key: String) -> String {
            (values[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Wie die iOS-App: unsignierte oder Platzhalter-Builds haben keine iCloud-Berechtigung; ein
        // `CKContainer` würde dort abstürzen. Sync bleibt dann aus und die Statusübersicht sagt warum.
        if value("SRCodeSigningAllowed").uppercased() == "NO" {
            cloudKit = .unavailable(reason: "unsignierter Build (keine iCloud-Berechtigung)")
        } else if value("SRDevelopmentTeam").isEmpty || value("SRDevelopmentTeam") == value("SRTemplateTeamPlaceholder") {
            cloudKit = .unavailable(reason: "kein Entwicklerteam in Config/Local.xcconfig eingetragen")
        } else {
            let container = value("SRCloudKitContainerIdentifier")
            if container.hasPrefix("iCloud."), !container.contains("$(") {
                cloudKit = .available(container: container)
            } else {
                cloudKit = .unavailable(reason: "kein gültiger CloudKit-Container konfiguriert")
            }
        }
        let group = value("SRKeychainSharedGroup")
        keychainAccessGroup = group.isEmpty || group.contains("$(") || group.hasPrefix(value("SRTemplateTeamPlaceholder") + ".")
            ? nil : group
    }

    init(bundle: Bundle) {
        let keys = ["SRCodeSigningAllowed", "SRDevelopmentTeam", "SRTemplateTeamPlaceholder", "SRCloudKitContainerIdentifier",
                    "SRKeychainSharedGroup"]
        var values: [String: String] = [:]
        for key in keys {
            if let value = bundle.object(forInfoDictionaryKey: key) as? String { values[key] = value }
        }
        self.init(values: values)
    }
}
