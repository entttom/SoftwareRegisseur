import AppKit
import SwiftUI

/// macOS-App: lebt in der Menüleiste (LSUIElement), Hauptfenster auf Anforderung (Pflichtenheft D1/D2).
@main
struct SoftwareRegisseurMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment: AppEnvironment
    @State private var windowState = WindowState()
    // Sparkle-Updates (ADR-0017), siehe SoftwareUpdater.swift.
    @State private var softwareUpdater = SoftwareUpdater()

    init() {
        _environment = State(initialValue: AppEnvironment.makeForLaunch())
    }

    var body: some Scene {
        MenuBarExtra {
            // Erster Start: Einrichtungsassistent (D3, Q4); die Menüleiste zeigt bis zum Dienstschritt nur diesen.
            OnboardingGate(compact: true) { MenuBarContentView() }
                .appEnvironment(environment)
                .environment(windowState)
                .environment(softwareUpdater)
        } label: {
            MenuBarLabel()
                .environment(environment.monitor)
                .environment(environment.library)
        }
        .menuBarExtraStyle(.window)

        Window("Software Regisseur", id: WindowID.main) {
            OnboardingGate { MainWindowView() }
                .appEnvironment(environment)
                .environment(windowState)
                .environment(softwareUpdater)
        }
        // Bis zum Abschluss des Assistenten öffnet sich das Fenster mit der Einrichtung; danach nur auf Anforderung.
        .defaultLaunchBehavior(environment.setup.needsPresentation ? .presented : .suppressed)
        .defaultSize(width: 1180, height: 760)
        // Nach der Anmeldung nur das Menüleistensymbol (A01): ein beim Abmelden offenes Fenster nicht wiederherstellen.
        .restorationBehavior(.disabled)
        .commands {
            SoftwareUpdateCommands(updater: softwareUpdater)
            SectionCommands(navigation: environment.navigation)
        }
    }
}

/// Alle gemeinsamen Zustandsobjekte der App.
@MainActor
struct AppEnvironment {
    let configuration: AppConfiguration
    let monitor: ServiceMonitor
    let commands: CommandCenter
    let library: LibraryStore
    let navigation: NavigationModel
    let loginAgent: LoginAgentController
    let keys: ProviderKeyStore
    let onboarding: BackgroundServiceOnboarding
    let setup: SetupAssistant

    /// Normale App: XPC zum Dienst, Datenbank im App-Group-Container. Im Bildschirmfoto-Modus (nur Debug)
    /// wird weder der Dienst kontaktiert noch etwas registriert.
    static func makeForLaunch() -> AppEnvironment {
        #if DEBUG
        if ScreenshotMode.isRequested {
            return PreviewFixtures.environment()
        }
        #endif
        let configuration = AppConfiguration.load()
        let monitor = ServiceMonitor(configuration: configuration)
        let library = LibraryStore(databaseURL: configuration.databaseURL)
        let commands = CommandCenter(monitor: monitor)
        commands.afterCommand = { [weak monitor, weak library] in
            await library?.reload()
            await monitor?.refresh()
        }
        monitor.startMonitoring()
        library.start()
        let loginAgent = LoginAgentController(configuration: configuration)
        let flags = UserDefaultsOnboardingFlags()
        let onboarding = BackgroundServiceOnboarding(registrar: loginAgent, flags: flags)
        return AppEnvironment(
            configuration: configuration, monitor: monitor, commands: commands, library: library,
            navigation: NavigationModel(), loginAgent: loginAgent,
            keys: ProviderKeyStore(accessGroup: configuration.keychainAccessGroup),
            onboarding: onboarding,
            setup: SetupAssistant(service: onboarding, progress: flags)
        )
    }
}

extension View {
    func appEnvironment(_ environment: AppEnvironment) -> some View {
        self
            .environment(environment.monitor)
            .environment(environment.commands)
            .environment(environment.library)
            .environment(environment.navigation)
            .environment(environment.loginAgent)
            .environment(environment.keys)
            .environment(environment.onboarding)
            .environment(environment.setup)
    }
}

/// Bereichswechsel per Tastatur (⌘1 … ⌘9).
struct SectionCommands: Commands {
    let navigation: NavigationModel

    var body: some Commands {
        CommandMenu("Gehe zu") {
            ForEach(MacSection.allCases) { section in
                if let shortcut = section.shortcut {
                    Button { navigation.show(section) } label: { Text(section.title) }
                        .keyboardShortcut(shortcut, modifiers: .command)
                } else {
                    Button { navigation.show(section) } label: { Text(section.title) }
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if ScreenshotMode.isRequested {
            MainActor.assumeIsolated { ScreenshotRenderer.runAndExit() }
        }
        #endif
    }
}
