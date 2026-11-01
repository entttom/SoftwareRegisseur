import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

/// Zusammenführen eines Sync-Konflikts mit Textfeldern (A24, N2): je Feld Vorfahr (falls bekannt), Stand
/// dieses Macs und iCloud-Stand; der Benutzer schreibt den zusammengeführten Text. Das Ergebnis geht als
/// `.merged(Data)` im gespeicherten Payload-Format (`SyncPayloadCodec`) an den Dienst.
///
/// Unterstützt Aufgaben (Titel, Inhalt, Transkript) und ADRs (Titel und Abschnitte). Andere Datensätze
/// haben keine freien Texte; dort bleiben „Stand behalten“ und „iCloud übernehmen“.
struct SyncConflictMerge: Hashable, Sendable {
    enum Field: String, Hashable, Sendable, CaseIterable, Identifiable {
        case title, structuredBody, transcript
        case context, decision, alternatives, consequences

        var id: Self { self }

        var displayName: String {
            switch self {
            case .title: String(localized: "Titel")
            case .structuredBody: String(localized: "Inhalt")
            case .transcript: String(localized: "Transkript")
            case .context: String(localized: "Kontext")
            case .decision: String(localized: "Entscheidung")
            case .alternatives: String(localized: "Erwogene Alternativen")
            case .consequences: String(localized: "Konsequenzen")
            }
        }
    }

    struct FieldVersions: Hashable, Sendable, Identifiable {
        let field: Field
        let ancestor: String?
        let local: String
        let remote: String
        var id: Field { field }

        /// Vorschlag für den zusammengeführten Text: unverändert gebliebene Seite übernimmt die andere, sonst
        /// der eigene Stand (der Benutzer entscheidet).
        var suggestion: String {
            if let ancestor {
                if local == ancestor { return remote }
                if remote == ancestor { return local }
            }
            return local
        }
    }

    let entityType: SyncEntityType
    let localPayload: Data
    /// Felder, deren Text sich zwischen beiden Ständen unterscheidet.
    let fields: [FieldVersions]

    init?(conflict: SyncConflict) {
        self.init(entityType: conflict.entityType, ancestor: conflict.ancestorPayload, local: conflict.localPayload,
                  remote: conflict.remotePayload)
    }

    /// `nil`, wenn eine Seite gelöscht wurde, der Typ keine Textfelder hat oder sich kein Text unterscheidet.
    init?(entityType: SyncEntityType, ancestor: Data?, local: Data?, remote: Data?) {
        guard let local, let remote else { return nil }
        let localTexts: [Field: String]
        let remoteTexts: [Field: String]
        let ancestorTexts: [Field: String]?
        switch entityType {
        case .workItem:
            guard let l = try? SyncPayloadCodec.decode(WorkItem.self, from: local),
                  let r = try? SyncPayloadCodec.decode(WorkItem.self, from: remote) else { return nil }
            localTexts = Self.texts(l)
            remoteTexts = Self.texts(r)
            ancestorTexts = ancestor.flatMap { try? SyncPayloadCodec.decode(WorkItem.self, from: $0) }.map(Self.texts)
        case .adr:
            guard let l = try? SyncPayloadCodec.decode(ADR.self, from: local),
                  let r = try? SyncPayloadCodec.decode(ADR.self, from: remote) else { return nil }
            localTexts = Self.texts(l)
            remoteTexts = Self.texts(r)
            ancestorTexts = ancestor.flatMap { try? SyncPayloadCodec.decode(ADR.self, from: $0) }.map(Self.texts)
        default:
            return nil
        }
        let fields = Field.allCases.compactMap { field -> FieldVersions? in
            guard let l = localTexts[field], let r = remoteTexts[field], l != r else { return nil }
            return FieldVersions(field: field, ancestor: ancestorTexts?[field], local: l, remote: r)
        }
        guard !fields.isEmpty else { return nil }
        self.entityType = entityType
        localPayload = local
        self.fields = fields
    }

    var initialValues: [Field: String] {
        Dictionary(uniqueKeysWithValues: fields.map { ($0.field, $0.suggestion) })
    }

    /// Payload aus dem lokalen Stand mit den zusammengeführten Texten.
    func mergedPayload(_ values: [Field: String]) throws -> Data {
        switch entityType {
        case .workItem:
            var item = try SyncPayloadCodec.decode(WorkItem.self, from: localPayload)
            for (field, value) in values {
                switch field {
                case .title: item.title = value
                case .structuredBody: item.structuredBody = value
                case .transcript: item.transcript = value.isEmpty ? nil : value
                default: break
                }
            }
            return try SyncPayloadCodec.encode(item)
        default:
            var adr = try SyncPayloadCodec.decode(ADR.self, from: localPayload)
            for (field, value) in values {
                switch field {
                case .title: adr.title = value
                case .context: adr.context = value
                case .decision: adr.decision = value
                case .alternatives: adr.alternatives = value
                case .consequences: adr.consequences = value
                default: break
                }
            }
            return try SyncPayloadCodec.encode(adr)
        }
    }

    private static func texts(_ item: WorkItem) -> [Field: String] {
        [.title: item.title, .structuredBody: item.structuredBody, .transcript: item.transcript ?? ""]
    }

    private static func texts(_ adr: ADR) -> [Field: String] {
        [.title: adr.title, .context: adr.context, .decision: adr.decision, .alternatives: adr.alternatives,
         .consequences: adr.consequences]
    }
}
