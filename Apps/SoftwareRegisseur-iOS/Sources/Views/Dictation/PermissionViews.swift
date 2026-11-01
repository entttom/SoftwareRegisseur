import SwiftUI
import UIKit
import SoftwareRegisseurAI
import SoftwareRegisseurAppCore

/// Own explanation screen before a system permission prompt (spec Q4, App Review 5.1.1(iv)).
///
/// - Explaining step: one neutral button „Weiter“, which immediately triggers the system prompt.
///   No „Später“, „Nicht jetzt“, close button or swipe-to-dismiss.
/// - After a denial: explains what does not work and links to Settings; never asks again.
struct PermissionFlowScreen: View {
    @Environment(\.openURL) private var openURL
    let flow: PermissionFlow
    /// Readable column on the iPad that grows with the text size.
    @ScaledMetric(relativeTo: .body) private var maxContentWidth: CGFloat = 540

    var body: some View {
        // Scrolls at large text sizes so „Weiter“ is always reachable; centred with a readable width on
        // the iPad (ADR-0025). Still a single neutral action and no way to skip (Q4).
        GeometryReader { proxy in
            ScrollView {
                Group {
                    switch flow.step {
                    case let .explaining(kind), let .requesting(kind):
                        explanation(kind)
                    case let .denied(kind):
                        denied(kind)
                    case .granted, .idle:
                        ProgressView()
                    }
                }
                .frame(maxWidth: maxContentWidth)
                .padding(32)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .accessibilityIdentifier("permission.screen")
        }
        .background(Color(.systemBackground))
        .interactiveDismissDisabled(true)
    }

    private func explanation(_ kind: PermissionKind) -> some View {
        VStack(spacing: 20) {
            Image(systemName: kind.symbol)
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(kind.title)
                .font(.title.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("permission.title")
            Text(kind.explanation)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if flow.availableActions.contains(.continueToSystemPrompt) {
                Button {
                    Task { await flow.continueTapped() }
                } label: {
                    Text("Weiter")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("permission.continue")
            } else {
                ProgressView()
            }
        }
    }

    private func denied(_ kind: PermissionKind) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 52))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("\(String(localized: kind.title)) nicht freigegeben")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("permission.deniedTitle")
            Text(kind.deniedConsequence)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text("Sie können den Zugriff jederzeit in den Einstellungen erlauben.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if flow.availableActions.contains(.openSettings), let url = URL(string: UIApplication.openSettingsURLString) {
                Button {
                    openURL(url)
                } label: {
                    Text("Einstellungen öffnen").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("permission.openSettings")
            }
            if flow.availableActions.contains(.close) {
                Button("Schließen") { flow.close() }
                    .accessibilityIdentifier("permission.close")
            }
        }
    }
}

/// Consent before audio leaves the device (spec H2: „Vor externem Upload klar anzeigen“, Q4).
struct UploadConsentSheet: View {
    let provider: SoftwareRegisseurAI.AIProviderID
    let duration: TimeInterval
    let onDecision: (Bool) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Label {
                    Text("Audio an \(String(localized: provider.title)) übertragen?")
                        .font(.title2.bold())
                } icon: {
                    Image(systemName: "icloud.and.arrow.up")
                }
                Text("Die Aufnahme (\(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))) wird zur Transkription an \(String(localized: provider.title)) gesendet und dort mit Ihrem eigenen API-Schlüssel verarbeitet. Es gelten die Datenschutzbedingungen von \(String(localized: provider.title)).")
                Text("Lange Aufnahmen werden in Abschnitte geteilt. Die Kosten trägt Ihr Anbieterkonto; die Anzeige in der App ist geschätzt.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    onDecision(true)
                } label: {
                    Text("Übertragen und transkribieren").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button {
                    onDecision(false)
                } label: {
                    Text("Nicht übertragen").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
            .padding(24)
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(true)
        .presentationDetents([.medium, .large])
    }
}
