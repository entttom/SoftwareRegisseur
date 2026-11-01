#if DEBUG
import AppKit
import SwiftUI

/// Nur Debug: `SoftwareRegisseur -SRRenderScreenshots <Ordner>` rendert Hauptansichten und Menüleiste mit
/// Beispieldaten (hell und dunkel) als PNG und beendet sich. Kein Dienstkontakt, keine Registrierung.
enum ScreenshotMode {
    static let argumentKey = "SRRenderScreenshots"

    static var outputDirectory: String? {
        UserDefaults.standard.string(forKey: argumentKey)
    }

    static var isRequested: Bool { outputDirectory != nil }
}

@MainActor
enum ScreenshotRenderer {
    static func runAndExit() {
        guard let directory = ScreenshotMode.outputDirectory else { return }
        Task { @MainActor in
            var status: Int32 = 0
            do {
                try await render(into: URL(filePath: directory, directoryHint: .isDirectory))
            } catch {
                FileHandle.standardError.write(Data("Bildschirmfotos fehlgeschlagen: \(error)\n".utf8))
                status = 1
            }
            exit(status)
        }
    }

    private static func render(into directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (environment, seed) = try await PreviewFixtures.seededEnvironment()
        let updater = SoftwareUpdater()
        let windowState = WindowState()

        for (appearanceName, appearance) in [("hell", NSAppearance.Name.aqua), ("dunkel", NSAppearance.Name.darkAqua)] {
            // Pflichtansichten hell und dunkel; weitere Bereiche zur Sichtprüfung nur hell.
            let sections: [MacSection] = appearance == .aqua
                ? [.dashboard, .queue, .review, .projects, .requests, .agents, .settings, .history, .inbox, .adrs]
                : [.dashboard, .queue, .review]
            for section in sections {
                environment.navigation.section = section
                environment.navigation.selectedProject = environment.library.snapshot.projects.first?.id
                environment.navigation.selectedWorkItem = environment.library.snapshot.job(seed.runningJob)?.workItemId
                environment.navigation.selectedInboxItem = environment.library.snapshot.inboxItems.first?.uuid
                environment.navigation.queueFilter = .active
                environment.navigation.selectedJob = seed.runningJob
                environment.navigation.selectedReview = seed.reviewId
                let view = MainWindowView()
                    .appEnvironment(environment)
                    .environment(windowState)
                    .environment(updater)
                try await capture(view, size: NSSize(width: 1_360, height: 860), appearance: appearance,
                                  to: directory.appending(path: "\(section.rawValue)-\(appearanceName).png"))
                if appearance == .aqua {
                    // Schmales Fenster zur Sichtprüfung der Umbrüche (Mindestgröße prüft `measureMinimumSizes`).
                    try await capture(view, size: NSSize(width: 900, height: 700), appearance: appearance,
                                      to: directory.appending(path: "\(section.rawValue)-klein.png"))
                }
            }
            let menu = MenuBarContentView()
                .appEnvironment(environment)
                .environment(windowState)
                .environment(updater)
                .background(.background)
            try await capture(menu, size: nil, appearance: appearance,
                              to: directory.appending(path: "menuleiste-\(appearanceName).png"))
        }
        try await renderOnboarding(environment: environment, updater: updater, windowState: windowState, into: directory)
        try await renderConversation(environment: environment, seed: seed, into: directory)
        try await measureMinimumSizes(environment: environment, updater: updater, windowState: windowState,
                                      into: directory)
    }

    /// Kleinste Fenstergröße je Bereich (`mindestgroessen.txt`): das Fenster wird auf 500 × 400 gesetzt und die
    /// Größe gemessen, bei der SwiftUI es festhält. Passt ein Bereich nicht in 900 × 700 (13-Zoll-Bildschirm mit
    /// Menüleiste und Dock), schlägt der Lauf fehl – so ließ sich das Hauptfenster einmal nicht kleiner ziehen.
    private static func measureMinimumSizes(environment: AppEnvironment, updater: SoftwareUpdater, windowState: WindowState,
                                            into directory: URL) async throws {
        let limit = NSSize(width: 900, height: 700)
        var lines: [String] = []
        var tooLarge: [String] = []
        func measure(_ name: String, _ view: some View) async throws {
            let controller = NSHostingController(rootView: view)
            controller.sizingOptions = [.minSize]
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 1_180, height: 760))
            window.orderFrontRegardless()
            try await Task.sleep(for: .seconds(1.5))
            window.setContentSize(NSSize(width: 500, height: 400))
            try await Task.sleep(for: .seconds(0.5))
            let size = window.contentLayoutRect.size
            let fits = size.width <= limit.width && size.height <= limit.height
            lines.append("\(name): \(Int(size.width.rounded())) × \(Int(size.height.rounded()))\(fits ? "" : " – ZU GROSS")")
            if !fits { tooLarge.append(name) }
            window.orderOut(nil)
        }
        for section in MacSection.allCases {
            environment.navigation.section = section
            try await measure(section.rawValue, MainWindowView()
                .appEnvironment(environment)
                .environment(windowState)
                .environment(updater))
        }
        for step in SetupAssistant.Step.allCases {
            try await measure("einrichtung-\(step.rawValue)", OnboardingGate { MainWindowView() }
                .environment(previewSetup(at: step))
                .appEnvironment(environment)
                .environment(windowState)
                .environment(updater))
        }
        try (lines.joined(separator: "\n") + "\n")
            .write(to: directory.appending(path: "mindestgroessen.txt"), atomically: true, encoding: .utf8)
        guard tooLarge.isEmpty else {
            throw CocoaError(.validationNumberTooLarge, userInfo: [
                NSLocalizedDescriptionKey: "Mindestgröße über \(Int(limit.width)) × \(Int(limit.height)): \(tooLarge.joined(separator: ", "))",
            ])
        }
    }

    /// Einrichtungsassistent beim ersten Start. Ersatz-Registrierung: es wird nie etwas bei `SMAppService` registriert.
    private static func renderOnboarding(environment: AppEnvironment, updater: SoftwareUpdater, windowState: WindowState,
                                         into directory: URL) async throws {
        func window(_ setup: SetupAssistant) -> some View {
            OnboardingGate { MainWindowView() }
                .environment(setup)
                .appEnvironment(environment)
                .environment(windowState)
                .environment(updater)
        }
        for step in SetupAssistant.Step.allCases {
            for (appearanceName, appearance) in [("hell", NSAppearance.Name.aqua), ("dunkel", NSAppearance.Name.darkAqua)] {
                try await capture(window(previewSetup(at: step)), size: NSSize(width: 1_100, height: 720), appearance: appearance,
                                  to: directory.appending(path: "einrichtung-\(step.rawValue)-\(appearanceName).png"))
            }
        }
        // Ergebnisse des Dienstschritts.
        let results: [(String, BackgroundServiceRegistrationResult)] = [
            ("freigabe", .requiresApproval),
            ("fehler", .failed("Vorgang nicht erlaubt")),
        ]
        for (name, result) in results {
            let setup = previewSetup(at: .backgroundService, registration: result)
            setup.performService(.continueToRegistration)
            try await capture(window(setup), size: NSSize(width: 1_100, height: 720), appearance: .aqua,
                              to: directory.appending(path: "einrichtung-dienst-\(name)-hell.png"))
        }
        for (appearanceName, appearance) in [("hell", NSAppearance.Name.aqua), ("dunkel", NSAppearance.Name.darkAqua)] {
            for (name, step) in [("dienst", SetupAssistant.Step.welcome), ("fortsetzen", .agents)] {
                let menu = OnboardingGate(compact: true) { MenuBarContentView() }
                    .environment(previewSetup(at: step))
                    .appEnvironment(environment)
                    .environment(windowState)
                    .environment(updater)
                    .background(.background)
                try await capture(menu, size: nil, appearance: appearance,
                                  to: directory.appending(path: "einrichtung-menuleiste-\(name)-\(appearanceName).png"))
            }
        }
    }

    /// Assistent auf `step`; Schritte nach dem Dienst mit bereits eingerichtetem (Ersatz-)Dienst.
    private static func previewSetup(at step: SetupAssistant.Step,
                                     registration: BackgroundServiceRegistrationResult = .requiresApproval) -> SetupAssistant {
        let pastService = SetupAssistant.Step.resumable.contains(step)
        let flags = InMemoryOnboardingFlags(completed: pastService, setupCompleted: false)
        if pastService { flags.setupAssistantStep = step.rawValue }
        let service = BackgroundServiceOnboarding(registrar: PreviewRegistrar(result: registration), flags: flags)
        let setup = SetupAssistant(service: service, progress: flags)
        if step == .backgroundService { setup.advance() }
        return setup
    }

    /// „Mit KI besprechen“ mit Ersatzanbieter: eine beantwortete Nachricht mit Vorschlag und das Manifest der nächsten.
    private static func renderConversation(environment: AppEnvironment, seed: PreviewFixtures.SeedResult,
                                           into directory: URL) async throws {
        let snapshot = environment.library.snapshot
        guard let item = snapshot.workItem(snapshot.job(seed.runningJob)?.workItemId) else { return }
        let conversation = MacConversationModel(
            item: item, provider: PreviewTextProvider(), model: "vorschau-modell-sonett",
            optionalContext: MacConversationContext.projectItems(for: item, workItems: snapshot.workItems,
                                                                 adrs: snapshot.project(item.projectId)?.adrs ?? []),
            commands: environment.commands)
        conversation.message = "Bitte ergänzen Sie Akzeptanzkriterien für das Querformat."
        await conversation.prepare()
        await conversation.confirmSend()
        if let first = conversation.optionalContext.first { conversation.setSelected(first.id, true) }
        conversation.message = "Wie sollen wir 13-Zoll-Geräte behandeln?"
        await conversation.prepare()
        for (appearanceName, appearance) in [("hell", NSAppearance.Name.aqua), ("dunkel", NSAppearance.Name.darkAqua)] {
            // Nur das Gesprächspanel in voller Höhe (ein Fenster mit Titelleiste wäre auf Bildschirmhöhe begrenzt).
            let view = ConversationPanel(item: item, model: .constant(conversation))
                .padding(16)
                .frame(width: 900)
                .groupBoxStyle(CardGroupBoxStyle())
                .appEnvironment(environment)
                .background(.background)
            try await capture(view, size: nil, appearance: appearance,
                              to: directory.appending(path: "ki-gespraech-\(appearanceName).png"))
        }
    }

    private static func capture(_ view: some View, size: NSSize?, appearance: NSAppearance.Name, to url: URL) async throws {
        let hosting = NSHostingView(rootView: view)
        let initial = size ?? NSSize(width: 370, height: 900)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: initial),
                              styleMask: size == nil ? [.borderless] : [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Software Regisseur"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        window.orderFrontRegardless()
        if size == nil {
            hosting.layoutSubtreeIfNeeded()
            window.setContentSize(hosting.fittingSize)
        }
        // SwiftUI-Layout, Tabellen und asynchrone `.task`-Ladevorgänge abschließen lassen.
        try await Task.sleep(for: .seconds(2.5))
        hosting.layoutSubtreeIfNeeded()
        // Fensterbild über das Systemwerkzeug (rendert Materialien und Tabellen korrekt). Ohne Berechtigung
        // zur Bildschirmaufnahme fällt es auf `cacheDisplay` zurück.
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path(percentEncoded: false)]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 || !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                throw CocoaError(.fileWriteUnknown)
            }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url)
        }
        window.orderOut(nil)
    }
}
#endif
