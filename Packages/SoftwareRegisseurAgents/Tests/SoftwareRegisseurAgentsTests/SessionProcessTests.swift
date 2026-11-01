import Darwin
import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurProcess
import Testing
import SoftwareRegisseurAgents

/// Public contract for other modules (no `@testable`): launch plans are constructible and sessions
/// expose their process group for liveness checks (spec L1, A21).
@Suite("Session process identity and public launch plans", .timeLimit(.minutes(1)))
struct SessionProcessTests {
    @Test func launchPlanIsPubliclyConstructible() {
        let snapshot = ConfigurationSnapshot(
            providerId: .codex, requestedModel: .model("gpt-5.5-codex"), requestedEffort: .high,
            resolvedModel: .model("gpt-5.5-codex"), resolvedEffort: .high,
            profileSource: ProfileSources(model: .job, effort: .job), capabilityRevision: 1, agentVersion: "1.0.0",
            createdAt: Date(timeIntervalSinceReferenceDate: 0))
        let capability = AgentCapability(providerId: .codex, displayName: "Codex", hostId: HostID(), version: "1.0.0", supportsModelSelection: true, supportsEffortSelection: true, modelCatalog: [], capabilitySource: .appServer, capabilityRevision: 1,
                                         lastChecked: Date(timeIntervalSinceReferenceDate: 0),
                                         detectionTimestamp: Date(timeIntervalSinceReferenceDate: 0))
        let toolchain = AgentToolchain(executableURL: URL(filePath: "/usr/bin/true"), environment: ProcessEnvironment.minimal(),
                                       version: nil)
        let plan = AgentLaunchPlan(providerId: .codex, snapshot: snapshot, capability: capability,
                                   modelArgument: "gpt-5.5-codex", effortArgument: .high, toolchain: toolchain)
        #expect(LaunchPreparation.ready(plan).plan == plan)
        #expect(plan.resolvedModelName == nil)
    }

    @Test func claudeSessionExposesItsProcessGroup() async throws {
        let setup = try ClaudeCodeEndToEndTests.setup("ok")
        let session = try await ClaudeCodeEndToEndTests.start(setup, snapshot: Fixtures.snapshot(provider: .claudeCode))
        let pid = try #require(await session.processIdentifier)
        #expect(pid > 1)
        #expect(await session.processGroupIdentifier == pid)
        // Own process group (POSIX_SPAWN_SETPGROUP): kill(-pgid, 0) reaches it while it runs.
        #expect(getpgid(pid) == pid || kill(-pid, 0) == 0)
        let events = await runSession(session, decide: { _ in .allow })
        #expect(events.result?.outcome == .completed)
    }
}
