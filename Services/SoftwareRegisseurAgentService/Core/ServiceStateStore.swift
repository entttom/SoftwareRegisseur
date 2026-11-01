import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC
import SoftwareRegisseurPersistence

/// Hostlokaler Zustand des Dienstes in der Tabelle `host_state` (Migration v3, nie synchronisiert).
///
/// Ablage unter dem Scope ``scope``:
/// - `hostId`, `deviceId`: stabile Kennungen dieses Macs (Ausführungshost bzw. Mac-Benutzergerät).
/// - `runState`: „läuft“/„pausiert“ – übersteht Dienstneustarts (D3).
/// - `rootFolders`: vom Benutzer bestätigte Stammordner (E1). Ohne Eintrag scannt der Dienst nichts.
/// - `settings`: ``ServiceSettings``.
/// - `ai.<request-uuid>`: Kontext-Manifest und Fehlermeldung je KI-Ausarbeitung (H4, Transparenz).
/// - `events.cursor`: Zeitpunkt der zuletzt ausgewerteten Verlaufseinträge (Markdown-Abgleich).
///
/// Die UI liest diese Werte nicht direkt; sie fragt sie über XPC ab (Format ist dienstintern).
struct ServiceStateStore: Sendable {
    static let scope = "agentService"

    let store: any HostStateStore
    let now: @Sendable () -> Date

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func load<T: Decodable>(_ type: T.Type, key: String) async throws -> T? {
        guard let data = try await store.value(scope: Self.scope, key: key) else { return nil }
        return try? Self.decoder.decode(T.self, from: data)
    }

    func save(_ value: some Encodable, key: String) async throws {
        try await store.setValue(Self.encoder.encode(value), scope: Self.scope, key: key, at: now())
    }

    func remove(key: String) async throws {
        try await store.removeValue(scope: Self.scope, key: key)
    }

    func keys() async throws -> [String] {
        try await store.keys(scope: Self.scope)
    }

    // MARK: Kennungen

    /// Liest oder erzeugt eine stabile UUID (erste Ausführung des Dienstes auf diesem Mac).
    func stableIdentifier(key: String) async throws -> UUID {
        if let existing = try await load(UUID.self, key: key) { return existing }
        let created = UUID()
        try await save(created, key: key)
        return created
    }

    // MARK: Betriebszustand

    func runState() async -> ServiceRunState {
        (try? await load(ServiceRunState.self, key: "runState")) ?? .running
    }

    func saveRunState(_ state: ServiceRunState) async throws {
        try await save(state, key: "runState")
    }

    // MARK: Stammordner

    struct RootFolder: Codable, Sendable, Hashable {
        var path: String
        var addedAt: Date
    }

    func rootFolders() async -> [RootFolder] {
        (try? await load([RootFolder].self, key: "rootFolders")) ?? []
    }

    func saveRootFolders(_ folders: [RootFolder]) async throws {
        try await save(folders, key: "rootFolders")
    }

    // MARK: Einstellungen

    func settings() async -> ServiceSettings {
        ((try? await load(ServiceSettings.self, key: "settings")) ?? ServiceSettings()).clamped
    }

    func saveSettings(_ settings: ServiceSettings) async throws {
        try await save(settings.clamped, key: "settings")
    }

    // MARK: KI-Ausarbeitungen

    struct AIElaborationRecord: Codable, Sendable, Hashable {
        var mode: MacAIElaborationMode
        var selectedFiles: [String]
        var info: MacAIElaborationInfo
    }

    func aiRecord(_ id: AIRequestID) async -> AIElaborationRecord? {
        try? await load(AIElaborationRecord.self, key: "ai.\(id.uuidString)")
    }

    func saveAIRecord(_ record: AIElaborationRecord) async throws {
        try await save(record, key: "ai.\(record.info.requestId.uuidString)")
    }
}
