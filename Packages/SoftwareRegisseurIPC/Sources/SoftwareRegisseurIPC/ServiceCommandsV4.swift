import Foundation
import SoftwareRegisseurDomain

// Befehls- und Ergebnisdaten seit Protokoll 4: „Mit KI besprechen“ am Mac (H3). Das Gespräch wird als
// synchronisierte `AIConversation` gespeichert, ein Vorschlag daraus als eigene `DraftVersion` (Kanal
// `conversation`) – getrennt von Originalnotiz und Transkript. Das Gespräch startet nie einen Agenten.

/// Vorschlag aus „Mit KI besprechen“ als neue Entwurfsversion einer Aufgabe.
///
/// `draftId` erzeugt die UI einmal je Vorschlag: eine Wiederholung nach Zeitüberschreitung legt keine zweite
/// Version an (Idempotenz). Mit `accept == true` übernimmt der Dienst den Entwurf sofort in die Aufgabe
/// (ausdrückliche Bestätigung in der UI), geprüft gegen `expectedRevision`. Ohne Übernahme bleibt der Entwurf
/// als Version stehen und kann später mit `acceptDraftVersion`/`rejectDraftVersion` entschieden werden.
public struct ConversationDraftCommand: Codable, Sendable, Hashable {
    public var draftId: DraftVersionID
    public var workItemId: WorkItemID
    /// Der strukturierte Vorschlag (Titel, Ziel, Kontext, Akzeptanzkriterien …).
    public var content: DraftContent
    /// Text-KI-Anbieter (`openai`, `anthropic`, `gemini`), nicht der Coding-Agent (ADR-0006).
    public var providerId: String
    public var modelId: String
    /// Gespräch, aus dem der Vorschlag stammt; der Dienst vermerkt dort die Entwurfsversion.
    public var conversationId: AIConversationID?
    /// Token-Nutzung des Gesprächszugs, der den Vorschlag erzeugt hat (Transparenz, H3).
    public var usage: TokenUsage
    /// `true` = nach ausdrücklicher Bestätigung sofort in die Aufgabe übernehmen.
    public var accept: Bool
    /// Revision der gelesenen Aufgabe; nur bei `accept` maßgeblich (optimistische Prüfung).
    public var expectedRevision: Int

    public init(draftId: DraftVersionID = DraftVersionID(), workItemId: WorkItemID, content: DraftContent, providerId: String,
                modelId: String, conversationId: AIConversationID?, usage: TokenUsage = TokenUsage(), accept: Bool,
                expectedRevision: Int) {
        self.draftId = draftId
        self.workItemId = workItemId
        self.content = content
        self.providerId = providerId
        self.modelId = modelId
        self.conversationId = conversationId
        self.usage = usage
        self.accept = accept
        self.expectedRevision = expectedRevision
    }
}

/// Stand eines gespeicherten Gesprächs.
public struct ConversationSavedInfo: Codable, Sendable, Hashable {
    public var conversationId: AIConversationID
    public var workItemId: WorkItemID
    /// Gespeicherte Nachrichten (der Dienst behält bei veralteten Wiederholungen den längeren Stand).
    public var messageCount: Int
    public var usage: TokenUsage
    /// `false`, wenn das Gespräch schon gespeichert war (Fortschreibung).
    public var wasCreated: Bool

    public init(conversationId: AIConversationID, workItemId: WorkItemID, messageCount: Int, usage: TokenUsage, wasCreated: Bool) {
        self.conversationId = conversationId
        self.workItemId = workItemId
        self.messageCount = messageCount
        self.usage = usage
        self.wasCreated = wasCreated
    }
}

/// Ergebnis von ``ServiceRequest/appendConversationDraft(_:)``.
public struct ConversationDraftInfo: Codable, Sendable, Hashable {
    public var draftId: DraftVersionID
    public var workItemId: WorkItemID
    /// Versionsnummer der Entwurfsversion an der Aufgabe.
    public var version: Int
    /// In die Aufgabe übernommen.
    public var accepted: Bool
    /// `false`, wenn die Version mit dieser `draftId` schon existierte (Wiederholung).
    public var wasCreated: Bool
    /// Stand der Aufgabe nach der Übernahme; `nil` ohne Übernahme.
    public var workItem: WorkItemSavedInfo?
    /// Deutsche Rückmeldung für die UI.
    public var message: String

    public init(draftId: DraftVersionID, workItemId: WorkItemID, version: Int, accepted: Bool, wasCreated: Bool,
                workItem: WorkItemSavedInfo?, message: String) {
        self.draftId = draftId
        self.workItemId = workItemId
        self.version = version
        self.accepted = accepted
        self.wasCreated = wasCreated
        self.workItem = workItem
        self.message = message
    }
}

// MARK: - Gekürzte Freigaben (SR-SEC-08, seit Protokoll 4)

/// Vollständiger, redigierter Text einer Freigabeanfrage, deren synchronisierte Vorschau gekürzt ist. Nur der
/// ausführende Mac kennt ihn (hostlokal, nie synchronisiert). „Erlauben“ ist bei gekürzter Vorschau nur über
/// ``ServiceRequest/answerApprovalOnHost(approvalId:decision:message:fullTextConfirmed:)`` möglich, nachdem die UI
/// diesen Text angezeigt und der Benutzer das Lesen ausdrücklich bestätigt hat.
public struct ApprovalPreviewInfo: Codable, Sendable, Hashable {
    public var approvalId: PendingApprovalID
    /// Vollständiger Text; `nil`, wenn keine laufende Agentensitzung auf diesem Mac die Anfrage hält (dann nur Ablehnen).
    public var fullText: String?
    /// Länge der synchronisierten (ggf. gekürzten) Vorschau in Zeichen.
    public var shownLength: Int
    /// Länge des vollständigen Texts, falls die Vorschau gekürzt ist.
    public var fullLength: Int?
    /// Erlauben nur nach Anzeige und Bestätigung des Volltexts auf diesem Mac.
    public var allowRequiresHostReview: Bool
    /// Deutscher Hinweis, falls `fullText == nil`.
    public var detail: String?

    public init(approvalId: PendingApprovalID, fullText: String?, shownLength: Int, fullLength: Int?, allowRequiresHostReview: Bool,
                detail: String? = nil) {
        self.approvalId = approvalId
        self.fullText = fullText
        self.shownLength = shownLength
        self.fullLength = fullLength
        self.allowRequiresHostReview = allowRequiresHostReview
        self.detail = detail
    }
}
