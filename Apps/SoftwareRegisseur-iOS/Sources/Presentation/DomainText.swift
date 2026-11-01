import SwiftUI
import SoftwareRegisseurAI
import SoftwareRegisseurAppCore
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence
import SoftwareRegisseurSync

// User-facing names for domain values. All texts come from the String Catalog (spec P: no hard-coded UI
// strings); provider-native IDs (models, unknown effort levels) are shown verbatim (ADR-0006).

extension WorkItemStatus {
    var title: LocalizedStringResource {
        switch self {
        case .inbox: "Inbox"
        case .open: "Offen"
        case .queued: "In Warteschlange"
        case .scheduled: "Geplant"
        case .inProgress: "In Arbeit"
        case .waitingApproval: "Wartet auf Freigabe"
        case .implementationFinished: "Umsetzung beendet"
        case .review: "Review"
        case .integrated: "Integriert"
        case .done: "Erledigt"
        case .blocked: "Blockiert"
        case .failed: "Fehlgeschlagen"
        case .cancelled: "Abgebrochen"
        case .paused: "Pausiert"
        }
    }

    var symbol: String {
        switch self {
        case .inbox: "tray"
        case .open: "circle"
        case .queued: "hourglass"
        case .scheduled: "calendar.badge.clock"
        case .inProgress: "gearshape.2"
        case .waitingApproval: "hand.raised"
        case .implementationFinished: "flag.checkered"
        case .review: "eye"
        case .integrated: "arrow.triangle.merge"
        case .done: "checkmark.circle.fill"
        case .blocked: "exclamationmark.octagon"
        case .failed: "xmark.octagon"
        case .cancelled: "xmark.circle"
        case .paused: "pause.circle"
        }
    }

    var tint: Color {
        switch self {
        case .done, .integrated: .green
        case .failed, .blocked: .red
        case .inProgress, .waitingApproval: .orange
        case .review, .implementationFinished: .purple
        case .queued, .scheduled: .blue
        default: .secondary
        }
    }
}

extension WorkItemType {
    var title: LocalizedStringResource {
        switch self {
        case .feature: "Feature Request"
        case .bug: "Bug Report"
        case .todo: "Todo"
        case .improvement: "Verbesserung"
        case .note: "Notiz"
        }
    }

    var symbol: String {
        switch self {
        case .feature: "sparkles"
        case .bug: "ladybug"
        case .todo: "checklist"
        case .improvement: "wand.and.stars"
        case .note: "note.text"
        }
    }
}

extension Priority {
    var title: LocalizedStringResource {
        switch self {
        case .low: "Niedrig"
        case .medium: "Mittel"
        case .high: "Hoch"
        case .urgent: "Dringend"
        }
    }
}

extension TaskComplexity {
    var title: LocalizedStringResource {
        switch self {
        case .small: "Klein"
        case .medium: "Mittel"
        case .large: "Groß"
        }
    }
}

extension ProjectStatus {
    var title: LocalizedStringResource {
        switch self {
        case .pendingMacSetup: "Einrichtung am Mac ausstehend"
        case .ready: "Bereit"
        case .unavailable: "Nicht erreichbar"
        case .needsAttention: "Benötigt Aufmerksamkeit"
        case .archived: "Archiviert"
        }
    }

    var tint: Color {
        switch self {
        case .ready: .green
        case .pendingMacSetup: .blue
        case .unavailable, .needsAttention: .orange
        case .archived: .secondary
        }
    }
}

extension RepositoryKind {
    var title: LocalizedStringResource {
        switch self {
        case .gitRepository: "Bestehendes Git-Repository"
        case .notARepository: "Noch kein Repository"
        case .subfolderOfRepository: "Unterordner eines Repositories"
        }
    }
}

extension AgentJobState {
    var title: LocalizedStringResource {
        switch self {
        case .requested: "Angefordert"
        case .pendingMac: "Wartet auf Mac"
        case .scheduled: "Geplant"
        case .admitted: "Zugelassen"
        case .starting: "Startet"
        case .running: "Agent arbeitet"
        case .finished: "Beendet"
        case .needsConfiguration: "Konfiguration erforderlich"
        case .waitingApproval: "Wartet auf Bestätigung"
        case .waitingQuota: "Wartet auf Kontingent"
        case .paused: "Pausiert"
        case .failed: "Fehlgeschlagen"
        case .cancelled: "Abgebrochen"
        }
    }
}

extension EffortLevel {
    var title: LocalizedStringResource {
        switch self {
        case .auto: "Automatisch (Anbieterstandard)"
        case .low: "Niedrig"
        case .medium: "Mittel"
        case .high: "Hoch"
        case .xhigh: "Extra hoch"
        case .max: "Maximum"
        default: "\(rawValue)"
        }
    }

    var explanation: LocalizedStringResource? {
        switch self {
        case .auto: "Der Agent wählt die Stufe selbst; es wird kein Wert übergeben."
        case .low: "Schnell und sparsam, für klar umrissene Aufgaben."
        case .medium: "Ausgewogen zwischen Laufzeit und Gründlichkeit."
        case .high: "Gründlicher, längere Laufzeit und höherer Kontingentverbrauch."
        case .xhigh, .max: "Maximale Denkzeit; deutlich längere Laufzeit und höherer Verbrauch."
        default: nil
        }
    }
}

extension ModelSelection {
    var title: LocalizedStringResource {
        switch self {
        case .providerDefault: "Anbieterstandard"
        case let .model(id): "\(id.rawValue)"
        }
    }
}

extension ProfileSource {
    var title: LocalizedStringResource {
        switch self {
        case .job: "dieser Auftrag"
        case .project: "Projektstandard"
        case .global: "globaler Standard"
        case .providerDefault: "Anbieterstandard"
        }
    }
}

extension ModelAvailability {
    var title: LocalizedStringResource {
        switch self {
        case .available: "Verfügbar"
        case .notEntitled: "Für dieses Konto nicht freigeschaltet"
        case .deprecated: "Abgekündigt"
        case .unavailable: "Nicht verfügbar"
        }
    }
}

extension ConfigurationIssue {
    var message: LocalizedStringResource {
        switch self {
        case let .providerMismatch(expected, found):
            "Die Einstellung gehört zu Agent „\(found.rawValue)“, erwartet wird „\(expected.rawValue)“."
        case .preferenceScopeMismatch:
            "Eine Voreinstellung hat einen falschen Geltungsbereich."
        case let .modelSelectionNotSupported(model):
            "Der Agent erlaubt keine Modellwahl; „\(model.rawValue)“ kann nicht gesetzt werden."
        case let .unknownModel(model):
            "Modell „\(model.rawValue)“ ist in der installierten Agentenversion nicht verfügbar."
        case let .modelUnavailable(model, _):
            "Modell „\(model.rawValue)“ ist derzeit nicht nutzbar."
        case .effortSelectionNotSupported:
            "Die Denkstufe ist bei diesem Agenten nicht einstellbar (Anbieterstandard – nicht einstellbar)."
        case let .effortNotSupportedByModel(effort, model):
            "Modell „\(model.rawValue)“ unterstützt die Stufe „\(effort.rawValue)“ nicht."
        case let .effortRequiresKnownModel(effort):
            "Die Stufe „\(effort.rawValue)“ erfordert ein ausdrücklich gewähltes Modell."
        }
    }
}

extension JobRequestBlocker {
    var message: LocalizedStringResource {
        switch self {
        case .noAgentSelected: "Bitte einen Agenten wählen."
        case .workItemWithoutProject: "Die Aufgabe ist keinem Projekt zugeordnet. Bitte zuerst ein Projekt zuweisen."
        case let .agentNotReported(provider): "Agent „\(provider.rawValue)“ wurde vom Mac nicht gemeldet."
        case let .agentNotReady(provider): "Agent „\(provider.rawValue)“ ist am Mac nicht startbereit (Installation oder Anmeldung prüfen)."
        case .workItemNotStartable: "In diesem Aufgabenstatus kann kein Agentenlauf angelegt werden."
        case .activeJobExists: "Für diese Aufgabe gibt es bereits einen aktiven Agentenlauf."
        case .configuration: "Diese Kombination aus Modell und Denkstufe ist nicht zulässig."
        case .scheduleInvalid: "Der gewählte Zeitpunkt ist ungültig."
        case .scheduleInPast: "Der gewählte Zeitpunkt liegt in der Vergangenheit."
        }
    }
}

extension ReviewDecision {
    var title: LocalizedStringResource {
        switch self {
        case .pending: "Offen"
        case .approved: "Zur Übernahme freigegeben"
        case .changesRequested: "Änderungen angefordert"
        case .rejected: "Abgelehnt"
        }
    }
}

extension TestOutcome {
    var title: LocalizedStringResource {
        switch self {
        case .passed: "Bestanden"
        case .failed: "Fehlgeschlagen"
        case .skipped: "Übersprungen"
        case .notRun: "Nicht ausgeführt"
        }
    }

    var symbol: String {
        switch self {
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .skipped: "arrow.uturn.right.circle"
        case .notRun: "circle.dashed"
        }
    }

    var tint: Color {
        switch self {
        case .passed: .green
        case .failed: .red
        default: .secondary
        }
    }
}

extension IntegrationStrategy {
    var title: LocalizedStringResource {
        switch self {
        case .squash: "Squash-Merge"
        case .mergeCommit: "Merge-Commit"
        case .cherryPick: "Cherry-pick"
        }
    }
}

extension ReviewAction {
    var title: LocalizedStringResource {
        switch self {
        case .approveIntegration: "Übernahme freigeben"
        case .requestChanges: "Änderungen anfordern"
        case .reject: "Ablehnen"
        case .markDone: "Als erledigt bestätigen"
        }
    }
}

extension DraftMode {
    var title: LocalizedStringResource {
        switch self {
        case .kurz: "Kurz ausarbeiten"
        case .ausfuehrlich: "Ausführlich"
        case .akzeptanzkriterienErgaenzen: "Akzeptanzkriterien ergänzen"
        case .technischeDetails: "Technische Details"
        case .inAufgabenAufteilen: "In Aufgaben aufteilen"
        }
    }
}

extension DraftType {
    var title: LocalizedStringResource {
        switch self {
        case .todo: "Todo"
        case .feature: "Feature Request"
        case .bug: "Bug Report"
        case .improvement: "Verbesserung"
        case .adr: "ADR-Vorschlag"
        case .note: "Notiz"
        }
    }
}

extension AIContextKind {
    var title: LocalizedStringResource {
        switch self {
        case .originalNote: "Originalnotiz"
        case .transcript: "Transkript"
        case .currentDraft: "Aktueller Entwurf"
        case .existingRequest: "Bestehender Request"
        case .adrIndex: "ADR-Index"
        case .repositoryStructure: "Repository-Struktur"
        case .sourceFile: "Quellcodedatei"
        case .other: "Sonstiger Kontext"
        }
    }
}

extension ContextExclusionReason {
    var message: LocalizedStringResource {
        switch self {
        case let .secretPath(pattern): "Ausgeschlossen: mögliche Geheimnisse (Muster „\(pattern)“)"
        case .overBudget: "Ausgeschlossen: Kontextbudget überschritten"
        case .empty: "Ausgeschlossen: leer"
        }
    }
}

extension SoftwareRegisseurAI.AIProviderID {
    var title: LocalizedStringResource {
        switch self {
        case .openai: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Google Gemini"
        default: "\(rawValue)"
        }
    }
}

extension KeyPurpose {
    var title: LocalizedStringResource {
        switch self {
        case .transcription: "Transkription"
        case .text: "KI-Ausarbeitung"
        }
    }
}

extension TranscriptionMethod {
    var title: LocalizedStringResource {
        switch self {
        case .appleSpeech: "Apple-Spracherkennung"
        case .openAI: "OpenAI Speech-to-Text"
        }
    }
}

extension PermissionKind {
    var title: LocalizedStringResource {
        switch self {
        case .microphone: "Mikrofon"
        case .speechRecognition: "Spracherkennung"
        }
    }

    var symbol: String {
        switch self {
        case .microphone: "mic.fill"
        case .speechRecognition: "waveform"
        }
    }

    var explanation: LocalizedStringResource {
        switch self {
        case .microphone:
            DeviceKind.current.pick(
                phone: "Software Regisseur nimmt gesprochene Ideen auf, damit Sie Aufgaben unterwegs diktieren können. Die Aufnahme bleibt auf diesem iPhone, solange Sie keine Übertragung an einen Transkriptionsanbieter bestätigen.",
                pad: "Software Regisseur nimmt gesprochene Ideen auf, damit Sie Aufgaben diktieren können. Die Aufnahme bleibt auf diesem iPad, solange Sie keine Übertragung an einen Transkriptionsanbieter bestätigen."
            )
        case .speechRecognition:
            DeviceKind.current.pick(
                phone: "Für die Apple-Spracherkennung wandelt das iPhone Ihre Aufnahme in Text um. Mit installiertem Sprachmodell geschieht das auf dem Gerät.",
                pad: "Für die Apple-Spracherkennung wandelt das iPad Ihre Aufnahme in Text um. Mit installiertem Sprachmodell geschieht das auf dem Gerät."
            )
        }
    }

    var deniedConsequence: LocalizedStringResource {
        switch self {
        case .microphone:
            "Ohne Mikrofonzugriff sind Sprachaufnahmen nicht möglich. Texterfassung, Aufgaben und KI-Ausarbeitung funktionieren weiterhin."
        case .speechRecognition:
            "Ohne Spracherkennung kann die Apple-Transkription nicht genutzt werden. Sie können stattdessen in den Einstellungen die OpenAI-Transkription wählen oder Text eintippen."
        }
    }
}

extension SyncAttention {
    var message: LocalizedStringResource {
        switch self {
        case .accountSignedOut:
            "Kein iCloud-Account angemeldet. Die Synchronisierung ist pausiert; lokale Daten bleiben erhalten."
        case .accountSwitched:
            "Der iCloud-Account wurde gewechselt. Die Synchronisierung ist pausiert, bis Sie bestätigen, mit dem neuen Account fortzufahren. Lokale Daten bleiben erhalten."
        case .zoneDeleted:
            "Die iCloud-Daten von Software Regisseur wurden gelöscht oder zurückgesetzt. Lokale Daten bleiben erhalten; Sie entscheiden, ob sie erneut hochgeladen werden."
        case let .openConflicts(count):
            "\(count) Synchronisierungskonflikt(e) warten auf Ihre Entscheidung."
        case let .secretsBlocked(count):
            "\(count) Änderung(en) enthalten vermutlich Zugangsdaten und werden nicht synchronisiert."
        case let .invalidRemoteRecords(count):
            "\(count) Datensätze aus iCloud konnten nicht gelesen werden."
        case .newerSchema:
            "Ein anderes Gerät nutzt eine neuere Version von Software Regisseur. Bitte aktualisieren Sie diese App."
        case .iCloudQuotaExceeded:
            "Der iCloud-Speicher ist voll. Neue Änderungen bleiben lokal, bis wieder Speicher frei ist."
        case .cloudDataDeletedByUser:
            DeviceKind.current.pick(
                phone: "Ihre iCloud-Daten wurden auf Ihren Wunsch gelöscht. Die Synchronisierung ist pausiert; lokale Daten bleiben auf diesem iPhone. Erst mit „Wieder mit iCloud synchronisieren“ werden sie erneut hochgeladen.",
                pad: "Ihre iCloud-Daten wurden auf Ihren Wunsch gelöscht. Die Synchronisierung ist pausiert; lokale Daten bleiben auf diesem iPad. Erst mit „Wieder mit iCloud synchronisieren“ werden sie erneut hochgeladen."
            )
        case .cloudDataDeletionPending:
            "Das Löschen der iCloud-Daten ist noch nicht abgeschlossen. Die Synchronisierung bleibt pausiert, bis iCloud das Löschen bestätigt."
        }
    }
}

extension CloudSyncUnavailableReason {
    var message: LocalizedStringResource {
        switch self {
        case .unsignedBuild:
            DeviceKind.current.pick(
                phone: "Dieser Build ist nicht signiert und hat daher keine iCloud-Berechtigung. Alle Daten bleiben lokal auf diesem iPhone; Änderungen werden gesammelt und mit einem signierten Build synchronisiert.",
                pad: "Dieser Build ist nicht signiert und hat daher keine iCloud-Berechtigung. Alle Daten bleiben lokal auf diesem iPad; Änderungen werden gesammelt und mit einem signierten Build synchronisiert."
            )
        case .placeholderSigning:
            "In Config/Local.xcconfig ist noch kein Apple-Team eingetragen; ohne Signierung gibt es keine iCloud-Berechtigung. Die App arbeitet lokal."
        case .missingContainer:
            "Kein gültiger CloudKit-Container konfiguriert (SR_CLOUDKIT_CONTAINER). Die App arbeitet lokal."
        }
    }
}

extension WorkItemConflictComparison.Field {
    var title: LocalizedStringResource {
        switch self {
        case .title: "Titel"
        case .status: "Status"
        case .priority: "Priorität"
        case .transcript: "Transkript"
        case .structuredBody: "Beschreibung"
        case .labels: "Labels"
        case .dependencies: "Abhängigkeiten"
        case .projectId: "Projekt"
        case .reviewState: "Review-Status"
        case .complexity: "Komplexität"
        }
    }
}

extension SyncEntityType {
    var title: LocalizedStringResource {
        switch self {
        case .project: "Projekt"
        case .projectSettings: "Projekteinstellungen"
        case .workItem: "Aufgabe"
        case .adr: "ADR"
        case .review: "Review"
        case .agentModelPreference: "Agenten-Voreinstellung"
        case .aiRequest: "KI-Anfrage"
        case .aiConversation: "KI-Gespräch"
        case .gitHubIssueLink: "GitHub-Issue-Verknüpfung"
        case .providerProfile: "Anbieterprofil"
        case .projectSetupCommand: "Projekteinrichtung"
        case .fileConflict: "Dateikonflikt"
        case .draftVersion: "Entwurfsversion"
        case .globalSettings: "Globale Einstellungen"
        case .approvalDecision: "Freigabe-Entscheidung"
        default: "\(rawValue)"
        }
    }
}

/// Human ID or the ADR-0018 placeholder.
func humanIDText(_ item: WorkItem) -> LocalizedStringResource {
    if let id = item.humanId { return "\(id.formatted)" }
    return "Noch keine Nummer"
}
