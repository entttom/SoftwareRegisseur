import SwiftUI
import UniformTypeIdentifiers
import SoftwareRegisseurAppCore
import SoftwareRegisseurPersistence
import SoftwareRegisseurPortability

/// Einstellungen → „Datenschutz“ (spec Q1 „transparente Löschung und Export“, A34).
struct DataPrivacySection: View {
    var body: some View {
        Section {
            NavigationLink {
                DataExportView()
            } label: {
                Label("Daten exportieren", systemImage: "square.and.arrow.up")
            }
            NavigationLink {
                DataDeletionView()
            } label: {
                Label("Daten löschen", systemImage: "trash")
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Datenschutz")
        } footer: {
            Text("Export aller Projekte, Aufgaben, ADRs, Ereignisse und Einstellungen als JSON und Markdown. Löschen immer mit Vorschau und ausdrücklicher Bestätigung.")
        }
    }
}

// MARK: - Export

struct DataExportView: View {
    @Environment(AppModel.self) private var model
    @State private var export: DataExportModel?
    @State private var savesToFiles = false
    @State private var saveMessage: String?
    @State private var saveError: String?

    var body: some View {
        Form {
            Section {
                Text(DeviceKind.current.pick(
                    phone: "Der Export enthält alle Daten dieses iPhones: Projekte, Aufgaben mit Originalnotizen, Transkripten und Entwürfen, ADRs, Ereignisse, Aufträge, Reviews, Freigaben, KI-Anfragen, Einstellungen und Synchronisierungskonflikte – maschinenlesbar (JSON) und lesbar (Markdown).",
                    pad: "Der Export enthält alle Daten dieses iPads: Projekte, Aufgaben mit Originalnotizen, Transkripten und Entwürfen, ADRs, Ereignisse, Aufträge, Reviews, Freigaben, KI-Anfragen, Einstellungen und Synchronisierungskonflikte – maschinenlesbar (JSON) und lesbar (Markdown)."
                ) as LocalizedStringResource)
                Label("API-Schlüssel werden nie exportiert.", systemImage: "key.slash")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Inhalt")
            }
            if let export {
                content(export)
            } else {
                Text("Die Datenbank ist noch nicht geöffnet.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Daten exportieren")
        .task(id: model.database.map(ObjectIdentifier.init)) {
            if export?.isRunning != true { export = model.makeExportModel() }
        }
        .onDisappear { export?.cancel() }
    }

    @ViewBuilder
    private func content(_ export: DataExportModel) -> some View {
        @Bindable var export = export
        switch export.state {
        case .idle, .cancelled, .failed:
            Section {
                Toggle("Diktataufnahmen einschließen", isOn: $export.includeAudio)
                Button {
                    saveMessage = nil
                    saveError = nil
                    export.start()
                } label: {
                    Label("Export erstellen", systemImage: "doc.zipper")
                }
            } footer: {
                Text(DeviceKind.current.pick(
                    phone: "Aufnahmen werden nie synchronisiert und liegen nur auf diesem iPhone. Der Export wird als ZIP-Archiv erstellt, das Sie teilen oder in „Dateien“ sichern.",
                    pad: "Aufnahmen werden nie synchronisiert und liegen nur auf diesem iPad. Der Export wird als ZIP-Archiv erstellt, das Sie teilen oder in „Dateien“ sichern."
                ) as LocalizedStringResource)
            }
            if export.state == .cancelled {
                Section { Label("Export abgebrochen. Es wurden keine Dateien behalten.", systemImage: "xmark.circle") }
            }
            if case let .failed(failure) = export.state {
                Section { ErrorText(message: failure.message) }
            }
        case let .running(progress):
            Section {
                ProgressView(value: progress.fractionCompleted) {
                    Text(progress.localizedDescription)
                }
                Button("Abbrechen", role: .cancel) { export.cancel() }
            } header: {
                Text("Export läuft")
            }
        case let .finished(outcome):
            Section {
                LabeledContent {
                    Text(outcome.entityCount, format: .number)
                } label: {
                    Text("Exportierte Einträge")
                }
                if outcome.audioFiles > 0 {
                    LabeledContent {
                        Text(outcome.audioFiles, format: .number)
                    } label: {
                        Text("Aufnahmen")
                    }
                }
                LabeledContent {
                    Text(verbatim: outcome.shareURL.lastPathComponent)
                } label: {
                    Text("Datei")
                }
                if outcome.userContentFindings > 0 {
                    Label("In \(outcome.userContentFindings) Textstellen Ihrer Notizen stehen Zeichenfolgen, die wie Zugangsdaten aussehen. Sie wurden unverändert exportiert – bitte prüfen Sie den Export vor der Weitergabe.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if let archiveError = outcome.archiveError {
                    ErrorText(message: archiveError.userMessage)
                }
            } header: {
                Text("Export fertig")
            }
            Section {
                ShareLink(item: outcome.shareURL) {
                    Label("Teilen …", systemImage: "square.and.arrow.up")
                }
                Button {
                    savesToFiles = true
                } label: {
                    Label("In Dateien sichern", systemImage: "folder")
                }
                .fileExporter(isPresented: $savesToFiles, document: ExportFileDocument(url: outcome.shareURL),
                              contentType: outcome.archiveURL != nil ? .zip : .folder,
                              defaultFilename: outcome.shareURL.lastPathComponent) { result in
                    switch result {
                    case .success:
                        saveMessage = String(localized: "Export in „Dateien“ gesichert.")
                        saveError = nil
                    case let .failure(error):
                        saveError = errorMessage(error)
                    }
                }
                if let saveMessage { Label(saveMessage, systemImage: "checkmark.circle").foregroundStyle(.green) }
                if let saveError { ErrorText(message: saveError) }
                Button(role: .destructive) {
                    export.discard()
                    saveMessage = nil
                } label: {
                    Text(DeviceKind.current.pick(
                        phone: "Exportdateien von diesem iPhone entfernen",
                        pad: "Exportdateien von diesem iPad entfernen"
                    ) as LocalizedStringResource)
                }
            } footer: {
                Text("Die Exportdateien liegen bis zum Entfernen im Zwischenspeicher der App.")
            }
        }
    }
}

extension DataExportModel.Failure {
    var message: String {
        switch self {
        case let .export(error): error.userMessage
        case let .unexpected(detail): String(localized: "Der Export ist fehlgeschlagen: \(detail)")
        }
    }
}

/// The finished export (ZIP or folder) for `fileExporter` („In Dateien sichern“).
struct ExportFileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.zip, .folder]
    let url: URL

    init(url: URL) { self.url = url }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: url, options: .immediate)
    }
}

// MARK: - Deletion

struct DataDeletionView: View {
    @Environment(AppModel.self) private var model
    @State private var deletion: DataDeletionModel?
    @State private var showsPlan = false

    var body: some View {
        List {
            Section {
                ForEach(LocalDeletionChoice.allCases, id: \.self) { choice in
                    Button {
                        open { await $0.prepare(choice) }
                    } label: {
                        ChoiceRow(title: choice.title, detail: choice.detail, systemImage: choice.systemImage)
                    }
                }
            } header: {
                Text(DeviceKind.current.pick(phone: "Auf diesem iPhone", pad: "Auf diesem iPad") as LocalizedStringResource)
            } footer: {
                Text("Sie sehen vor dem Löschen genau, welche Dateien und Schlüssel entfernt werden. Git-Repositories auf dem Mac werden nie gelöscht.")
            }
            Section {
                Button {
                    open { await $0.prepareCloudDeletion() }
                } label: {
                    ChoiceRow(title: "iCloud-Daten löschen",
                              detail: "Entfernt alle synchronisierten Daten aus Ihrer privaten iCloud-Datenbank. Lokale Daten und API-Schlüssel – auch im iCloud-Schlüsselbund – bleiben erhalten.",
                              systemImage: "icloud.slash")
                }
                .disabled(deletion?.isCloudDeletionAvailable != true)
                if deletion?.isCloudDeletionAvailable != true {
                    Text(cloudSyncInactiveMessage)
                        .font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("iCloud")
            } footer: {
                Text("Eigener Schritt mit eigener Bestätigung. Danach bleibt die Synchronisierung pausiert, bis Sie „Wieder mit iCloud synchronisieren“ wählen; nichts wird automatisch erneut hochgeladen.")
            }
        }
        .navigationTitle("Daten löschen")
        .task(id: [model.database.map(ObjectIdentifier.init), model.syncCoordinator.map(ObjectIdentifier.init)]) {
            if deletion?.isExecuting != true, !showsPlan { deletion = model.makeDeletionModel() }
        }
        .sheet(isPresented: $showsPlan, onDismiss: {
            deletion?.cancel()
            deletion = model.makeDeletionModel() // fresh eraser for the (possibly reopened) database
        }) {
            if let deletion {
                NavigationStack { DeletionPlanView(deletion: deletion) }
                    .interactiveDismissDisabled(deletion.isExecuting)
            }
        }
    }

    private func open(_ action: @escaping (DataDeletionModel) async -> Void) {
        guard let deletion else { return }
        showsPlan = true
        Task { await action(deletion) }
    }
}

private struct ChoiceRow: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(.red)
                // Explicit colour: inside a Button `.secondary` would take the tint.
                Text(detail).font(.caption).foregroundStyle(Color(uiColor: .secondaryLabel))
            }
        } icon: {
            Image(systemName: systemImage).foregroundStyle(.red)
        }
    }
}

/// Preview → explicit confirmation → result. The destructive button is enabled only after the user
/// confirmed having checked the exact list.
struct DeletionPlanView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Bindable var deletion: DataDeletionModel

    var body: some View {
        Form {
            switch deletion.step {
            case .idle, .preparing:
                Section { ProgressView("Vorschau wird erstellt …") }
            case let .preview(preview), let .executing(preview):
                previewContent(preview)
            case let .completed(completion):
                completionContent(completion)
            case let .failed(failure):
                Section {
                    ErrorText(message: failure.message)
                }
                Section {
                    Button("Schließen") { dismiss() }
                }
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if deletion.preview != nil, !deletion.isExecuting {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
    }

    private var navigationTitle: String {
        switch deletion.preview {
        case let .local(_, plan)?: plan.title
        case let .cloud(plan)?: plan.title
        case nil: String(localized: "Daten löschen")
        }
    }

    @ViewBuilder
    private func previewContent(_ preview: DataDeletionModel.Preview) -> some View {
        switch preview {
        case let .local(choice, plan):
            Section {
                Label {
                    Text(plan.summary).bold()
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.red)
                if let consequence = choice.consequence(pendingChanges: model.syncStatus.pendingCount) {
                    Text(consequence).font(.callout)
                }
            }
            if !plan.items.isEmpty {
                Section {
                    ForEach(plan.items) { item in
                        DeletionItemRow(item: item)
                    }
                } header: {
                    Text("Wird endgültig gelöscht")
                }
            }
            Section {
                ForEach(plan.retained, id: \.self) { note in
                    Label(note, systemImage: "checkmark.shield").font(.callout)
                }
            } header: {
                Text("Bleibt erhalten")
            }
            if !plan.isEmpty {
                confirmation(expiresAt: plan.expiresAt, buttonTitle: "Endgültig löschen")
            }
        case let .cloud(plan):
            Section {
                Label {
                    Text("Ihre iCloud-Daten von Software Regisseur werden endgültig gelöscht.").bold()
                } icon: {
                    Image(systemName: "exclamationmark.icloud.fill")
                }
                .foregroundStyle(.red)
                ForEach(plan.consequences, id: \.self) { Text($0).font(.callout) }
            } header: {
                Text("Folgen")
            }
            Section {
                Label("API-Schlüssel im iCloud-Schlüsselbund werden nicht gelöscht. Sie entfernen sie bei Bedarf unter „API-Schlüssel löschen“.", systemImage: "key")
                Label("Die Synchronisierung bleibt danach pausiert. Nichts wird automatisch erneut hochgeladen – erst wenn Sie „Wieder mit iCloud synchronisieren“ wählen.", systemImage: "pause.circle")
                Label("Ihr Mac und andere Geräte erkennen das Löschen beim nächsten Abgleich und pausieren ebenfalls, bis Sie dort entscheiden.", systemImage: "laptopcomputer.and.iphone")
            } header: {
                Text("Bleibt erhalten")
            }
            .font(.callout)
            confirmation(expiresAt: plan.expiresAt, buttonTitle: "iCloud-Daten endgültig löschen")
        }
    }

    @ViewBuilder
    private func confirmation(expiresAt: Date, buttonTitle: LocalizedStringKey) -> some View {
        Section {
            Toggle(isOn: $deletion.isAcknowledged) {
                Text("Ich habe die Liste geprüft und möchte diese Daten endgültig löschen.")
            }
            .disabled(deletion.isExecuting)
            Button(role: .destructive) {
                Task { await deletion.confirm() }
            } label: {
                HStack {
                    Spacer()
                    if deletion.isExecuting {
                        ProgressView()
                    } else {
                        Text(buttonTitle).bold()
                    }
                    Spacer()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!deletion.canConfirm || deletion.isExecuting)
        } footer: {
            if deletion.isPreviewExpired {
                Text("Die Vorschau ist abgelaufen. Bitte schließen und neu öffnen.").foregroundStyle(.red)
            } else {
                Text("Diese Vorschau gilt bis \(expiresAt.formatted(date: .omitted, time: .shortened)). Es wird genau das Gelistete gelöscht, nichts später Hinzugekommenes. Nicht rückgängig zu machen.")
            }
        }
    }

    @ViewBuilder
    private func completionContent(_ completion: DataDeletionModel.Completion) -> some View {
        switch completion {
        case let .local(choice, report):
            Section {
                Label {
                    Text("\(report.deleted.count) Einträge gelöscht.")
                } icon: {
                    Image(systemName: report.isComplete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                }
                .foregroundStyle(report.isComplete ? .green : .orange)
                if !report.alreadyMissing.isEmpty {
                    Text("\(report.alreadyMissing.count) Einträge waren bereits entfernt.").font(.callout)
                }
                ForEach(report.failed, id: \.item.id) { failure in
                    ErrorText(message: failure.message)
                }
                if choice.resetsDatabase {
                    Text("Die App wurde mit einer leeren Datenbank neu gestartet. Synchronisierte Daten werden beim nächsten Abgleich wieder aus iCloud geladen.")
                        .font(.callout)
                }
            }
        case .cloud:
            Section {
                Label("Die iCloud-Daten wurden gelöscht.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Die Synchronisierung ist pausiert. Unter „Einstellungen → Synchronisierung“ können Sie jederzeit „Wieder mit iCloud synchronisieren“ wählen; dann werden Ihre lokalen Daten erneut hochgeladen.")
                    .font(.callout)
            }
        }
        Section {
            Button("Fertig") { dismiss() }
        }
    }
}

private struct DeletionItemRow: View {
    let item: DeletionItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: item.label)
            HStack(spacing: 8) {
                if let bytes = item.byteCount {
                    Text(bytes, format: .byteCount(style: .file))
                }
                if item.affectsOtherDevices {
                    Label("auch auf Ihren anderen Geräten", systemImage: "icloud")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

extension LocalDeletionChoice {
    var title: LocalizedStringKey {
        switch self {
        case .audioRecordings: "Audioaufnahmen löschen"
        case .apiKeys: "API-Schlüssel löschen"
        case .localDatabase: "Lokale Datenbank und Zwischenspeicher löschen"
        case .everythingLocal: "Alle lokalen Daten löschen"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .audioRecordings:
            DeviceKind.current.pick(
                phone: "Diktataufnahmen auf diesem iPhone. Transkripte und Aufgaben bleiben erhalten.",
                pad: "Diktataufnahmen auf diesem iPad. Transkripte und Aufgaben bleiben erhalten."
            )
        case .apiKeys:
            "Alle API-Schlüssel dieser App im Schlüsselbund – auch Schlüssel im iCloud-Schlüsselbund, die damit auf Ihren anderen Geräten fehlen."
        case .localDatabase:
            "Datenbank und Zwischenspeicher. Synchronisierte Daten werden danach erneut aus iCloud geladen; nicht übertragene Änderungen gehen verloren."
        case .everythingLocal:
            DeviceKind.current.pick(
                phone: "Datenbank, Aufnahmen, Einstellungen, Zwischenspeicher und nur auf diesem iPhone gespeicherte Schlüssel. Schlüssel im iCloud-Schlüsselbund und iCloud-Daten bleiben erhalten.",
                pad: "Datenbank, Aufnahmen, Einstellungen, Zwischenspeicher und nur auf diesem iPad gespeicherte Schlüssel. Schlüssel im iCloud-Schlüsselbund und iCloud-Daten bleiben erhalten."
            )
        }
    }

    var systemImage: String {
        switch self {
        case .audioRecordings: "waveform"
        case .apiKeys: "key"
        case .localDatabase: "externaldrive"
        case .everythingLocal: DeviceKind.current.pick(phone: "iphone.slash", pad: "xmark.bin")
        }
    }

    /// App-specific consequence shown above the exact list.
    func consequence(pendingChanges: Int) -> String? {
        switch self {
        case .audioRecordings:
            nil
        case .apiKeys:
            String(localized: "Ohne Schlüssel sind KI-Ausarbeitung und OpenAI-Transkription nicht verfügbar, bis Sie neue Schlüssel hinterlegen.")
        case .localDatabase, .everythingLocal:
            pendingChanges > 0
                ? String(localized: "\(pendingChanges) Änderungen wurden noch nicht mit iCloud abgeglichen und gehen verloren. Die App startet danach mit einer leeren Datenbank und lädt synchronisierte Daten erneut aus iCloud.")
                : String(localized: "Die App startet danach mit einer leeren Datenbank und lädt synchronisierte Daten erneut aus iCloud.")
        }
    }
}

extension DataDeletionModel.Failure {
    var message: String {
        switch self {
        case let .deletion(error): error.userMessage
        case let .cloud(message): message
        case .cloudUnavailable:
            String(localized: cloudSyncInactiveMessage)
        case let .unexpected(detail): String(localized: "Das Löschen ist fehlgeschlagen: \(detail)")
        }
    }
}

/// „Daten löschen“ without an active iCloud sync (ADR-0025: device-appropriate wording).
let cloudSyncInactiveMessage: LocalizedStringResource = DeviceKind.current.pick(
    phone: "Die iCloud-Synchronisierung ist auf diesem iPhone nicht aktiv; es gibt hier keine iCloud-Daten zu löschen.",
    pad: "Die iCloud-Synchronisierung ist auf diesem iPad nicht aktiv; es gibt hier keine iCloud-Daten zu löschen."
)
