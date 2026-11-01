import Foundation
import Observation
import SoftwareRegisseurAI

/// „Mit KI besprechen“ (spec H3). The context manifest of every turn is shown before it is sent; a proposed
/// draft is only returned to the caller after explicit acceptance. This type has no agent access.
@MainActor
@Observable
public final class ConversationController {
    public enum Phase: Hashable, Sendable {
        case composing
        /// Manifest is visible; the user confirms sending.
        case reviewingContext(PreparedConversationTurn)
        case sending
        case failed(String)
    }

    public private(set) var phase: Phase = .composing
    public private(set) var turns: [ConversationTurn] = []
    public private(set) var pendingProposal: StructuredDraft?
    public private(set) var usage = AIUsage.zero
    /// Number of requests actually sent to the provider.
    public private(set) var sentRequestCount = 0

    private let session: ConversationSession

    public init(session: ConversationSession) {
        self.session = session
    }

    public var providerID: AIProviderID { session.provider.providerID }
    public var model: String { session.model }

    /// Step 1: builds the request and shows its manifest. Nothing is sent.
    public func prepare(message: String) async {
        do {
            phase = .reviewingContext(try await session.prepare(userMessage: message))
        } catch let error as AIProviderError {
            phase = .failed(error.userMessage())
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Step 2: sends exactly the prepared request.
    public func confirmSend() async {
        guard case let .reviewingContext(prepared) = phase else { return }
        phase = .sending
        do {
            sentRequestCount += 1
            let reply = try await session.send(prepared)
            turns = await session.history
            pendingProposal = await session.pendingProposal
            usage = usage + reply.usage
            phase = .composing
        } catch let error as AIProviderError {
            phase = .failed(error.userMessage())
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Narrows the synced project data sent with the next turn (deselected items are not sent).
    public func setProjectContext(_ items: [AIContextItem]) async {
        await session.setProjectContext(items)
    }

    public func cancelPrepared() {
        if case .reviewingContext = phase { phase = .composing }
    }

    public func dismissError() {
        if case .failed = phase { phase = .composing }
    }

    /// Explicit acceptance: returns the proposal to be written as a new draft version.
    public func acceptProposal() async -> StructuredDraft? {
        let accepted = await session.acceptProposal()
        pendingProposal = nil
        return accepted
    }

    public func discardProposal() async {
        await session.discardProposal()
        pendingProposal = nil
    }
}
