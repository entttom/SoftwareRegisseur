import SwiftUI
import SoftwareRegisseurAI
import SoftwareRegisseurAppCore
import SoftwareRegisseurDomain

/// Onboarding on the first launch (spec B, H2, I, N1, P): Willkommen → iCloud → Mac → Diktat →
/// KI-Schlüssel → Zusammenfassung. Replaces the tab view until finished; „Einstellungen“ reopens it.
///
/// No page asks for a system permission and none explains one (spec Q4): microphone and speech
/// recognition are requested only when a dictation starts, behind `PermissionFlowScreen`.
///
/// iPhone and compact iPad windows show a progress bar above the page; the iPad in regular width shows
/// the steps in a sidebar, like the Mac's setup assistant.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var maxContentWidth: CGFloat = 560

    private var onboarding: MobileOnboarding { model.onboarding }
    /// At accessibility sizes the page needs the full width; the progress bar replaces the sidebar.
    private var showsSidebar: Bool { horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                if showsSidebar {
                    OnboardingSidebar()
                        .frame(width: 300)
                    Divider().ignoresSafeArea()
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !showsSidebar {
                            OnboardingProgressBar()
                                .padding(.bottom, 28)
                        }
                        page
                            .id(onboarding.step)
                            .transition(pageTransition)
                    }
                    .frame(maxWidth: maxContentWidth, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, showsSidebar ? 48 : 12)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                // On the scroll view itself: on the composite with the inset it replaced the button's identifier.
                .accessibilityIdentifier("onboarding.screen")
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    OnboardingFooter(maxWidth: maxContentWidth)
                }
            }
            .background(Color(.systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    @ViewBuilder
    private var page: some View {
        switch onboarding.step {
        case .welcome: WelcomePage()
        case .sync: SyncPage()
        case .mac: MacPage()
        case .dictation: DictationPage()
        case .keys: KeysPage()
        case .summary: SummaryPage()
        }
    }

    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: onboarding.movedForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: onboarding.movedForward ? .leading : .trailing).combined(with: .opacity)
        )
    }
}

// MARK: - Step metadata

extension MobileOnboarding.Step {
    var title: LocalizedStringResource {
        switch self {
        case .welcome: "Willkommen"
        case .sync: "iCloud"
        case .mac: "Mac verbinden"
        case .dictation: "Diktat"
        case .keys: "KI-Schlüssel"
        case .summary: "Fertig"
        }
    }

    var subtitle: LocalizedStringResource {
        switch self {
        case .welcome: "Was die App für Sie erledigt"
        case .sync: "Abgleich mit Ihren Geräten"
        case .mac: "Wo die Coding-Agenten laufen"
        case .dictation: "Ideen sprechen statt tippen"
        case .keys: "Optional, für KI-Funktionen"
        case .summary: "Alles auf einen Blick"
        }
    }

    var symbolName: String {
        switch self {
        case .welcome: "sparkles"
        case .sync: "icloud"
        case .mac: "desktopcomputer"
        case .dictation: "waveform"
        case .keys: "key"
        case .summary: "checkmark.seal"
        }
    }

    var tint: Color {
        switch self {
        case .welcome: .indigo
        case .sync: .blue
        case .mac: .purple
        case .dictation: .orange
        case .keys: .teal
        case .summary: .green
        }
    }
}

// MARK: - Chrome

/// Segmented progress bar with „Schritt n von m“ and „Zurück“ (iPhone, compact width).
private struct OnboardingProgressBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let onboarding = model.onboarding
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                OnboardingBackButton()
                Spacer()
                Text("Schritt \(onboarding.position) von \(onboarding.stepCount)")
                    .font(.subheadline)
                    .foregroundStyle(.metadata)
                    .accessibilityIdentifier("onboarding.position")
            }
            .frame(minHeight: 44)
            HStack(spacing: 6) {
                ForEach(MobileOnboarding.Step.allCases) { step in
                    Capsule()
                        .fill(onboarding.state(of: step) == .upcoming ? AnyShapeStyle(Color(.systemFill)) : AnyShapeStyle(onboarding.step.tint.gradient))
                        .frame(height: 5)
                }
            }
            .accessibilityHidden(true)
        }
    }
}

/// „Zurück“ above the page; keeps its space on the first page so the layout does not jump.
private struct OnboardingBackButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let onboarding = model.onboarding
        Button {
            withAnimation(.snappy) { onboarding.goBack() }
        } label: {
            Label("Zurück", systemImage: "chevron.left")
        }
        // At accessibility sizes „Zurück“ next to „Schritt n von m“ was hyphenated („Zu-rück“); the arrow alone
        // keeps the label for VoiceOver.
        .labelStyle(dynamicTypeSize.isAccessibilitySize ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
        .opacity(onboarding.canGoBack ? 1 : 0)
        .disabled(!onboarding.canGoBack)
        .accessibilityHidden(!onboarding.canGoBack)
        .accessibilityIdentifier("onboarding.back")
    }
}

/// Steps in a sidebar (iPad, regular width).
private struct OnboardingSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let onboarding = model.onboarding
        VStack(alignment: .leading, spacing: 0) {
            // Scrolls at large text sizes instead of growing past the screen (it pushed „Weiter“ off screen).
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Einrichtung")
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                        .padding(.bottom, 24)
                    ForEach(Array(MobileOnboarding.Step.allCases.enumerated()), id: \.element) { index, step in
                        OnboardingStepRow(step: step, number: index + 1, state: onboarding.state(of: step),
                                          isLast: index == MobileOnboarding.Step.allCases.count - 1)
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            OnboardingBackButton()
                .padding(28)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(.secondarySystemGroupedBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.sidebar")
    }
}

private struct OnboardingStepRow: View {
    let step: MobileOnboarding.Step
    let number: Int
    let state: MobileOnboarding.StepState
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 4) {
                ZStack {
                    // Done: tinted circle with a check mark. Current: tinted ring around the number in label colour
                    // (white on green or blue failed the contrast audit).
                    switch state {
                    case .done:
                        Circle().fill(step.tint.gradient)
                        Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                    case .current:
                        Circle().strokeBorder(step.tint, lineWidth: 3)
                        Text(number, format: .number).font(.caption.bold()).foregroundStyle(.primary)
                    case .upcoming:
                        Circle().fill(Color(.systemFill))
                        Text(number, format: .number).font(.caption.bold()).foregroundStyle(.metadata)
                    }
                }
                .frame(width: 28, height: 28)
                if !isLast {
                    Capsule()
                        .fill(state == .done ? AnyShapeStyle(step.tint.opacity(0.5)) : AnyShapeStyle(Color(.separator)))
                        .frame(width: 2)
                        .frame(minHeight: 18, maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.headline)
                    .foregroundStyle(state == .upcoming ? AnyShapeStyle(.metadata) : AnyShapeStyle(.primary))
                Text(step.subtitle)
                    .font(.caption)
                    .foregroundStyle(.metadata)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)
            .padding(.bottom, isLast ? 0 : 14)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Schritt \(number) von \(MobileOnboarding.Step.allCases.count): \(String(localized: step.title))"))
        .accessibilityValue(Text(stateText))
        .accessibilityAddTraits(state == .current ? .isSelected : [])
    }

    private var stateText: LocalizedStringResource {
        switch state {
        case .done: "Erledigt"
        case .current: "Aktueller Schritt"
        case .upcoming: "Noch offen"
        }
    }
}

/// Primary action under the page: „Weiter“, on the summary „Los geht’s“.
private struct OnboardingFooter: View {
    @Environment(AppModel.self) private var model
    let maxWidth: CGFloat

    var body: some View {
        let onboarding = model.onboarding
        Button {
            if onboarding.isLastStep {
                model.show(.overview)
                withAnimation(.smooth) { onboarding.advance() }
            } else {
                withAnimation(.snappy) { onboarding.advance() }
            }
        } label: {
            Text(onboarding.isLastStep ? "Los geht’s" : "Weiter")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("onboarding.continue")
        .frame(maxWidth: maxWidth)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.footer")
    }
}

// MARK: - Shared page parts

private struct OnboardingHeader: View {
    let step: MobileOnboarding.Step
    let title: LocalizedStringResource
    let text: LocalizedStringResource

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            OnboardingSymbolTile(symbolName: step.symbolName, tint: step.tint)
            Text(title)
                .font(.largeTitle.bold())
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("onboarding.title")
            Text(text)
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 28)
    }
}

private struct OnboardingSymbolTile: View {
    let symbolName: String
    let tint: Color
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 60

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .shadow(color: tint.opacity(0.3), radius: 10, y: 5)
            .accessibilityHidden(true)
    }
}

private struct OnboardingCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Symbol, title and explanation, used for features and status lines.
private struct OnboardingInfoRow: View {
    let symbolName: String
    let tint: Color
    let title: LocalizedStringResource
    let text: LocalizedStringResource
    @ScaledMetric(relativeTo: .title2) private var iconWidth: CGFloat = 32

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbolName)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Title on the left, menu picker on the right (outside a `List` a menu picker shows only its value);
/// stacked at accessibility text sizes.
private struct OnboardingPickerRow<Control: View>: View {
    let title: LocalizedStringResource
    @ViewBuilder let picker: () -> Control

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(title)
                Spacer()
                picker().labelsHidden()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                picker().labelsHidden()
            }
        }
    }
}

// MARK: - 1 Willkommen

private struct WelcomePage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnboardingHeader(
                step: .welcome,
                title: "Willkommen bei Software Regisseur",
                text: DeviceKind.current.pick(
                    phone: "Ideen unterwegs erfassen, Coding-Agenten auf Ihrem Mac beauftragen und Ergebnisse prüfen – direkt von diesem iPhone aus.",
                    pad: "Ideen unterwegs erfassen, Coding-Agenten auf Ihrem Mac beauftragen und Ergebnisse prüfen – direkt von diesem iPad aus."
                )
            )
            OnboardingCard {
                OnboardingInfoRow(symbolName: "square.and.pencil", tint: .orange, title: "Erfassen",
                                  text: "Aufgaben und Ideen per Text oder Diktat – auch ohne Verbindung.")
                Divider()
                OnboardingInfoRow(symbolName: "cpu", tint: .purple, title: "Beauftragen",
                                  text: "Codex oder Claude Code setzen Aufgaben auf Ihrem Mac um, mit dem Modell und der Denkstufe Ihrer Wahl.")
                Divider()
                OnboardingInfoRow(symbolName: "checkmark.shield", tint: .green, title: "Prüfen",
                                  text: "Freigaben erteilen und Ergebnisse ansehen, bevor etwas in Ihr Repository kommt.")
            }
            Text("Die Einrichtung dauert etwa eine Minute. Alles lässt sich später in den Einstellungen ändern.")
                .font(.footnote)
                .foregroundStyle(.metadata)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
        }
    }
}

// MARK: - 2 iCloud

private struct SyncPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingHeader(step: .sync, title: "iCloud-Synchronisierung",
                             text: "Aufgaben, Projekte und Agentenaufträge gleichen sich über Ihren iCloud-Account mit Ihrem Mac und Ihren anderen Geräten ab.")
            .padding(.bottom, -12)
            OnboardingCard { status }
            OnboardingCard {
                OnboardingInfoRow(symbolName: "arrow.triangle.2.circlepath", tint: .blue, title: "Ohne Push-Benachrichtigungen",
                                  text: "Abgeglichen wird beim Öffnen und Aktivieren der App, durch Herunterziehen und auf Ihren Wunsch.")
                Divider()
                OnboardingInfoRow(symbolName: "lock.shield", tint: .green, title: "Geheimnisse bleiben lokal",
                                  text: "API-Schlüssel und Audioaufnahmen werden nie über iCloud-Datensätze übertragen.")
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.cloudAvailability {
        case let .unavailable(reason):
            OnboardingInfoRow(symbolName: "icloud.slash", tint: .orange, title: "Nicht verfügbar", text: reason.message)
                .accessibilityIdentifier("onboarding.sync.unavailable")
        case .available:
            let status = model.syncStatus
            if status.isSyncing {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Wird abgeglichen …").foregroundStyle(.secondary)
                }
            } else if let attention = status.attention.first {
                OnboardingInfoRow(symbolName: "exclamationmark.icloud", tint: .orange, title: "Aufmerksamkeit nötig",
                                  text: attention.message)
            } else if let error = model.syncStartError ?? status.lastError {
                OnboardingInfoRow(symbolName: "exclamationmark.icloud", tint: .orange, title: "Abgleich fehlgeschlagen",
                                  text: "\(error)")
            } else if let date = status.lastSuccessfulFetch {
                OnboardingInfoRow(symbolName: "checkmark.icloud", tint: .green, title: "Verbunden",
                                  text: "Zuletzt abgeglichen \(date.formatted(.relative(presentation: .named))).")
            } else {
                OnboardingInfoRow(symbolName: "icloud", tint: .blue, title: "Noch nicht abgeglichen",
                                  text: "Melden Sie sich in den Systemeinstellungen bei iCloud an, falls noch nicht geschehen.")
            }
            Button {
                Task { await model.sync(.manual) }
            } label: {
                Label("Jetzt abgleichen", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(status.isSyncing)
            .accessibilityIdentifier("onboarding.sync.now")
        }
    }
}

// MARK: - 3 Mac

private struct MacPage: View {
    @Environment(AppModel.self) private var model
    @State private var catalog = Catalog()
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingHeader(step: .mac, title: "Mac verbinden",
                             text: DeviceKind.current.pick(
                                 phone: "Die Coding-Agenten laufen auf Ihrem Mac. Dieses iPhone plant Aufträge, der Mac führt sie aus und meldet die Ergebnisse zurück.",
                                 pad: "Die Coding-Agenten laufen auf Ihrem Mac. Dieses iPad plant Aufträge, der Mac führt sie aus und meldet die Ergebnisse zurück."
                             ))
            .padding(.bottom, -12)
            if let error { ErrorText(message: error) }
            if catalog.hosts.isEmpty {
                instructions
            } else {
                ForEach(catalog.hosts) { host in hostCard(host) }
                defaultAgent
            }
        }
        .reloadOnDataChange { await load() }
    }

    private var instructions: some View {
        OnboardingCard {
            Text("Noch kein Mac gefunden").font(.headline)
            NumberedStep(number: 1, text: "Software Regisseur auf dem Mac installieren und dort die Einrichtung abschließen.")
            NumberedStep(number: 2, text: DeviceKind.current.pick(
                phone: "Am Mac und auf diesem iPhone mit demselben Apple-Account bei iCloud angemeldet sein.",
                pad: "Am Mac und auf diesem iPad mit demselben Apple-Account bei iCloud angemeldet sein."
            ))
            NumberedStep(number: 3, text: "Der Mac erscheint hier, sobald beide Geräte abgeglichen haben. Das kann nach dem ersten Start einige Minuten dauern.")
            if case .unavailable = model.cloudAvailability {
                Text("Ohne iCloud-Synchronisierung kann sich der Mac nicht melden. Aufgaben erfassen und Diktate funktionieren trotzdem.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button {
                    Task { await model.sync(.manual) }
                } label: {
                    Label("Erneut prüfen", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(model.syncStatus.isSyncing)
                .accessibilityIdentifier("onboarding.mac.refresh")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.mac.instructions")
    }

    private func hostCard(_ host: AgentHost) -> some View {
        let offline = HostAvailability.isOffline(host, now: .now)
        let capabilities = catalog.capabilities.filter { $0.hostId == host.hostId }
        return OnboardingCard {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text(verbatim: host.name).font(.headline)
                } icon: {
                    Image(systemName: "desktopcomputer").foregroundStyle(.purple)
                }
                Spacer()
                HostReachabilityText(offline: offline).font(.subheadline)
            }
            .accessibilityElement(children: .combine)
            if capabilities.isEmpty {
                Text("Dieser Mac hat noch keine Coding-Agenten gemeldet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(capabilities, id: \.providerId) { capability in
                Divider()
                HStack {
                    Text(verbatim: capability.displayName)
                    Spacer()
                    AgentReadinessBadge(capability: capability)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.mac.host")
    }

    @ViewBuilder
    private var defaultAgent: some View {
        let providers = Array(Set(catalog.capabilities.map(\.providerId))).sorted()
        if !providers.isEmpty {
            OnboardingCard {
                OnboardingPickerRow(title: "Standardagent") {
                    Picker(selection: Binding(
                        get: { model.globalSettings.defaultAgentId },
                        set: { provider in Task { await saveDefaultAgent(provider) } }
                    )) {
                        Text("Keiner").tag(ProviderID?.none)
                        ForEach(providers, id: \.self) { provider in
                            Text(verbatim: catalog.capabilities.first { $0.providerId == provider }?.displayName ?? provider.rawValue)
                                .tag(ProviderID?.some(provider))
                        }
                    } label: {
                        Text("Standardagent")
                    }
                    .accessibilityIdentifier("onboarding.mac.defaultAgent")
                }
                Text("Wird bei neuen Aufträgen vorausgewählt. Modell und Denkstufe je Agent stellen Sie unter „Agenten“ ein.")
                    .font(.footnote)
                    .foregroundStyle(.metadata)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func load() async {
        do {
            catalog = try await model.loadCatalog()
            error = nil
        } catch {
            self.error = errorMessage(error)
        }
    }

    private func saveDefaultAgent(_ provider: ProviderID?) async {
        do {
            try await model.updateGlobalSettings { $0.defaultAgentId = provider }
            error = nil
        } catch {
            self.error = errorMessage(error)
        }
    }
}

private struct NumberedStep: View {
    let number: Int
    let text: LocalizedStringResource

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(number, format: .number)
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.purple.gradient, in: Circle())
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 4 Diktat

private struct DictationPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            OnboardingHeader(step: .dictation, title: "Diktat",
                             text: "Sprechen Sie Ideen einfach ein. Wählen Sie, wie Ihre Aufnahmen in Text umgewandelt werden.")
            .padding(.bottom, -12)
            ForEach(TranscriptionMethod.allCases, id: \.self) { method in
                MethodOption(method: method, selected: model.settings.dictationMethod == method) {
                    model.settings.dictationMethod = method
                }
            }
            if model.settings.dictationMethod == .openAI,
               case .missing = model.keys.status(provider: .openai, purpose: .transcription) {
                Label("Den OpenAI-Schlüssel für die Transkription hinterlegen Sie im nächsten Schritt.", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            OnboardingCard {
                Toggle(isOn: $model.settings.autoDraftAfterDictation) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Entwurf automatisch vorbereiten")
                        Text("Nach dem Diktat wird ein strukturierter Entwurf vorbereitet. Sie prüfen ihn, bevor etwas gesendet wird.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityIdentifier("onboarding.dictation.autoDraft")
            }
        }
    }
}

private struct MethodOption: View {
    let method: TranscriptionMethod
    let selected: Bool
    let select: () -> Void
    @ScaledMetric(relativeTo: .title2) private var iconWidth: CGFloat = 32

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: method == .appleSpeech ? "apple.logo" : "cloud")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .frame(width: iconWidth)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(method.title).font(.headline).foregroundStyle(.primary)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.tertiaryLabel)))
                    .accessibilityHidden(true)
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("onboarding.dictation.\(method.rawValue)")
    }

    private var detail: LocalizedStringResource {
        switch method {
        case .appleSpeech:
            "Erkennung auf dem Gerät – ohne Upload und ohne Kosten."
        case .openAI:
            "Mit Ihrem eigenen OpenAI-Schlüssel. Die Aufnahme wird zu OpenAI übertragen; vor jeder Übertragung fragt die App nach."
        }
    }
}

// MARK: - 5 KI-Schlüssel

private struct KeysPage: View {
    @Environment(AppModel.self) private var model
    /// Key status is read from the keychain; refreshed when the page reappears after editing a key.
    @State private var refresh = 0

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            OnboardingHeader(step: .keys, title: "Eigene KI-Schlüssel",
                             text: "Optional: Für KI-Ausarbeitung und OpenAI-Transkription verwenden Sie Ihre eigenen API-Schlüssel. Erfassen, Apple-Diktat und Agentenaufträge funktionieren auch ohne.")
            .padding(.bottom, -12)
            OnboardingCard {
                ForEach(Array(keyRows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider() }
                    NavigationLink {
                        ProviderKeyView(provider: row.provider, purpose: row.purpose)
                    } label: {
                        HStack {
                            KeyStatusRow(provider: row.provider, purpose: row.purpose)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right")
                                .font(.footnote.bold())
                                .foregroundStyle(Color(.tertiaryLabel))
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .id(refresh)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("onboarding.keys")
            OnboardingCard {
                OnboardingPickerRow(title: "KI-Ausarbeitung") {
                    Picker(selection: Binding(
                        get: { model.settings.textProvider },
                        set: { provider in
                            guard provider != model.settings.textProvider else { return }
                            model.settings.textProvider = provider
                            model.settings.textModel = nil
                        }
                    )) {
                        Text("Keiner").tag(String?.none)
                        ForEach(KeyPurpose.text.providers, id: \.rawValue) { Text($0.title).tag(String?.some($0.rawValue)) }
                    } label: {
                        Text("Anbieter für KI-Ausarbeitung")
                    }
                    .accessibilityIdentifier("onboarding.keys.textProvider")
                }
                Text("Das Modell wählen Sie danach unter Einstellungen › KI-Ausarbeitung.")
                    .font(.footnote)
                    .foregroundStyle(.metadata)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Label("Schlüssel liegen nur im Schlüsselbund, nie in iCloud-Datensätzen, Git oder Logs. Ein OpenAI-Schlüssel ist keine Codex-Anmeldung, ein Anthropic-Schlüssel kein Claude-Code-Abonnement.",
                  systemImage: "lock.shield")
                .font(.footnote)
                .foregroundStyle(.metadata)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { refresh += 1 }
    }

    private var keyRows: [(provider: SoftwareRegisseurAI.AIProviderID, purpose: KeyPurpose)] {
        KeyPurpose.allCases.flatMap { purpose in purpose.providers.map { (provider: $0, purpose: purpose) } }
    }
}

// MARK: - 6 Zusammenfassung

private struct SummaryPage: View {
    @Environment(AppModel.self) private var model
    @State private var catalog = Catalog()

    var body: some View {
        let ready = isSyncReady && !catalog.hosts.isEmpty
        VStack(alignment: .leading, spacing: 16) {
            OnboardingHeader(step: .summary, title: ready ? "Alles bereit" : "Fast geschafft",
                             text: ready
                                 ? "Ihr Mac ist verbunden. Erfassen Sie die erste Idee und lassen Sie sie von einem Coding-Agenten umsetzen."
                                 : "Sie können sofort Ideen erfassen. Was noch fehlt, holen Sie jederzeit in den Einstellungen nach.")
            .padding(.bottom, -12)
            OnboardingCard {
                SummaryRow(step: .sync, title: "iCloud", value: syncValue, state: isSyncReady ? .ok : .attention)
                Divider()
                SummaryRow(step: .mac, title: "Mac", value: macValue, state: catalog.hosts.isEmpty ? .attention : .ok)
                Divider()
                SummaryRow(step: .dictation, title: "Diktat", value: model.settings.dictationMethod.title,
                           state: dictationReady ? .ok : .attention)
                Divider()
                SummaryRow(step: .keys, title: "KI-Schlüssel", value: keysValue, state: storedKeyCount > 0 ? .ok : .optional)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("onboarding.summary")
        }
        .reloadOnDataChange { catalog = (try? await model.loadCatalog()) ?? Catalog() }
    }

    private var isSyncReady: Bool {
        guard case .available = model.cloudAvailability else { return false }
        return model.syncStartError == nil && !model.syncStatus.needsAttention
    }

    private var syncValue: LocalizedStringResource {
        switch model.cloudAvailability {
        case .unavailable: return "Nicht verfügbar – nur lokal"
        case .available:
            if model.syncStatus.needsAttention || model.syncStartError != nil { return "Aufmerksamkeit nötig" }
            return model.syncStatus.lastSuccessfulFetch == nil ? "Aktiv, noch nicht abgeglichen" : "Aktiv"
        }
    }

    private var macValue: LocalizedStringResource {
        switch catalog.hosts.count {
        case 0: "Noch kein Mac verbunden"
        case 1: "„\(catalog.hosts[0].name)“ verbunden"
        default: "\(catalog.hosts.count) Macs verbunden"
        }
    }

    private var dictationReady: Bool {
        guard model.settings.dictationMethod == .openAI else { return true }
        if case .stored = model.keys.status(provider: .openai, purpose: .transcription) { return true }
        return false
    }

    private var storedKeyCount: Int {
        KeyPurpose.allCases.reduce(0) { count, purpose in
            count + purpose.providers.filter {
                if case .stored = model.keys.status(provider: $0, purpose: purpose) { return true }
                return false
            }.count
        }
    }

    private var keysValue: LocalizedStringResource {
        storedKeyCount == 0 ? "Keine – optional" : "\(storedKeyCount) hinterlegt"
    }
}

private struct SummaryRow: View {
    enum State { case ok, attention, optional }

    @Environment(AppModel.self) private var model
    let step: MobileOnboarding.Step
    let title: LocalizedStringResource
    let value: LocalizedStringResource
    let state: State

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            Button("Ändern") {
                withAnimation(.snappy) { model.onboarding.revisit(step) }
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("\(String(localized: title)) ändern"))
            .accessibilityIdentifier("onboarding.summary.change.\(step.rawValue)")
        }
    }

    private var symbol: String {
        switch state {
        case .ok: "checkmark.circle.fill"
        case .attention: "exclamationmark.circle.fill"
        case .optional: "minus.circle"
        }
    }

    private var tint: Color {
        switch state {
        case .ok: .green
        case .attention: .orange
        case .optional: .secondary
        }
    }
}

/// Switches label styles at runtime (`LabelStyle` has no type-erased form in SwiftUI).
private struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView

    init(_ style: some LabelStyle) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}
