import SwiftUI

/// Zeigt beim ersten Start statt jeder anderen Oberfläche den Einrichtungsassistenten (D3, Q4).
/// Gilt für Hauptfenster (auch wiederhergestellt oder über „Gehe zu“/Menüleiste geöffnet) und Menüleiste.
/// Die Menüleiste zeigt bis zum Ende des Dienstschritts nur dessen Erklärung, danach die normale Ansicht mit einem
/// Hinweis, die Einrichtung im Fenster fortzusetzen.
struct OnboardingGate<Content: View>: View {
    @Environment(SetupAssistant.self) private var setup
    var compact = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        if compact {
            if setup.isInServicePhase {
                BackgroundServiceOnboardingView(compact: true)
                    // Auf dem Erklärschritt gibt es kein Schließen (kein Aufschieben vor der Systemaktion).
                    .windowDismissBehavior(setup.blocksDismissal ? .disabled : .automatic)
            } else if setup.needsPresentation {
                VStack(alignment: .leading, spacing: 0) {
                    SetupResumeBanner()
                    content()
                }
            } else {
                content()
            }
        } else if setup.needsPresentation {
            SetupAssistantView()
                .windowDismissBehavior(setup.blocksDismissal ? .disabled : .automatic)
                .windowMinimizeBehavior(setup.blocksDismissal ? .disabled : .automatic)
        } else {
            content()
        }
    }
}

/// Kompakte Einrichtung des Hintergrunddienstes in der Menüleiste: Erklärung → „Weiter“ (registriert sofort) →
/// Ergebnis. Nur der Ergebnisschritt bietet weitere Wege an.
struct BackgroundServiceOnboardingView: View {
    @Environment(SetupAssistant.self) private var setup
    var compact = false

    var body: some View {
        let step = setup.service.step
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: step.symbolName)
                    .font(.system(size: compact ? 28 : 40))
                    .foregroundStyle(step.tint)
                    .accessibilityHidden(true)
                Text(step.title)
                    .font(compact ? .title3.bold() : .title.bold())
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            BackgroundServiceOnboardingText(step: step)
            BackgroundServiceActions()
                .padding(.top, 8)
        }
        .padding(compact ? 16 : 32)
        .frame(width: compact ? 360 : nil, alignment: .topLeading)
    }
}

/// Aktionen des Dienstschritts; „Weiter“ ist die einzige Aktion vor der Systemaktion.
struct BackgroundServiceActions: View {
    @Environment(SetupAssistant.self) private var setup
    var large = false

    var body: some View {
        let service = setup.service
        HStack {
            if service.step == .registering {
                ProgressView().controlSize(.small)
                Text("Dienst wird registriert …").foregroundStyle(.secondary)
            }
            Spacer()
            let actions = service.availableActions
            // Hauptaktion rechts (macOS-Konvention), weitere Aktionen links davon.
            ForEach(actions.dropFirst().reversed(), id: \.self) { action in
                Button(setup.serviceTitle(for: action)) { setup.performService(action) }
            }
            if let primary = actions.first {
                Button(setup.serviceTitle(for: primary)) { setup.performService(primary) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(large ? .large : .regular)
    }
}

/// Erklärtexte des Dienstschritts, gemeinsam für Menüleiste und Assistent.
struct BackgroundServiceOnboardingText: View {
    let step: BackgroundServiceOnboarding.Step

    var body: some View {
        Group {
            switch step {
            case .explanation, .registering, .finished:
                VStack(alignment: .leading, spacing: 10) {
                    Text("Software Regisseur arbeitet mit einem Hintergrunddienst auf diesem Mac. Er synchronisiert Aufgaben mit iCloud, durchsucht Ihre Stammordner, startet Coding-Agenten zu den von Ihnen geplanten Zeiten und leitet Freigaben an Ihr iPhone weiter – auch wenn das Fenster geschlossen ist.")
                    Text("Damit das zuverlässig funktioniert, werden der Dienst und das Menüleistensymbol bei Ihrer macOS-Anmeldung automatisch gestartet, ohne Hauptfenster. macOS zeigt dazu eine Mitteilung zu Anmeldeobjekten an.")
                    Text("Sie können den Start bei der Anmeldung jederzeit in den Einstellungen unter „Dienst“ oder in den Systemeinstellungen unter „Anmeldeobjekte“ ändern.")
                        .foregroundStyle(.secondary)
                }
            case .requiresApproval:
                VStack(alignment: .leading, spacing: 10) {
                    Text("Der Hintergrunddienst ist registriert, aber macOS hat ihn noch nicht freigegeben. Ohne Freigabe startet er nicht: Synchronisierung, Scans und geplante Agentenläufe finden dann nicht statt.")
                    Text("Öffnen Sie die Anmeldeobjekte und aktivieren Sie „Software Regisseur“ unter „Im Hintergrund erlauben“. Den Start bei der Anmeldung können Sie später in den Einstellungen unter „Dienst“ wieder abschalten.")
                        .foregroundStyle(.secondary)
                }
            case let .failed(message):
                VStack(alignment: .leading, spacing: 10) {
                    Text(message)
                    Text("Ohne Hintergrunddienst sind Synchronisierung, Scans und Agentenläufe nicht verfügbar. Sie können die Registrierung erneut versuchen oder später in den Einstellungen unter „Dienst“ aktivieren.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension BackgroundServiceOnboarding.Step {
    var title: String {
        switch self {
        case .explanation, .registering: String(localized: "Hintergrunddienst einrichten")
        case .requiresApproval: String(localized: "Freigabe in den Systemeinstellungen")
        case .failed: String(localized: "Einrichtung nicht abgeschlossen")
        case .finished: String(localized: "Hintergrunddienst aktiv")
        }
    }

    var symbolName: String {
        switch self {
        case .explanation, .registering, .finished: "gearshape.2"
        case .requiresApproval: "person.badge.key"
        case .failed: "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch self {
        case .failed: .orange
        case .requiresApproval: .blue
        default: .accentColor
        }
    }
}
