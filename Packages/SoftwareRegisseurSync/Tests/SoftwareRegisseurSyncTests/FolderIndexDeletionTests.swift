import CloudKit
import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence
@testable import SoftwareRegisseurSync
import SoftwareRegisseurSyncTesting
import Testing

/// ADR-0028: folder index entries the Mac removes (e.g. after narrowing the scan depth) are deleted on the
/// server instead of leaving a tombstone record per folder in iCloud.
@Suite("Folder index deletion on the server")
struct FolderIndexDeletionTests {
    let server = FakeCloudDatabase()
    let clock = TestClock()

    func devices() async throws -> (mac: SimulatedDevice, phone: SimulatedDevice) {
        let mac = try await SimulatedDevice.make("mac", role: .executionHost(Fixture.host), server: server, clock: clock)
        let phone = try await SimulatedDevice.make("phone", role: .mobile, server: server, clock: clock)
        return (mac, phone)
    }

    func folder(_ name: String, depth: Int) -> IndexedFolder {
        IndexedFolder(hostId: Fixture.host, canonicalPath: "/Users/me/Developer/\(name)", displayName: name,
                      kind: .plainFolder, scanRootPath: "/Users/me/Developer", depth: depth, isSelectable: true, lastSeenAt: t0)
    }

    func recordName(_ folder: IndexedFolder) -> String {
        SyncRecordSchema.recordName(.indexedFolder, folder.id.rawValue)
    }

    @Test("A removed folder disappears from iCloud and from the iPhone; nothing is left pending")
    func removedFolderIsDeletedOnServer() async throws {
        let (mac, phone) = try await devices()
        let kept = folder("app", depth: 1)
        let removed = folder("app/Sources/Deep", depth: 3)
        try await mac.database.indexedFolders.upsert(kept)
        try await mac.database.indexedFolders.upsert(removed)
        try await mac.sync()
        try await phone.sync()
        #expect(Set(try await phone.database.indexedFolders.selectable().map(\.canonicalPath)) == [kept.canonicalPath, removed.canonicalPath])

        try await mac.database.indexedFolders.delete(hostId: Fixture.host, path: removed.canonicalPath)
        let report = try await mac.sync()
        #expect(report.sendFailures == 0)
        let names = Set(await server.recordNames(in: SyncRecordSchema.zoneID))
        #expect(!names.contains(recordName(removed)))
        #expect(names.contains(recordName(kept)))
        #expect(await mac.status().pendingCount == 0)

        try await phone.sync()
        #expect(try await phone.database.indexedFolders.selectable().map(\.canonicalPath) == [kept.canonicalPath])

        // The Mac fetches its own deletion back: it converges without conflicts or re-uploads.
        let echo = try await mac.sync(.poll)
        #expect(echo.sent == 0)
        #expect(echo.sendFailures == 0)
        #expect(await mac.status().openConflictCount == 0)
        #expect(!Set(await server.recordNames(in: SyncRecordSchema.zoneID)).contains(recordName(removed)))
    }

    @Test("A folder added and removed before the next sync never reaches iCloud")
    func neverUploadedFolderLeavesNoRecord() async throws {
        let (mac, _) = try await devices()
        let transient = folder("tmp", depth: 1)
        try await mac.database.indexedFolders.upsert(transient)
        try await mac.database.indexedFolders.delete(hostId: Fixture.host, path: transient.canonicalPath)
        let report = try await mac.sync()
        #expect(report.sendFailures == 0)
        #expect(await server.recordNames(in: SyncRecordSchema.zoneID).isEmpty)
        #expect(await mac.status().pendingCount == 0)
    }

    @Test("A folder that comes back after its deletion is uploaded again")
    func folderComesBack() async throws {
        let (mac, phone) = try await devices()
        let entry = folder("app/Docs", depth: 2)
        try await mac.database.indexedFolders.upsert(entry)
        try await mac.sync()
        try await mac.database.indexedFolders.delete(hostId: Fixture.host, path: entry.canonicalPath)
        try await mac.sync()
        #expect(await server.recordNames(in: SyncRecordSchema.zoneID).isEmpty)

        // Scan depth raised again: the scanner records the folder anew.
        let again = folder("app/Docs", depth: 2)
        try await mac.database.indexedFolders.upsert(again)
        let report = try await mac.sync()
        #expect(report.sendFailures == 0)
        #expect(await mac.status().pendingCount == 0)
        try await phone.sync()
        #expect(try await phone.database.indexedFolders.selectable().map(\.canonicalPath) == [entry.canonicalPath])
    }

    @Test("Other kinds still upload tombstone records")
    func otherKindsKeepTombstones() {
        #expect(SyncRecordSchema.deletesRecordOnServer(.indexedFolder))
        for type in SyncEntityType.allCases where type != .indexedFolder {
            #expect(!SyncRecordSchema.deletesRecordOnServer(type))
        }
    }
}
