import CloudKit
import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence
@testable import SoftwareRegisseurSync
import SoftwareRegisseurSyncTesting
import Testing

/// The Mac-owned workspace/approval entities and the user-wide settings between iPhone and Mac.
@Suite("Two-device sync of cross-device contracts")
struct ContractSyncTests {
    let server = FakeCloudDatabase()
    let clock = TestClock()

    func devices() async throws -> (mac: SimulatedDevice, phone: SimulatedDevice) {
        let mac = try await SimulatedDevice.make("mac", role: .executionHost(Fixture.host), server: server, clock: clock)
        let phone = try await SimulatedDevice.make("phone", role: .mobile, server: server, clock: clock)
        return (mac, phone)
    }

    @Test func mergePoliciesForNewEntityKinds() {
        #expect(SyncMergePolicy.policy(for: .projectSetupCommand) == .executionHostWins)
        #expect(SyncMergePolicy.policy(for: .indexedFolder) == .executionHostWins)
        #expect(SyncMergePolicy.policy(for: .pendingApproval) == .executionHostWins)
        #expect(SyncMergePolicy.policy(for: .approvalDecision) == .appendOnly)
        #expect(SyncMergePolicy.policy(for: .fileConflict) == .keepBothForUser)
        #expect(SyncMergePolicy.policy(for: .draftVersion) == .keepBothForUser)
        #expect(SyncMergePolicy.policy(for: .globalSettings) == .keepBothForUser)
        for type in [SyncEntityType.projectSetupCommand, .indexedFolder, .fileConflict, .pendingApproval, .approvalDecision,
                     .draftVersion, .globalSettings] {
            #expect(SyncRecordSchema.recordType(for: type) != nil)
            #expect(!type.isDeviceLocal)
        }
    }

    @Test("E2: folder index reaches the iPhone; a CreateProject command goes to the Mac and its state comes back")
    func setupCommandRoundTrip() async throws {
        let (mac, phone) = try await devices()
        let folder = IndexedFolder(hostId: Fixture.host, canonicalPath: "/Users/me/Developer/app", displayName: "app",
                                   kind: .gitRepository, scanRootPath: "/Users/me/Developer", depth: 1,
                                   documents: DetectedProjectDocuments(hasAgentsFile: true, readmeFiles: ["README.md"]),
                                   isSelectable: true, lastSeenAt: t0)
        try await mac.database.indexedFolders.upsert(folder)
        try await mac.sync()
        try await phone.sync()
        #expect(try await phone.database.indexedFolders.selectable() == [folder])

        let command = ProjectSetupCommand(kind: .createProject, projectName: "App", target: .indexedFolder(path: folder.canonicalPath),
                                          requestedBy: phone.deviceId, createdAt: t0)
        try command.validateStructure()
        try await phone.database.projectSetupCommands.insert(command, at: t0)
        try await phone.sync(.localChange)
        try await mac.sync(.poll)
        var onMac = try #require(try await mac.database.projectSetupCommands.fetch(command.id))
        #expect(onMac.isPending)
        let base = onMac.revision
        onMac.complete(resultPath: folder.canonicalPath, at: t0.addingTimeInterval(10))
        try await mac.database.projectSetupCommands.update(onMac, expectedRevision: base)
        try await mac.sync()
        try await phone.sync()
        let onPhone = try #require(try await phone.database.projectSetupCommands.fetch(command.id))
        #expect(onPhone.state == .completed && onPhone.resultPath == folder.canonicalPath)
        #expect(try await phone.database.sync.openConflicts().isEmpty)
    }

    @Test("J6 fallback: approval mirrored by the Mac, decided on the iPhone, decision relayed back")
    func approvalRelay() async throws {
        let (mac, phone) = try await devices()
        let approval = PendingApproval(jobId: JobID(), workItemId: WorkItemID(), hostId: Fixture.host, requestId: "perm-1",
                                       kind: .commandExecution, summary: "Befehl ausführen: swift test", preview: "swift test",
                                       allowedDecisions: [.allow, .deny], requestedAt: t0, expiresAt: t0.addingTimeInterval(3600))
        try await mac.database.approvals.save(approval, at: t0)
        try await mac.sync()
        try await phone.sync()
        let open = try await phone.database.approvals.openApprovals(hostId: nil)
        #expect(open == [approval])

        let decision = ApprovalDecision(for: approval, decision: .allow, decidedBy: phone.deviceId, at: t0.addingTimeInterval(30))
        try await phone.database.approvals.recordDecision(decision)
        try await phone.sync(.localChange)
        try await mac.sync(.poll)
        #expect(try await mac.database.approvals.decisions(approvalId: approval.id) == [decision])

        var answered = approval
        answered.recordAnswer(decision, at: t0.addingTimeInterval(31))
        try await mac.database.approvals.save(answered, at: t0.addingTimeInterval(31))
        try await mac.sync()
        try await phone.sync()
        #expect(try await phone.database.approvals.fetch(approval.id)?.state == .answered)
        #expect(try await phone.database.approvals.openApprovals(hostId: nil).isEmpty)
    }

    @Test func globalSettingsDraftsAndConflictRequestsSync() async throws {
        let (mac, phone) = try await devices()
        var settings = try await phone.database.globalSettings.fetch()
        settings.defaultAgentId = .codex
        settings.folderLayout.adrPath = "docs/decisions"
        let saved = try await phone.database.globalSettings.save(settings, expectedRevision: 0, at: t0)
        let draft = DraftVersion(workItemId: WorkItemID(), version: 1, source: .ai, channel: .conversation, providerId: .anthropic,
                                 modelId: "claude-sonnet-5", contents: [DraftContent(classification: .bug, title: "Absturz")],
                                 createdAt: t0)
        try await phone.database.draftVersions.save(draft, at: t0)
        let conflict = FileConflict(projectId: ProjectID(), location: "docs/requests/open/BUG-0001.md", kind: .concurrentEdit,
                                    databaseRevision: 3, detectedAt: t0)
        try await mac.database.fileConflicts.insert(conflict)
        try await phone.sync(.localChange)
        try await mac.sync()
        try await phone.sync()
        #expect(try await mac.database.globalSettings.fetch() == saved)
        #expect(try await mac.database.draftVersions.fetch(draft.id) == draft)
        _ = try await phone.database.fileConflicts.requestResolution(conflict.id, resolution: .keptDatabase, by: phone.deviceId,
                                                                      at: t0.addingTimeInterval(5))
        try await phone.sync(.localChange)
        try await mac.sync(.poll)
        #expect(try await mac.database.fileConflicts.pendingRequests().map(\.requestedResolution) == [.keptDatabase])
    }
}
