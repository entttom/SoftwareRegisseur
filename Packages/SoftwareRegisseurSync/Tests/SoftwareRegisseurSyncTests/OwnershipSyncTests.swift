import CloudKit
import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence
@testable import SoftwareRegisseurSync
import SoftwareRegisseurSyncTesting
import Testing

/// ADR-0026 / SR-SEC-01 (B05, B08, B11, B17): another device in the account cannot redirect the Mac.
@Suite("Ownership of execution-host data across devices (security audit 2026-10-30)")
struct OwnershipSyncTests {
    let server = FakeCloudDatabase()
    let clock = TestClock()

    @Test("Foreign device writes a RepositoryLocation with the Mac's hostId → the Mac ignores it")
    func foreignRepositoryLocationIsIgnoredByTheMac() async throws {
        let mac = try await SimulatedDevice.make("mac", role: .executionHost(Fixture.host), server: server, clock: clock)
        let attacker = try await SimulatedDevice.make("attacker", role: .mobile, server: server, clock: clock)
        let (project, settings) = Fixture.project()
        try await mac.database.projects.create(project, settings: settings, at: t0)
        let mine = RepositoryLocation(projectId: project.id, hostId: Fixture.host, canonicalPath: "/Users/me/Developer/app")
        try await mac.database.projects.saveLocation(mine, at: t0)
        try await mac.sync(.appLaunch)
        try await attacker.sync(.appLaunch)
        #expect(try await attacker.database.projects.locations(projectId: project.id) == [mine])

        // The attacker device rewrites the path of the Mac's repository location.
        var forged = mine
        forged.canonicalPath = "/Users/me/.ssh"
        try await attacker.database.projects.saveLocation(forged, at: t0.addingTimeInterval(5))
        try await attacker.sync(.localChange)
        clock.advance(by: 10)
        try await mac.sync(.poll)
        #expect(try await mac.database.projects.locations(projectId: project.id).map(\.canonicalPath) == ["/Users/me/Developer/app"])
        let rejected = try await mac.database.sync.resolvedConflicts(limit: 10)
            .filter { $0.resolution == RemoteOwnershipPolicy.rejectedResolution }
        #expect(rejected.count == 1 && rejected.first?.entityType == .repositoryLocation)

        // The Mac re-asserts its value; the other device converges back.
        try await mac.sync(.localChange)
        try await attacker.sync(.poll)
        #expect(try await attacker.database.projects.locations(projectId: project.id).map(\.canonicalPath) == ["/Users/me/Developer/app"])
    }

    @Test("A job request from the iPhone still reaches the Mac")
    func plainJobRequestIsAccepted() async throws {
        let mac = try await SimulatedDevice.make("mac", role: .executionHost(Fixture.host), server: server, clock: clock)
        let phone = try await SimulatedDevice.make("phone", role: .mobile, server: server, clock: clock)
        let (project, settings) = Fixture.project()
        try await mac.database.projects.create(project, settings: settings, at: t0)
        try await mac.sync(.appLaunch)
        try await phone.sync(.appLaunch)
        let item = Fixture.workItem(projectId: project.id)
        try await phone.database.workItems.insert(item, actor: phone.actor, at: t0)
        let job = Fixture.job(for: item)
        _ = try await phone.database.jobs.create(job, actor: phone.actor, at: t0.addingTimeInterval(1))
        try await phone.sync(.localChange)
        try await mac.sync(.poll)
        #expect(try await mac.database.jobs.fetch(job.jobId)?.state == .requested)
        #expect(try await mac.database.sync.resolvedConflicts(limit: 10).isEmpty)
    }

    @Test("SR-SEC-11: SecretGuard catches further token formats and key names")
    func secretGuardExtensions() {
        for value in ["eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N", "sk_live_51HxAbCdEfGhIjKlMnOp",
                      "npm_abcdefghijklmnopqrstuvwxyz0123456789", "ya29.a0AfH6SMBabcdefghijklmnopqrstu",
                      "https://hooks.slack.com/services/T000/B000/XXXXXXXX", "-----BEGIN OPENSSH PRIVATE KEY-----",
                      "AKIAABCDEFGHIJKLMNOP", "glpat-abcdefghijklmnopqrstuv"] {
            #expect(SecretGuard.looksLikeSecret(value), "\(value)")
        }
        for name in ["githubToken", "apiToken", "key", "signingKey", "deployKey", "webhookSecret", "dbPassword"] {
            #expect(SecretGuard.isForbiddenKeyName(name), "\(name)")
        }
        for name in ["idempotencyKey", "sortKey", "keychainReference", "inputTokens", "outputTokens", "tokenCount"] {
            #expect(!SecretGuard.isForbiddenKeyName(name), "\(name)")
        }
    }
}
