import Foundation
import SoftwareRegisseurIPC

/// Aus der Info.plist gelesene Build-Konfiguration (Werte stammen aus Config/Local.xcconfig, ADR-0013).
struct AppConfiguration: Sendable {
    static let agentPlistNameInfoKey = "SRAgentLaunchdPlistName"
    static let keychainGroupInfoKey = "SRKeychainSharedGroup"
    static let templateTeamInfoKey = "SRTemplateTeamPlaceholder"

    let endpoint: Result<ServiceEndpoint, ServiceEndpointError>
    let agentPlistName: String?
    /// Gemeinsame Schlüsselbund-Gruppe mit dem Dienst; `nil` bei Platzhalter-Team oder fehlendem Wert.
    let keychainAccessGroup: String?

    static func load(from bundle: Bundle = .main) -> AppConfiguration {
        let endpoint = Result { () throws(ServiceEndpointError) -> ServiceEndpoint in
            try ServiceEndpoint(bundle: bundle)
        }
        let plistName = (bundle.object(forInfoDictionaryKey: agentPlistNameInfoKey) as? String)
            .flatMap { $0.isEmpty || $0.contains("$(") ? nil : $0 }
        return AppConfiguration(
            endpoint: endpoint,
            agentPlistName: plistName,
            keychainAccessGroup: keychainGroup(
                value: bundle.object(forInfoDictionaryKey: keychainGroupInfoKey) as? String,
                templateTeam: bundle.object(forInfoDictionaryKey: templateTeamInfoKey) as? String
            )
        )
    }

    /// Gleiche Regel wie der Dienst (`ServiceBundleConfiguration`): Platzhalterwerte werden nie verwendet.
    static func keychainGroup(value: String?, templateTeam: String?) -> String? {
        guard let value, !value.isEmpty, !value.contains("$(") else { return nil }
        if let templateTeam, !templateTeam.isEmpty, value.hasPrefix(templateTeam + ".") { return nil }
        return value
    }

    /// Datenbank des Dienstes im App-Group-Container (ADR-0019); `nil` ohne gültige App Group.
    var databaseURL: URL? {
        guard case let .success(endpoint) = endpoint else { return nil }
        return ServiceStorageLayout(endpoint: endpoint)?.databaseURL
    }
}
