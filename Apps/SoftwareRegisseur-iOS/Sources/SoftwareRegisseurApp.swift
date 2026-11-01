import SwiftUI
import SoftwareRegisseurAppCore

/// iPhone and iPad app (spec H, P; ADR-0025). Data lives in the app's own GRDB database (ADR-0019) and
/// syncs with CloudKit on explicit triggers only (ADR-0011).
@main
struct SoftwareRegisseurApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Reads the device idiom once on the main thread for device-specific texts (ADR-0025).
        _ = DeviceKind.current
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(model)
                .preferredColorScheme(Self.forcedColorScheme)
                .task { await model.bootstrap() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await model.sceneBecameActive() }
            }
        }
        .commands { AppCommands(model: model) }
    }

    /// Debug builds only, launch argument `-SRForceAppearance dark|light` for the UI tests: on the iOS 27
    /// simulator `XCUIDevice.appearance` did not change the running app, so dark-mode audits saw light screens.
    private static var forcedColorScheme: ColorScheme? {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "SRForceAppearance") {
        case "dark": .dark
        case "light": .light
        default: nil
        }
        #else
        nil
        #endif
    }
}

/// Keyboard shortcuts for the main actions (iPad menu bar, ⌘-hold overview, hardware keyboard on the
/// iPhone): new note ⌘N, search ⌘F, sync ⌘R and the sections ⌘1–⌘8.
struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Neue Notiz") { model.requestQuickCapture() }
                .keyboardShortcut("n")
                .disabled(model.loadState != .ready || model.onboarding.needsPresentation)
            Button("Neues Fenster") { openWindow(id: "main") }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }
        CommandMenu("Gehe zu") {
            ForEach(Array(AppTab.allCases.enumerated()), id: \.element) { index, tab in
                Button {
                    model.show(tab)
                } label: {
                    Text(tab.title)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
            Divider()
            Button("Suchen") { model.requestSearch() }
                .keyboardShortcut("f")
                .disabled(model.loadState != .ready || model.onboarding.needsPresentation)
            Button("Jetzt synchronisieren") { Task { await model.sync(.manual) } }
                .keyboardShortcut("r")
                .disabled(model.loadState != .ready || model.syncStatus.isSyncing)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.loadState {
        case .loading:
            ProgressView("Daten werden geladen …")
        case let .failed(message):
            ContentUnavailableView {
                Label("Datenbank konnte nicht geöffnet werden", systemImage: "externaldrive.badge.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Erneut versuchen") { Task { await model.bootstrap() } }
            }
        case .ready:
            if model.onboarding.needsPresentation {
                OnboardingView()
                    .transition(.opacity)
            } else {
                MainTabView()
                    .transition(.opacity)
            }
        }
    }
}

/// One `NavigationStack` per tab, nothing nested (spec P, iPhone views 1–8).
///
/// On the iPhone (and in compact width on the iPad) eight tabs would overflow into the system „More“
/// tab, whose UIKit navigation controller wraps each overflowing tab and stacked a second navigation
/// bar (double back button) on top of the tab's own stack. The compact layout therefore shows four
/// sections plus an own „Mehr“ tab whose single stack pushes the remaining sections; regular width
/// (iPad sidebar) keeps all eight sections as tabs.
struct MainTabView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        @Bindable var model = model
        Group {
            if DeviceKind.current == .phone || horizontalSizeClass == .compact {
                CompactTabView()
            } else {
                RegularTabView()
            }
        }
        // ⌘N („Neue Notiz“) from any section.
        .sheet(isPresented: $model.showsQuickCapture) {
            QuickCaptureView(defaultProject: nil)
        }
    }
}

/// iPad in regular width: sidebar with all eight sections; lists with a detail column (ADR-0025).
private struct RegularTabView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Tab(value: tab) {
                    if tab.usesSplitLayout {
                        SplitTabStack(tab: tab)
                    } else {
                        TabStack(tab: tab)
                    }
                } label: {
                    Label { Text(tab.title) } icon: { Image(systemName: tab.symbol) }
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}

/// List and detail side by side. The tab's path keeps its meaning from the stack layout: the first
/// route is the selected row (detail root), further routes are pushed in the detail column. So
/// `openTask(_:)` and a switch to the compact layout (Split View, Stage Manager) keep the place.
private struct SplitTabStack: View {
    @Environment(AppModel.self) private var model
    let tab: AppTab
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var path: [AppRoute] { model.paths[tab] ?? [] }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            tab.rootView
                .environment(\.routeListSelection, Binding(
                    get: { path.first },
                    set: { model.paths[tab] = $0.map { [$0] } ?? [] }
                ))
                .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 440)
        } detail: {
            NavigationStack(path: Binding(
                get: { Array(path.dropFirst()) },
                set: { model.paths[tab] = Array(path.prefix(1)) + $0 }
            )) {
                Group {
                    if let root = path.first {
                        AppRouteDestination(route: root)
                            .id(root)
                    } else {
                        tab.emptyDetail
                    }
                }
                .appRouteDestinations()
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

private struct CompactTabView: View {
    private enum Selection: Hashable {
        case section(AppTab)
        case more
    }

    @Environment(AppModel.self) private var model
    @State private var selection: Selection = .section(.overview)

    var body: some View {
        @Bindable var model = model
        TabView(selection: Binding(get: { selection }, set: select)) {
            ForEach(AppTab.compactPrimary, id: \.self) { tab in
                Tab(value: Selection.section(tab)) {
                    TabStack(tab: tab)
                } label: {
                    Label { Text(tab.title) } icon: { Image(systemName: tab.symbol) }
                }
            }
            Tab(value: Selection.more) {
                NavigationStack(path: $model.morePath) {
                    MoreView().appRouteDestinations()
                }
            } label: {
                Label("Mehr", systemImage: "ellipsis")
            }
        }
        .onAppear { apply(model.selectedTab) }
        .onChange(of: model.tabRequest) { _, request in
            if let request { apply(request.tab) }
        }
        .onChange(of: model.morePath) { _, path in
            if selection == .more, case let .section(tab)? = path.first { model.selectedTab = tab }
        }
    }

    private func select(_ newValue: Selection) {
        selection = newValue
        switch newValue {
        case let .section(tab):
            model.selectedTab = tab
        case .more:
            if case let .section(tab)? = model.morePath.first { model.selectedTab = tab }
        }
    }

    private func apply(_ tab: AppTab) {
        if tab.isCompactPrimary {
            selection = .section(tab)
        } else {
            selection = .more
            if model.morePath.first != .section(tab) { model.morePath = [.section(tab)] }
        }
    }
}

/// The single navigation stack of one tab.
private struct TabStack: View {
    @Environment(AppModel.self) private var model
    let tab: AppTab

    var body: some View {
        NavigationStack(path: Binding(get: { model.paths[tab] ?? [] }, set: { model.paths[tab] = $0 })) {
            tab.rootView.appRouteDestinations()
        }
    }
}
