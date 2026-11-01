import SwiftUI
import SoftwareRegisseurAI
import SoftwareRegisseurAppCore
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

/// Context the iPhone may send (spec H3): the item itself plus synced project data (existing requests,
/// ADR index). Source code only comes from the Mac (H4).
enum ProjectContextBuilder {
    static func items(for item: WorkItem, database: AppDatabase) async throws -> [AIContextItem] {
        guard let projectId = item.projectId else { return [] }
        let others = try await database.workItems.list(WorkItemFilter(project: .project(projectId), limit: 200))
            .filter { $0.uuid != item.uuid }
        var result: [AIContextItem] = []
        if !others.isEmpty {
            let lines = others.map { other in
                "- [\(other.type.rawValue)] \(other.humanId?.formatted ?? "—") \(other.title) (\(other.status.rawValue))"
            }
            result.append(AIContextItem(id: "existing-requests", kind: .existingRequest,
                                        title: String(localized: "Bestehende Requests"), content: lines.joined(separator: "\n")))
        }
        let adrs = try await database.adrs.list(projectId: projectId)
        if !adrs.isEmpty {
            let lines = adrs.map { "- ADR \($0.decisionNumber): \($0.title) (\($0.status.rawValue))" }
            result.append(AIContextItem(id: "adr-index", kind: .adrIndex, title: String(localized: "ADR-Index"),
                                        content: lines.joined(separator: "\n")))
        }
        return result
    }
}

/// What will be sent, shown before every request (spec H3/H4).
struct ManifestView: View {
    let manifest: ContextManifest

    var body: some View {
        Section {
            LabeledContent { Text(manifest.provider.title) } label: { Text("Anbieter") }
            LabeledContent { Text(verbatim: manifest.model) } label: { Text("Modell") }
            LabeledContent {
                Text("ca. \(manifest.estimatedTokens) Tokens (geschätzt)")
            } label: {
                Text("Umfang")
            }
            ForEach(manifest.included) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Label {
                        Text(entry.kind.title)
                    } icon: {
                        Image(systemName: "checkmark.circle").foregroundStyle(.green)
                    }
                    Text("\(entry.characterCount) Zeichen")
                        .font(.caption).foregroundStyle(.secondary)
                    if entry.redactionCount > 0 {
                        Text("\(entry.redactionCount) mögliche Geheimnisse geschwärzt").font(.caption).foregroundStyle(.orange)
                    }
                    if entry.truncated {
                        Text("Gekürzt (Kontextbudget)").font(.caption).foregroundStyle(.orange)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            ForEach(manifest.excluded) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Label {
                        Text(entry.kind.title)
                    } icon: {
                        Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                    }
                    Text(entry.reason.message).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Wird übertragen")
        } footer: {
            Text("Notizinhalte werden als Daten gekennzeichnet, nicht als Anweisungen. Die KI startet nie einen Coding-Agenten.")
        }
    }
}

struct DraftContentView: View {
    let draft: StructuredDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(draft.type.title).font(.caption.bold()).foregroundStyle(.secondary)
                if let priority = DraftMapping.priority(draft.priority) {
                    Text(priority.title).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(verbatim: draft.title).font(.headline)
            field("Ziel", draft.goal)
            field("Kontext", draft.context)
            list("Akzeptanzkriterien", draft.acceptanceCriteria)
            list("Technische Hinweise", draft.technicalNotes)
            list("Testfälle", draft.testCases)
            list("Abhängigkeiten", draft.dependencies)
            if !draft.openQuestions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Offene Fragen", systemImage: "questionmark.bubble").font(.subheadline.bold()).foregroundStyle(.orange)
                    ForEach(draft.openQuestions, id: \.self) { Text(verbatim: "• \($0)").font(.callout) }
                }
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func field(_ title: LocalizedStringResource, _ value: String) -> some View {
        if !value.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(verbatim: value).font(.callout)
            }
        }
    }

    @ViewBuilder
    private func list(_ title: LocalizedStringResource, _ values: [String]) -> some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                ForEach(values, id: \.self) { Text(verbatim: "• \($0)").font(.callout) }
            }
        }
    }
}

/// Usage and cost, always marked as estimate (spec H3, I).
struct UsageView: View {
    @Environment(AppModel.self) private var model
    let usage: AIUsage
    let provider: SoftwareRegisseurAI.AIProviderID
    let modelID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Tokens: \(usage.inputTokens) Eingabe, \(usage.outputTokens) Ausgabe")
            if let seconds = usage.audioSeconds {
                Text("Audio: \(Int(seconds.rounded())) Sekunden")
            }
            if let estimate = model.costEstimator.estimate(usage: usage, provider: provider, model: modelID) {
                Text("Kosten: \(estimate.amount.formatted(.currency(code: estimate.currencyCode))) (geschätzt)")
                if !estimate.unpricedComponents.isEmpty {
                    Text("Ohne Preis: \(estimate.unpricedComponents.joined(separator: ", "))")
                }
            } else {
                Text("Kosten unbekannt – für dieses Modell ist kein Preis hinterlegt (Einstellungen › Kosten).")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// Text provider from settings + keychain, or the reason why none is usable.
enum TextProviderResolution {
    case ready(any TextAIProvider, model: String)
    case missingProvider
    case missingModel
    case missingKey(SoftwareRegisseurAI.AIProviderID)

    @MainActor
    static func resolve(_ model: AppModel) -> TextProviderResolution {
        guard let provider = model.settings.textProviderID else { return .missingProvider }
        guard let modelID = model.settings.textModel, !modelID.isEmpty else { return .missingModel }
        guard let client = try? model.keys.textProvider(provider) else { return .missingKey(provider) }
        return .ready(client, model: modelID)
    }
}

/// Explains a missing text-AI configuration and links to the fix (spec I: no dead options).
struct TextProviderSetupHint: View {
    let resolution: TextProviderResolution

    var body: some View {
        Section {
            switch resolution {
            case .ready:
                EmptyView()
            case .missingProvider, .missingModel:
                Text("Für die KI-Ausarbeitung ist noch kein Anbieter und Modell gewählt.")
            case let .missingKey(provider):
                Text("Für \(String(localized: provider.title)) ist kein API-Schlüssel für die KI-Ausarbeitung hinterlegt.")
            }
            NavigationLink("Zu den KI-Einstellungen") { AISettingsView() }
        } footer: {
            Text("Eigene Schlüssel (BYOK) bleiben im Schlüsselbund dieses Geräts.")
        }
    }
}
