import AppKit
import SwiftUI
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC

extension StatusLevel {
    /// Farben ergänzen Text, ersetzen ihn nie (P).
    var color: Color {
        switch self {
        case .ok: .green
        case .info: .blue
        case .warning: .orange
        case .error: .red
        case .unknown: .secondary
        }
    }
}

/// Symbol + Text in Statusfarbe; VoiceOver liest nur den Text.
struct StatusLabel: View {
    let title: String
    var detail: String?
    let level: StatusLevel
    let symbolName: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbolName)
                .foregroundStyle(level.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Kleine Plakette für Status/Typ.
struct Badge: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

/// Segmente, wenn sie in die Breite passen, sonst ein Aufklappmenü. macOS gibt jedem Segment die Breite des
/// breitesten; die sieben Bereiche der Aufgabe allein hielten das Hauptfenster auf rund 940 pt Mindestbreite.
struct AdaptivePicker<Value: Hashable, Content: View>: View {
    let title: LocalizedStringKey
    @Binding var selection: Value
    @ViewBuilder var content: Content

    init(_ title: LocalizedStringKey, selection: Binding<Value>, @ViewBuilder content: () -> Content) {
        self.title = title
        _selection = selection
        self.content = content()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Picker(title, selection: $selection) { content }
                .pickerStyle(.segmented)
            Picker(title, selection: $selection) { content }
                .pickerStyle(.menu)
                .fixedSize()
        }
        .labelsHidden()
    }
}

/// Zeilenumbrechende Anordnung kleiner Elemente (Plaketten).
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

extension WorkItemStatus {
    var level: StatusLevel {
        switch self {
        case .inbox, .open, .cancelled: .unknown
        case .queued, .scheduled, .inProgress, .implementationFinished: .info
        case .waitingApproval, .review, .paused, .blocked: .warning
        case .integrated, .done: .ok
        case .failed: .error
        }
    }
}

extension AgentJobState {
    var level: StatusLevel {
        switch self {
        case .requested, .pendingMac, .scheduled, .admitted, .starting: .info
        case .running: .ok
        case .waitingApproval, .waitingQuota, .paused, .needsConfiguration: .warning
        case .failed: .error
        case .finished: .ok
        case .cancelled: .unknown
        }
    }
}

extension ProjectStatus {
    var level: StatusLevel {
        switch self {
        case .ready: .ok
        case .pendingMacSetup: .info
        case .unavailable: .error
        case .needsAttention: .warning
        case .archived: .unknown
        }
    }
}

/// Führt einen Dienstbefehl aus, zeigt währenddessen einen Fortschritt und optional eine Rückfrage.
struct CommandButton: View {
    @Environment(CommandCenter.self) private var commands

    let title: String
    var systemImage: String?
    var role: ButtonRole?
    /// Text der Rückfrage für nicht umkehrbare Aktionen.
    var confirmation: String?
    let request: () -> ServiceRequest
    var onResult: ((CommandOutcome) -> Void)?

    @State private var isRunning = false
    @State private var isConfirming = false

    init(_ title: String, systemImage: String? = nil, role: ButtonRole? = nil, confirmation: String? = nil,
         request: @escaping () -> ServiceRequest, onResult: ((CommandOutcome) -> Void)? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.confirmation = confirmation
        self.request = request
        self.onResult = onResult
    }

    var body: some View {
        Button(role: role) {
            if confirmation != nil { isConfirming = true } else { run() }
        } label: {
            HStack(spacing: 6) {
                if isRunning {
                    ProgressView().controlSize(.small)
                } else if let systemImage {
                    Image(systemName: systemImage).accessibilityHidden(true)
                }
                Text(title)
            }
        }
        .disabled(isRunning)
        .accessibilityLabel(Text(title))
        .confirmationDialog(Text(title), isPresented: $isConfirming) {
            Button(role: role) { run() } label: { Text(title) }
            Button(role: .cancel) {} label: { Text("Abbrechen") }
        } message: {
            if let confirmation { Text(confirmation) }
        }
    }

    private func run() {
        isRunning = true
        Task {
            let outcome = await commands.perform(title, request())
            isRunning = false
            onResult?(outcome)
        }
    }
}

/// Ehrlicher Hinweis, warum eine Funktion gerade nicht verfügbar ist (fehlender Agent, Schlüssel, Ordner …).
struct UnavailableNotice: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

/// Zeigt die Rückmeldung des letzten Befehls (Erfolg oder Fehler mit Handlungshinweis).
struct FeedbackBanner: View {
    @Environment(CommandCenter.self) private var commands

    var body: some View {
        VStack(spacing: 6) {
            if commands.isBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(commands.running.map(\.title).joined(separator: ", "))
                        .lineLimit(1)
                    Spacer()
                }
                .padding(8)
                .background(.bar, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("Läuft: \(commands.running.map(\.title).joined(separator: ", "))"))
            }
            if let entry = commands.latest {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: entry.feedback.isFailure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(entry.feedback.isFailure ? Color.red : Color.green)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title).font(.headline)
                        // Begrenzt: die Mindesthöhe des Fensters misst SwiftUI bei kleinster Breite, ein frei
                        // umbrechender Text hielt das Hauptfenster sonst rund 640 pt hoch. Volltext im Tooltip.
                        Text(entry.feedback.message)
                            .lineLimit(5)
                            .frame(minWidth: 220, alignment: .leading)
                            .help(Text(verbatim: entry.feedback.message))
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button {
                        commands.dismissLatest()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Hinweis schließen"))
                    .keyboardShortcut(.cancelAction)
                }
                .padding(10)
                .background(.bar, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(entry.feedback.isFailure ? Color.red.opacity(0.5) : Color.clear))
                .accessibilityElement(children: .combine)
                .task(id: entry.id) {
                    guard !entry.feedback.isFailure else { return }
                    try? await Task.sleep(for: .seconds(8))
                    if commands.latest?.id == entry.id { commands.dismissLatest() }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, commands.isBusy || commands.latest != nil ? 8 : 0)
    }
}

/// Leer-/Fehlerzustand, solange die Datenbank nicht lesbar ist.
struct LibraryGate<Content: View>: View {
    @Environment(LibraryStore.self) private var library
    @ViewBuilder var content: () -> Content

    var body: some View {
        switch library.phase {
        case .ready:
            content()
        case .unconfigured:
            ContentUnavailableView {
                Label("Keine Datenbank", systemImage: "externaldrive.badge.xmark")
            } description: {
                Text("Die App-Group-Kennung fehlt. Ohne sie findet die App die Daten des Hintergrunddienstes nicht. Config/Local.xcconfig prüfen und neu bauen.")
            }
        case let .waiting(message):
            ContentUnavailableView {
                Label("Warte auf den Hintergrunddienst", systemImage: "hourglass")
            } description: {
                Text(message)
            }
        case let .failed(message):
            ContentUnavailableView {
                Label("Daten nicht lesbar", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Erneut laden") { Task { await library.reload() } }
            }
        }
    }
}

/// Einfache Markdown-Vorschau mit Überschriften, Listen, Zitaten und Codeblöcken.
struct MarkdownPreview: View {
    let text: String

    var body: some View {
        let blocks = MarkdownBlock.parse(text)
        if blocks.isEmpty {
            Text("Kein Inhalt.")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            inline(text)
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, level <= 2 ? 6 : 2)
                .accessibilityAddTraits(.isHeader)
        case let .paragraph(text):
            inline(text)
        case let .bullet(text, depth):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "•").accessibilityHidden(true)
                inline(text)
            }
            .padding(.leading, CGFloat(depth) * 16)
        case let .numbered(text, number):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "\(number).")
                inline(text)
            }
        case let .task(text, checked):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: checked ? "checkmark.square" : "square")
                    .accessibilityLabel(checked ? Text("Erledigt") : Text("Offen"))
                inline(text)
            }
        case let .quote(text):
            inline(text)
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 3) }
        case let .code(code, _):
            Text(verbatim: code)
                .font(.system(.callout, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        case .rule:
            Divider()
        case let .frontmatter(yaml):
            DisclosureGroup {
                Text(verbatim: yaml)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Frontmatter")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func inline(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(verbatim: text)
    }
}

/// Unified-Diff mit farbigen Zeilen (+ grün, − rot, Abschnittsköpfe blau).
struct UnifiedDiffView: View {
    let diff: String

    var body: some View {
        let lines = UnifiedDiff.lines(diff)
        if lines.allSatisfy({ $0.text.isEmpty }) {
            Text("Keine Änderungen.")
                .foregroundStyle(.secondary)
        } else {
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        Text(verbatim: line.text.isEmpty ? " " : line.text)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(foreground(line.kind))
                            .padding(.horizontal, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(background(line.kind))
                            .accessibilityLabel(Text(accessibilityPrefix(line.kind) + line.text))
                    }
                }
                .textSelection(.enabled)
            }
        }
    }

    private func foreground(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .hunk: .blue
        case .header: .secondary
        default: .primary
        }
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: .green.opacity(0.15)
        case .removed: .red.opacity(0.15)
        default: .clear
        }
    }

    private func accessibilityPrefix(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .added: String(localized: "Hinzugefügt: ")
        case .removed: String(localized: "Entfernt: ")
        default: ""
        }
    }
}

/// Zwei Stände nebeneinander (Dateikonflikt: App-Stand links, externer Stand rechts).
struct SideBySideDiffView: View {
    let leftTitle: String
    let rightTitle: String
    let left: String
    let right: String

    var body: some View {
        let rows = SideBySideDiff.rows(left: left, right: right)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(leftTitle).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                Text(rightTitle).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(6)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        HStack(spacing: 1) {
                            cell(row.left, highlighted: row.change == .changed || row.change == .onlyLeft, color: .red)
                            cell(row.right, highlighted: row.change == .changed || row.change == .onlyRight, color: .green)
                        }
                    }
                }
                .textSelection(.enabled)
            }
        }
    }

    private func cell(_ text: String?, highlighted: Bool, color: Color) -> some View {
        Text(verbatim: text ?? " ")
            .font(.system(.callout, design: .monospaced))
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? color.opacity(0.15) : Color.clear)
            .foregroundStyle(text == nil ? .secondary : .primary)
    }
}

/// Finder/Terminal/Editor für lokale Pfade (Worktree öffnen, Datei bearbeiten).
enum LocalOpener {
    static func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
    }

    static func openInTerminal(_ path: String) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([URL(filePath: path, directoryHint: .isDirectory)], withApplicationAt: terminal,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    /// Öffnet die Datei im Standardeditor des Benutzers. Änderungen erkennt der Dienst und gleicht sie ab (E3).
    static func openFile(_ path: String) -> Bool {
        NSWorkspace.shared.open(URL(filePath: path))
    }

    static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

/// Zeile „Bezeichnung: Wert“ mit auswählbarem Wert.
struct InfoRow: View {
    let label: LocalizedStringKey
    let value: String

    init(_ label: LocalizedStringKey, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        // Nebeneinander, wenn der Wert in eine Zeile passt; sonst untereinander, damit schmale Spalten den Wert
        // nicht silbenweise umbrechen („Nachfrage/n“).
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 150, alignment: .leading)
                Text(value)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .foregroundStyle(.secondary)
                Text(value)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Abschnittskasten in voller Breite mit Überschrift (Hell/Dunkel über Systemfarben).
struct CardGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            configuration.content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

extension Date {
    var shortDateTime: String { formatted(date: .abbreviated, time: .shortened) }
}

extension View {
    /// Ausdrückliche Mindestgröße für eine `HSplitView` in der Detailspalte des Hauptfensters. Ohne sie meldete die
    /// Teilung dort rund 1.000 pt Mindestbreite, unabhängig von ihren Spalten, und das Fenster ließ sich nicht
    /// kleiner ziehen. `width` ist die Summe der Mindestbreiten der Spalten.
    func splitViewMinimum(width: CGFloat) -> some View {
        frame(minWidth: width + 1, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
    }
}
