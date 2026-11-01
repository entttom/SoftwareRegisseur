import SwiftUI

// iPad layout helpers (ADR-0025). Compact width (iPhone, iPad Split View/Slide Over, narrow Stage
// Manager windows) keeps the iPhone layout; regular width gets split views and readable widths.

extension EnvironmentValues {
    /// Selection of the list column when a section runs in a split view (iPad, regular width).
    /// `nil` in a plain navigation stack, where rows push as usual.
    @Entry var routeListSelection: Binding<AppRoute?>? = nil
}

/// `List` whose `NavigationLink(value:)` rows select the split view's detail on the iPad and push
/// onto the tab's stack everywhere else.
struct RouteList<Content: View>: View {
    @Environment(\.routeListSelection) private var selection
    @ViewBuilder let content: () -> Content

    var body: some View {
        if let selection {
            List(selection: selection, content: content)
        } else {
            List(content: content)
        }
    }
}

/// Limits the content of a full-width list or form to a readable line length in regular width.
///
/// Uses safe-area padding instead of a frame, so the grouped background, the scroll indicator and
/// scrolling still span the whole column, and nested scroll views (e.g. `TextEditor`) and sheets are
/// not affected.
private struct ReadableContentWidth: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ScaledMetric(relativeTo: .body) private var maxWidth: CGFloat = 720
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        // Measured outside the padding: the outer width does not depend on the inset (no layout loop).
        content
            .safeAreaPadding(.horizontal, horizontalSizeClass == .regular ? max(0, (width - maxWidth) / 2) : 0)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0.rounded() }
    }
}

extension View {
    /// Search field of a section list: always visible in the iPad list column (the automatic placement
    /// hides it there), system default in the iPhone layout.
    func sectionSearchable(text: Binding<String>, prompt: Text) -> some View {
        modifier(SectionSearchable(text: text, prompt: prompt))
    }

    func readableContentWidth() -> some View {
        modifier(ReadableContentWidth())
    }
}

extension AppTab {
    /// Sections shown as list + detail in regular width (ADR-0025: „Split-View-Detailansichten“).
    var usesSplitLayout: Bool {
        switch self {
        case .tasks, .inbox, .projects, .review: true
        case .overview, .dictation, .agents, .settings: false
        }
    }

    /// Detail column before anything is selected.
    @ViewBuilder
    var emptyDetail: some View {
        switch self {
        case .tasks:
            ContentUnavailableView("Keine Aufgabe ausgewählt", systemImage: "checklist",
                                   description: Text("Wählen Sie eine Aufgabe aus der Liste."))
        case .inbox:
            ContentUnavailableView("Keine Notiz ausgewählt", systemImage: "tray",
                                   description: Text("Wählen Sie eine Notiz aus der Inbox."))
        case .projects:
            ContentUnavailableView("Kein Projekt ausgewählt", systemImage: "folder",
                                   description: Text("Wählen Sie ein Projekt aus der Liste."))
        case .review:
            ContentUnavailableView("Kein Ergebnis ausgewählt", systemImage: "checkmark.seal",
                                   description: Text("Wählen Sie ein Ergebnis aus der Liste."))
        case .overview, .dictation, .agents, .settings:
            EmptyView()
        }
    }
}

private struct SectionSearchable: ViewModifier {
    @Environment(\.routeListSelection) private var selection
    @Binding var text: String
    let prompt: Text

    func body(content: Content) -> some View {
        content.searchable(text: $text,
                           placement: selection != nil ? .navigationBarDrawer(displayMode: .always) : .automatic,
                           prompt: prompt)
    }
}

/// Buttons side by side, stacked at accessibility text sizes: side by side their titles were hyphenated
/// into two-line capsules („Erlau-ben“, A29 screenshot check).
struct AdaptiveButtonRow<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ViewBuilder var content: Content

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) { content }
                .buttonSizing(.flexible)
        } else {
            HStack { content }
        }
    }
}

extension View {
    /// Labels without icons, e.g. for wide button titles at accessibility text sizes.
    @ViewBuilder
    func titleOnlyLabels(_ titleOnly: Bool) -> some View {
        if titleOnly { labelStyle(.titleOnly) } else { self }
    }
}
