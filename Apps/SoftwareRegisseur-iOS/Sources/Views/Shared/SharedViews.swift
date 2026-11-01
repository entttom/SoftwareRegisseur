import SwiftUI
import SoftwareRegisseurAI
import SoftwareRegisseurAppCore
import SoftwareRegisseurPersistence
import SoftwareRegisseurDomain
import SoftwareRegisseurSync

extension Color {
    /// Secondary text for caption-sized metadata (status, priority, number). The system `secondaryLabel`
    /// stays just under 4.5:1 at caption size and failed the contrast audit in light mode (A29);
    /// this grey keeps the hierarchy with ≥ 4.5:1 on the list backgrounds in light and dark mode.
    static let metadata = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.70, alpha: 1) : UIColor(white: 0.36, alpha: 1)
    })
}

/// Metadata text style: the high-contrast grey on normal rows, the system's secondary style on a
/// selected row (iPad split view), where a fixed grey would sit on the accent-coloured selection.
struct MetadataStyle: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> AnyShapeStyle {
        environment.backgroundProminence == .increased ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.metadata)
    }
}

extension ShapeStyle where Self == MetadataStyle {
    static var metadata: MetadataStyle { MetadataStyle() }
}

/// Status label with symbol and text (spec P: colours/symbols complement text, never replace it).
struct StatusBadge: View {
    let title: LocalizedStringResource
    let symbol: String
    var tint: Color = .secondary
    @Environment(\.backgroundProminence) private var backgroundProminence

    var body: some View {
        // Coloured symbol, text in the label colour: green/orange/blue caption text on the list
        // background fails the contrast audit (A29). The text alone still carries the meaning.
        Label {
            Text(title)
                .foregroundStyle(tint == .secondary ? AnyShapeStyle(.metadata) : AnyShapeStyle(.primary))
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(backgroundProminence == .increased ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
        }
        .font(.caption)
        .labelStyle(.titleAndIcon)
    }
}

/// Reachability of a Mac host: coloured symbol plus text in the label colour (A29 contrast).
struct HostReachabilityText: View {
    let offline: Bool

    var body: some View {
        Label {
            Text(offline ? "Offline" : "Erreichbar")
                .foregroundStyle(Color(.label))
        } icon: {
            Image(systemName: offline ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(offline ? .orange : .green)
        }
        .labelStyle(.titleAndIcon)
    }
}

struct WorkItemRow: View {
    let item: WorkItem
    var projectName: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: item.type.symbol)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(item.title.isEmpty ? String(localized: "Ohne Titel") : item.title)
                    .font(.body)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
            }
            // Status, priority and number stack at accessibility text sizes instead of being cut off.
            AccessibleRowLayout(spacing: 10) {
                StatusBadge(title: item.status.title, symbol: item.status.symbol, tint: item.status.tint)
                // High priority stands out by weight and label colour (orange text failed the contrast audit, A29).
                Text(item.priority.title)
                    .font(.caption)
                    .fontWeight(item.priority >= .high ? .semibold : .regular)
                    .foregroundStyle(item.priority >= .high ? AnyShapeStyle(.primary) : AnyShapeStyle(.metadata))
                Text(humanIDText(item))
                    .font(.caption.monospaced())
                    .foregroundStyle(.metadata)
            }
            if let projectName {
                Text(projectName)
                    .font(.caption)
                    .foregroundStyle(.metadata)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Horizontal metadata line that becomes a vertical stack at accessibility text sizes (A29).
struct AccessibleRowLayout<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder let content: () -> Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: spacing))
        layout(content)
    }
}

/// Inline error with a concrete next step (spec P: „Fehlermeldungen mit konkreten Handlungsmöglichkeiten“).
struct ErrorText: View {
    let message: String

    var body: some View {
        // Red symbol, text in the label colour: red callout text misses the contrast minimum (A29).
        Label {
            Text(message)
                .foregroundStyle(Color(.label))
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
        .font(.callout)
    }
}

/// Sync status (A26: last sync time and state visible without push).
struct SyncStatusSection: View {
    @Environment(AppModel.self) private var model
    var showsDetails = true
    @State private var deletionRetryError: String?

    var body: some View {
        Section {
            switch model.cloudAvailability {
            case let .unavailable(reason):
                // Plain stack instead of `Label`: inside the label's title slot both texts were measured
                // shorter than their lines and reported as clipped by the accessibility audit (A29).
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: "icloud.slash")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("iCloud-Synchronisierung nicht verfügbar")
                            .font(.headline)
                        Text(reason.message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("sync.unavailable")
            case .available:
                availableContent
            }
        } header: {
            Text("Synchronisierung")
        } footer: {
            if showsDetails {
                Text("Keine Push-Benachrichtigungen: Abgleich beim Öffnen, beim Aktivieren der App, durch Herunterziehen und manuell. Der Mac übernimmt Aufträge, sobald er erreichbar ist.")
            }
        }
    }

    @ViewBuilder
    private var availableContent: some View {
        let status = model.syncStatus
        if let error = model.syncStartError {
            ErrorText(message: error)
        }
        LabeledContent {
            if status.isSyncing {
                ProgressView()
            } else if let date = status.lastSuccessfulFetch {
                Text(date, format: .relative(presentation: .named))
            } else {
                Text("Noch nie")
            }
        } label: {
            Text("Zuletzt abgeglichen")
        }
        .accessibilityIdentifier("sync.lastSync")
        if showsDetails {
            LabeledContent {
                Text(status.pendingCount, format: .number)
            } label: {
                Text("Noch nicht übertragen")
            }
        }
        if let error = status.lastError {
            ErrorText(message: error)
        }
        ForEach(status.attention, id: \.self) { attention in
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(attention.message)
                } icon: {
                    Image(systemName: "exclamationmark.icloud")
                }
                .foregroundStyle(.orange)
                switch attention {
                case .accountSwitched:
                    Button("Mit neuem Account fortfahren") { Task { await model.acknowledgeAccountChange() } }
                case .zoneDeleted:
                    Button("Lokale Daten erneut hochladen") { Task { await model.recreateZone() } }
                case .cloudDataDeletedByUser:
                    Button("Wieder mit iCloud synchronisieren") { Task { await model.recreateZone() } }
                case .cloudDataDeletionPending:
                    Button("Löschen erneut versuchen") {
                        Task { deletionRetryError = await model.retryCloudDeletion() }
                    }
                    Button("Löschen abbrechen und wieder synchronisieren") { Task { await model.recreateZone() } }
                    if let deletionRetryError { ErrorText(message: deletionRetryError) }
                case .openConflicts:
                    NavigationLink("Konflikte anzeigen") { ConflictListView() }
                default:
                    EmptyView()
                }
            }
        }
        Button {
            Task { await model.sync(.manual) }
        } label: {
            Label("Jetzt synchronisieren", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(status.isSyncing)
        .accessibilityIdentifier("sync.now")
    }
}

/// Loads data whenever the app's data version changes (local write or sync).
struct ReloadOnChange: ViewModifier {
    @Environment(AppModel.self) private var model
    let action: @MainActor () async -> Void

    func body(content: Content) -> some View {
        content.task(id: model.dataVersion) { await action() }
    }
}

extension View {
    func reloadOnDataChange(_ action: @escaping @MainActor () async -> Void) -> some View {
        modifier(ReloadOnChange(action: action))
    }
}

/// Short-lived undo bar after an edit (spec H1 „Undo“).
struct UndoBar: View {
    let message: LocalizedStringResource
    let undo: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack {
            Text(message)
                .font(.callout)
            Spacer()
            Button("Rückgängig", action: undo)
                .buttonStyle(.borderedProminent)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel(Text("Hinweis schließen"))
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }
}

func errorMessage(_ error: any Error) -> String {
    if let error = error as? SoftwareRegisseurAI.AIProviderError { return error.userMessage() }
    if let error = error as? StoreError { return storeErrorMessage(error) }
    return error.localizedDescription
}

func storeErrorMessage(_ error: StoreError) -> String {
    switch error {
    case .revisionConflict:
        String(localized: "Die Aufgabe wurde inzwischen geändert (z. B. durch eine Synchronisierung). Bitte neu laden und erneut versuchen.")
    case .activeJobExists:
        String(localized: "Für diese Aufgabe läuft bereits ein Agentenauftrag.")
    case .workItemStatusChange(.activeJobConflict):
        String(localized: "Der Status wird vom Mac aus dem aktiven Agentenlauf abgeleitet und kann gerade nicht manuell geändert werden.")
    case .workItemStatusChange(.invalidTransition), .invalidWorkItemTransition:
        String(localized: "Dieser Statuswechsel ist nicht erlaubt.")
    case .identityFieldChanged(_, "projectId"):
        String(localized: "Eine Aufgabe mit vergebener Nummer kann nicht in ein anderes Projekt verschoben werden.")
    case .reclassificationRefused(.typeChangeAfterHumanID):
        String(localized: "Der Typ kann nicht mehr geändert werden, weil der Mac bereits eine Nummer vergeben hat.")
    case .reclassificationRefused:
        String(localized: "Der Typ kann während eines Agentenlaufs nicht geändert werden.")
    case .approvalClosed:
        String(localized: "Diese Freigabe ist nicht mehr offen; eine Entscheidung hat keine Wirkung mehr.")
    case .approvalDecisionNotAllowed:
        String(localized: "Diese Entscheidung bietet der Agent für diese Anfrage nicht an.")
    case .invalidSettings:
        String(localized: "Die Ordnerstandards müssen relative Pfade ohne „..“ sein.")
    default:
        String(localized: "Speichern fehlgeschlagen: \(String(describing: error))")
    }
}

