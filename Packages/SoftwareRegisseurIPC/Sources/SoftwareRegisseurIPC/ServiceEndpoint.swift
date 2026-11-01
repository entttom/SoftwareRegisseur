import Foundation

/// Benennung des Mach-Service, über den UI und Agent Service per XPC sprechen.
///
/// Der Name trägt immer das App-Group-Präfix (`<TEAMID>.<präfix>.SoftwareRegisseur`),
/// damit er auch dann gültig bleibt, wenn die UI später sandboxed läuft
/// (ADR-0020; Recherche apple-platform.md §3.2).
public struct ServiceEndpoint: Sendable, Hashable {
    /// Info.plist-Schlüssel, unter dem UI und Dienst die App-Group-Kennung erhalten.
    public static let appGroupInfoKey = "SRAppGroupIdentifier"
    /// Suffix des Mach-Service-Namens. Muss mit `SR_AGENT_MACH_SERVICE` in `Config/Base.xcconfig` übereinstimmen.
    public static let machServiceSuffix = "agent"

    public let appGroupIdentifier: String

    public init(appGroupIdentifier: String) throws(ServiceEndpointError) {
        let trimmed = appGroupIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .missingAppGroup }
        // Unaufgelöste Build-Variable, z. B. "$(SR_APP_GROUP_MAC)".
        guard !trimmed.contains("$(") else { throw .unresolvedBuildSetting(trimmed) }
        // macOS-App-Groups mit Team-ID-Präfix: "<TEAMID>.<name>"; "group."-Präfix wäre iOS-Stil.
        let components = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2, components.allSatisfy({ !$0.isEmpty }) else {
            throw .malformedAppGroup(trimmed)
        }
        guard !trimmed.hasPrefix("group.") else { throw .malformedAppGroup(trimmed) }
        self.appGroupIdentifier = trimmed
    }

    /// Liest die App-Group-Kennung aus der Info.plist eines Bundles.
    public init(bundle: Bundle) throws(ServiceEndpointError) {
        guard let value = bundle.object(forInfoDictionaryKey: Self.appGroupInfoKey) as? String else {
            throw .missingAppGroup
        }
        try self.init(appGroupIdentifier: value)
    }

    /// Mach-Service-Name im Format `<app group>.agent`.
    public var machServiceName: String {
        "\(appGroupIdentifier).\(Self.machServiceSuffix)"
    }
}

public enum ServiceEndpointError: Error, Sendable, Hashable {
    case missingAppGroup
    case unresolvedBuildSetting(String)
    case malformedAppGroup(String)
}
