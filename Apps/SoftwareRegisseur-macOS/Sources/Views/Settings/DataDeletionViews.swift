import SwiftUI
import SoftwareRegisseurIPC
import SoftwareRegisseurPersistence

/// Lokale Löschung (A34): Umfang wählen → Vorschau des Dienstes → ausdrücklich bestätigen → löschen.
struct LocalDeletionSection: View {
    @Environment(CommandCenter.self) private var commands
    @Environment(LibraryStore.self) private var library
    @State private var kind: LocalDeletionKind = .localDatabase
    @State private var preview: LocalDeletionPreviewInfo?
    @State private var confirmation = DeletionConfirmation()
    @State private var report: LocalDeletionReportInfo?
    @State private var running = false

    var body: some View {
        Picker("Umfang", selection: $kind) {
            ForEach(LocalDeletionKind.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .onChange(of: kind) { reset() }
        CommandButton(String(localized: "Vorschau erstellen"), systemImage: "list.bullet.rectangle") {
            .prepareLocalDeletion(kind)
        } onResult: { outcome in
            report = nil
            confirmation = DeletionConfirmation()
            if case let .localDeletionPreview(info)? = outcome.result { preview = info }
        }
        if let preview {
            VStack(alignment: .leading, spacing: 6) {
                Text(preview.title).font(.headline)
                Text(preview.summary)
                ForEach(Array(preview.items.enumerated()), id: \.offset) { _, item in
                    HStack {
                        Image(systemName: "trash").foregroundStyle(.red).accessibilityHidden(true)
                        Text(item.label)
                        Spacer()
                        if let bytes = item.byteCount {
                            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).foregroundStyle(.secondary)
                        }
                        if item.affectsOtherDevices {
                            Badge(text: String(localized: "auch auf anderen Geräten"), color: .orange)
                        }
                    }
                }
                ForEach(preview.consequences, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                ForEach(preview.retained, id: \.self) { Label($0, systemImage: "checkmark.shield").foregroundStyle(.secondary) }
                Text("Vorschau gültig bis \(preview.expiresAt.formatted(date: .omitted, time: .shortened)).")
                    .font(.caption).foregroundStyle(.secondary)
                if !preview.isEmpty {
                    Toggle("Ich habe die Liste geprüft und möchte diese Daten endgültig löschen.", isOn: $confirmation.confirmed)
                    Button(role: .destructive) {
                        execute(preview)
                    } label: {
                        HStack {
                            if running { ProgressView().controlSize(.small) }
                            Text("Endgültig löschen")
                        }
                    }
                    .disabled(!confirmation.canExecute(preview: preview, now: .now) || running)
                }
            }
        }
        if let report {
            VStack(alignment: .leading, spacing: 4) {
                Label(DeletionConfirmation.summary(report), systemImage: report.isComplete ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(report.isComplete ? Color.green : Color.orange)
                ForEach(report.failed, id: \.self) { Text($0).foregroundStyle(.red) }
            }
        }
    }

    private func reset() {
        preview = nil
        report = nil
        confirmation = DeletionConfirmation()
    }

    private func execute(_ preview: LocalDeletionPreviewInfo) {
        running = true
        let touchesDatabase = preview.kind != .apiKeys
        Task {
            // Eigene Nur-Lese-Verbindung schließen, damit der Dienst die Datenbankdateien entfernen kann.
            if touchesDatabase { library.closeForDeletion() }
            let outcome = await commands.perform(
                String(localized: "Lokale Daten löschen"),
                .executeLocalDeletion(planId: preview.planId, confirmationToken: preview.confirmationToken))
            if touchesDatabase { await library.reopenAfterDeletion() }
            running = false
            self.preview = nil
            confirmation = DeletionConfirmation()
            if case let .localDeletionReport(info)? = outcome.result { report = info }
        }
    }
}

/// Löschung der iCloud-Daten (A34): Vorschau der Folgen, ausdrückliche Bestätigung, dann löscht der
/// Sync-Koordinator die Zone. Lokale Daten bleiben; der Sync bleibt pausiert, bis Sie neu hochladen.
struct CloudDeletionSection: View {
    @Environment(ServiceMonitor.self) private var monitor
    @State private var preview: CloudDeletionPreviewInfo?
    @State private var confirmation = DeletionConfirmation()

    var body: some View {
        let sync = monitor.currentSummary?.sync
        if sync?.state == .unavailable {
            Text(sync?.unavailableReason ?? String(localized: "iCloud-Synchronisierung ist in diesem Build nicht verfügbar."))
                .foregroundStyle(.secondary)
        } else if let deletion = sync?.cloudDataDeletion {
            CloudDeletionStateView(state: deletion)
        } else {
            CommandButton(String(localized: "Folgen anzeigen"), systemImage: "icloud.slash") {
                .prepareCloudDeletion
            } onResult: { outcome in
                confirmation = DeletionConfirmation()
                if case let .cloudDeletionPreview(info)? = outcome.result { preview = info }
            }
            if let preview {
                ForEach(preview.consequences, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                Toggle("Ich möchte alle iCloud-Daten von Software Regisseur endgültig löschen.", isOn: $confirmation.confirmed)
                CommandButton(String(localized: "iCloud-Daten löschen"), systemImage: "trash", role: .destructive) {
                    .confirmCloudDeletion(planId: preview.planId, confirmationToken: preview.confirmationToken)
                } onResult: { _ in
                    self.preview = nil
                    confirmation = DeletionConfirmation()
                }
                .disabled(!confirmation.canConfirmCloud(preview: preview, now: .now))
            }
        }
    }
}

/// Zustand nach einer vom Benutzer ausgelösten iCloud-Löschung mit den passenden nächsten Schritten.
struct CloudDeletionStateView: View {
    let state: SyncSummary.CloudDataDeletionState

    var body: some View {
        switch state {
        case .deleted:
            Label("Ihre iCloud-Daten wurden gelöscht. Die Synchronisierung ist pausiert; lokale Daten bleiben auf diesem Mac.",
                  systemImage: "icloud.slash")
            CommandButton(String(localized: "Wieder mit iCloud synchronisieren"), systemImage: "arrow.clockwise.icloud",
                          confirmation: String(localized: "Die iCloud-Zone wird neu angelegt und alle lokalen Daten werden erneut hochgeladen.")) {
                .recreateCloudZone
            }
        case .pending:
            Label("Das Löschen der iCloud-Daten ist noch nicht bestätigt (z. B. keine Verbindung). Die Synchronisierung bleibt pausiert.",
                  systemImage: "hourglass")
                .foregroundStyle(.orange)
            CommandButton(String(localized: "Löschen erneut versuchen"), systemImage: "arrow.clockwise") { .retryCloudDeletion }
        }
    }
}

/// Zusammenführen eines Sync-Konflikts mit Textfeldern (A24): Vorfahr, dieser Mac, iCloud, Ergebnis.
struct SyncConflictMergeSheet: View {
    @Environment(CommandCenter.self) private var commands
    @Environment(\.dismiss) private var dismiss
    let conflictId: UUID
    let merge: SyncConflictMerge
    @State private var values: [SyncConflictMerge.Field: String]
    @State private var error: String?

    init(conflictId: UUID, merge: SyncConflictMerge) {
        self.conflictId = conflictId
        self.merge = merge
        _values = State(initialValue: merge.initialValues)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Konflikt zusammenführen").font(.title2.bold())
            Text("Links stehen der gemeinsame Vorfahr (falls bekannt), der Stand dieses Macs und der iCloud-Stand. Schreiben Sie rechts den zusammengeführten Text; alle anderen Felder bleiben wie auf diesem Mac.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(merge.fields) { versions in
                        Text(versions.field.displayName).font(.headline)
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 6) {
                                version(String(localized: "Gemeinsamer Vorfahr"), versions.ancestor ?? String(localized: "(nicht bekannt)"))
                                version(String(localized: "Dieser Mac"), versions.local)
                                version(String(localized: "iCloud"), versions.remote)
                            }
                            .frame(maxWidth: .infinity)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Ergebnis").font(.subheadline.weight(.semibold))
                                TextEditor(text: Binding(get: { values[versions.field] ?? "" }, set: { values[versions.field] = $0 }))
                                    .font(.system(.body, design: .monospaced))
                                    .frame(minHeight: 160)
                                    .accessibilityLabel(Text("Ergebnis \(versions.field.displayName)"))
                                HStack {
                                    Button("Mac übernehmen") { values[versions.field] = versions.local }
                                    Button("iCloud übernehmen") { values[versions.field] = versions.remote }
                                }
                                .controlSize(.small)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Zusammengeführt speichern") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 820, minHeight: 600)
    }

    private func version(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(verbatim: text.isEmpty ? " " : text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
        }
    }

    private func save() {
        let payload: Data
        do {
            payload = try merge.mergedPayload(values)
        } catch {
            self.error = String(localized: "Der zusammengeführte Stand konnte nicht erzeugt werden.")
            return
        }
        Task {
            let outcome = await commands.perform(String(localized: "Konflikt zusammenführen"),
                                                 .resolveSyncConflict(conflictId: conflictId, choice: .merged(payload)))
            if outcome.succeeded { dismiss() } else { error = outcome.feedback.message }
        }
    }
}
