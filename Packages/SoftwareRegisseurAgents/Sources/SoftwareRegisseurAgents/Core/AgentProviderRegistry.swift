import Foundation
import SoftwareRegisseurDomain

/// Registered coding-agent adapters (spec J1, ADR-0005). Providers that are not fully implemented
/// are still detected (so the UI can show „installiert, noch nicht unterstützt“) but never reported
/// as runnable.
public struct AgentProviderRegistry: Sendable {
    public private(set) var providers: [any AgentProvider]

    public init(providers: [any AgentProvider] = []) {
        self.providers = []
        for provider in providers { register(provider) }
    }

    /// Replaces an existing provider with the same ID.
    public mutating func register(_ provider: any AgentProvider) {
        providers.removeAll { $0.providerId == provider.providerId }
        providers.append(provider)
    }

    public func provider(for id: ProviderID) -> (any AgentProvider)? {
        providers.first { $0.providerId == id }
    }

    public var providerIds: [ProviderID] { providers.map(\.providerId) }

    /// Detects all providers concurrently. `previous` supplies the last capabilities for stable revisions.
    public func detectAll(previous: [ProviderID: AgentCapability] = [:]) async -> [AgentDetectionReport] {
        await withTaskGroup(of: (Int, AgentDetectionReport).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask {
                    (index, Self.enforceImplementationGate(await provider.detect(previous: previous[provider.providerId]), provider: provider))
                }
            }
            var reports: [(Int, AgentDetectionReport)] = []
            for await report in group { reports.append(report) }
            return reports.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    static func enforceImplementationGate(_ report: AgentDetectionReport, provider: any AgentProvider) -> AgentDetectionReport {
        guard !provider.isFullyImplemented, report.capability.runnable else { return report }
        var capability = report.capability
        capability.runnable = false
        capability.supportsAutomaticStart = false
        let diagnostic = AgentDiagnostic(
            code: "adapter.notImplemented", severity: .blocking,
            message: String(localized: "Der Adapter für \(provider.displayName) ist noch nicht vollständig implementiert.", bundle: .module)
        )
        let diagnostics = report.diagnostics + [diagnostic]
        capability.diagnostic = diagnostics.joinedMessage
        return AgentDetectionReport(capability: capability, diagnostics: diagnostics, toolchain: report.toolchain,
                                    modelResolutions: report.modelResolutions)
    }
}
