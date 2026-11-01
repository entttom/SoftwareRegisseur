import Foundation
import SoftwareRegisseurDomain
import Testing
@testable import SoftwareRegisseurAgents

/// Optional checks against the agents installed on this Mac. Enabled only with
/// `SR_REAL_AGENT_TESTS=1`. They perform NON-billable calls only: `--version`, `login status` /
/// `auth status`, Codex `initialize` + `model/list`, Claude `initialize` control request.
/// No thread, turn or prompt is ever started here.
@Suite("Real installed agents (non-billable)", .enabled(if: ProcessInfo.processInfo.environment["SR_REAL_AGENT_TESTS"] == "1"),
       .timeLimit(.minutes(2)))
struct RealAgentTests {
    static func describe(_ report: AgentDetectionReport) -> String {
        let c = report.capability
        let models = c.modelCatalog.map { "\($0.modelId)[\($0.supportedEffortIds.map(\.rawValue).joined(separator: ","))]" }
        return """
        provider=\(c.providerId) path=\(c.executablePath ?? "-") version=\(c.version) installed=\(c.installed) \
        authenticated=\(c.authenticated) runnable=\(c.runnable) default=\(c.defaultModelId?.rawValue ?? "-") \
        models=\(models.joined(separator: " ")) diagnostics=\(report.diagnostics.map(\.code))
        """
    }

    @Test func codexDetectionAndCatalog() async throws {
        let provider = CodexAgentProvider(configuration: .init(hostId: Fixtures.hostId))
        let report = await provider.detect(previous: nil)
        print("REAL-CODEX:", Self.describe(report))
        try #require(report.capability.installed, "Codex not installed on this Mac")
        #expect(SemanticVersion(report.capability.version) != nil)
        if report.capability.authenticated {
            #expect(!report.capability.modelCatalog.isEmpty, "\(report.diagnostics)")
            #expect(report.capability.defaultModelId != nil)
            #expect(report.capability.runnable, "\(report.diagnostics)")
        }
    }

    @Test func claudeDetectionAndCatalog() async throws {
        let provider = ClaudeCodeAgentProvider(configuration: .init(hostId: Fixtures.hostId))
        let report = await provider.detect(previous: nil)
        print("REAL-CLAUDE:", Self.describe(report))
        try #require(report.capability.installed, "Claude Code not installed on this Mac")
        #expect(SemanticVersion(report.capability.version) != nil)
        if !report.capability.authenticated {
            // Expected while the CLI login is expired: never runnable, explicit diagnostic.
            #expect(!report.capability.runnable)
            #expect(report.diagnostics.contains { $0.code == "claude.notAuthenticated" })
        }
        // The initialize handshake works even without login (spike 4b); if it fails, no built-in list.
        if report.diagnostics.contains(where: { $0.code == "claude.catalogFailed" }) {
            #expect(report.capability.modelCatalog.isEmpty)
            #expect(!report.capability.supportsModelSelection)
        } else {
            #expect(!report.capability.modelCatalog.isEmpty)
        }
    }
}
