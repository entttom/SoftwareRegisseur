import SwiftUI
import SoftwareRegisseurAI
import SoftwareRegisseurAppCore
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

/// „Diktat“ (spec P 5, H2): Apple speech recognition or OpenAI transcription; record, pause, listen,
/// delete, transcribe, correct, save, and continue with AI drafting.
struct DictationView: View {
    @Environment(AppModel.self) private var model

    @State private var recorder: AudioRecorder?
    @State private var permissionFlow: PermissionFlow?
    @State private var showsPermissionScreen = false
    @State private var appleAvailability: AppleSpeechAvailability?
    @State private var isDownloadingModel = false
    @State private var rawTranscript: String?
    @State private var editedText = ""
    @State private var consentGate: UploadConsentGate?
    @State private var showsConsent = false
    @State private var isTranscribing = false
    @State private var progress: (Int, Int)?
    @State private var usage: AIUsage?
    @State private var projects: [Project] = []
    @State private var projectID: ProjectID?
    @State private var type: WorkItemType = .note
    @State private var savedItem: WorkItem?
    @State private var showsDrafting = false
    @State private var error: String?

    private var method: TranscriptionMethod { model.settings.dictationMethod }

    var body: some View {
        Form {
            methodSection
            recordingSection
            if recorder?.state == .finished || rawTranscript != nil {
                transcriptSection
            }
            if let error { ErrorText(message: error) }
            if let savedItem { savedSection(savedItem) }
        }
        .accessibilityIdentifier("dictation.form")
        .readableContentWidth()
        .navigationTitle("Diktat")
        .task {
            if recorder == nil { recorder = AudioRecorder(directory: model.directories.audioDirectory) }
            projects = ((try? await model.database?.projects.list()) ?? []).filter { $0.status != .archived }
        }
        .task(id: model.settings.speechLocaleIdentifier) { await refreshAppleAvailability() }
        .fullScreenCover(isPresented: $showsPermissionScreen) {
            if let permissionFlow { PermissionFlowScreen(flow: permissionFlow) }
        }
        .onChange(of: permissionFlow?.step) { _, step in
            switch step {
            case .granted?:
                showsPermissionScreen = false
                permissionFlow?.reset()
                recorder?.start()
            case .idle?:
                showsPermissionScreen = false
            default:
                break
            }
        }
        .sheet(isPresented: $showsConsent) {
            if let provider = method.uploadProvider {
                UploadConsentSheet(provider: provider, duration: recorder?.duration ?? 0) { granted in
                    showsConsent = false
                    if granted {
                        consentGate?.grant(at: .now)
                        Task { await transcribe() }
                    } else {
                        consentGate?.deny(at: .now)
                    }
                }
            }
        }
        .sheet(isPresented: $showsDrafting) {
            if let savedItem {
                DraftingView(item: savedItem, autoPrepare: model.settings.autoDraftAfterDictation)
                    .presentationSizing(.page)
            }
        }
    }

    // MARK: Sections

    private var methodSection: some View {
        @Bindable var model = model
        return Section {
            Picker(selection: $model.settings.dictationMethod) {
                ForEach(TranscriptionMethod.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                Text("Spracherkennung")
            }
            switch method {
            case .appleSpeech:
                appleStatus
            case .openAI:
                openAIStatus
            }
        } header: {
            Text(DeviceKind.current.pick(phone: "Methode (dieses iPhone)", pad: "Methode (dieses iPad)") as LocalizedStringResource)
        } footer: {
            Text("Ein Wechsel der Methode verwirft keine Aufnahme und kein Transkript.")
        }
    }

    @ViewBuilder
    private var appleStatus: some View {
        switch appleAvailability {
        case nil:
            HStack { ProgressView(); Text("Verfügbarkeit wird geprüft …") }
        case let .installed(locale, _)?:
            // Coloured symbol, text in the label colour: green/orange text is too faint (A29 contrast).
            Label {
                Text("Auf diesem Gerät verfügbar, auch offline (\(locale)).")
            } icon: {
                Image(systemName: "checkmark.circle").foregroundStyle(.green)
            }
        case let .downloadRequired(locale, module)?:
            VStack(alignment: .leading, spacing: 6) {
                Label("Sprachmodell für \(locale) muss einmalig geladen werden (Internet nötig).", systemImage: "arrow.down.circle")
                Button {
                    Task { await downloadModel(locale: locale, module: module) }
                } label: {
                    if isDownloadingModel {
                        ProgressView()
                    } else {
                        Text("Sprachmodell laden")
                    }
                }
                .disabled(isDownloadingModel)
            }
        case .unsupportedLocale?:
            Label {
                Text("Die Apple-Spracherkennung unterstützt die eingestellte Sprache auf diesem Gerät nicht. Bitte OpenAI-Transkription wählen.")
            } icon: {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        case .unavailable?:
            Label {
                Text("Die Apple-Spracherkennung ist auf diesem Gerät nicht verfügbar. Bitte OpenAI-Transkription wählen.")
            } icon: {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var openAIStatus: some View {
        switch model.keys.status(provider: .openai, purpose: .transcription) {
        case .stored:
            Label("OpenAI-Schlüssel für Transkription hinterlegt. Audio wird erst nach Ihrer Bestätigung übertragen.",
                  systemImage: "key")
        case .missing:
            VStack(alignment: .leading, spacing: 6) {
                Label("Kein OpenAI-Schlüssel für Transkription hinterlegt.", systemImage: "key.slash")
                    .foregroundStyle(.orange)
                NavigationLink("Schlüssel hinterlegen") {
                    ProviderKeyView(provider: .openai, purpose: .transcription)
                }
            }
        case let .unreadable(message):
            ErrorText(message: message)
        }
    }

    private var recordingSection: some View {
        Section {
            if let recorder {
                HStack {
                    Text(Duration.seconds(recorder.duration), format: .time(pattern: .minuteSecond))
                        .font(.title2.monospacedDigit())
                        .accessibilityLabel(Text("Aufnahmedauer"))
                    Spacer()
                    if recorder.state == .recording {
                        ProgressView(value: Double(recorder.level))
                            .frame(width: 100)
                            .accessibilityLabel(Text("Pegel"))
                    }
                }
                if let message = recorder.lastError { ErrorText(message: message) }
                controls(recorder)
            }
        } header: {
            Text("Aufnahme")
        }
    }

    @ViewBuilder
    private func controls(_ recorder: AudioRecorder) -> some View {
        switch recorder.state {
        case .idle:
            Button {
                startRequested()
            } label: {
                Label("Aufnahme starten", systemImage: "mic.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.title3)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .accessibilityIdentifier("dictation.start")
        case .recording, .paused:
            // Large bordered buttons: easy to hit by finger and pointer, with ⌘⇧P / ⌘⇧D on a keyboard.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { recordingButtons(recorder) }
                VStack(spacing: 12) { recordingButtons(recorder) }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        case .finished:
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { finishedButtons(recorder) }
                VStack(spacing: 12) { finishedButtons(recorder) }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            if rawTranscript == nil {
                Button {
                    transcribeRequested()
                } label: {
                    if isTranscribing {
                        HStack {
                            ProgressView()
                            if let progress {
                                Text("Abschnitt \(progress.0) von \(progress.1)")
                            } else {
                                Text("Wird transkribiert …")
                            }
                        }
                    } else {
                        Label("Transkribieren", systemImage: "text.bubble")
                    }
                }
                .disabled(isTranscribing || !canTranscribe)
            }
        }
    }

    @ViewBuilder
    private func recordingButtons(_ recorder: AudioRecorder) -> some View {
        if recorder.state == .recording {
            Button { recorder.pause() } label: {
                Label("Pausieren", systemImage: "pause.fill").frame(maxWidth: .infinity)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
        } else {
            Button { recorder.resume() } label: {
                Label("Fortsetzen", systemImage: "record.circle").frame(maxWidth: .infinity)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
        }
        Button { recorder.stop() } label: {
            Label("Beenden", systemImage: "stop.fill").frame(maxWidth: .infinity)
        }
        .keyboardShortcut("d", modifiers: [.command, .shift])
    }

    @ViewBuilder
    private func finishedButtons(_ recorder: AudioRecorder) -> some View {
        Button { recorder.togglePlayback() } label: {
            Label(recorder.isPlaying ? "Stopp" : "Anhören", systemImage: recorder.isPlaying ? "stop.fill" : "play.fill")
                .frame(maxWidth: .infinity)
        }
        Button(role: .destructive) {
            recorder.discardFile()
            rawTranscript = nil
            editedText = ""
            usage = nil
        } label: {
            Label("Löschen", systemImage: "trash").frame(maxWidth: .infinity)
        }
    }

    private var transcriptSection: some View {
        Section {
            TextEditor(text: $editedText)
                .frame(minHeight: 140)
                .accessibilityLabel(Text("Transkript"))
            if let usage, method == .openAI {
                UsageView(usage: usage, provider: .openai, modelID: model.settings.transcriptionModel)
            }
            Picker(selection: $type) {
                ForEach(WorkItemType.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                Text("Typ")
            }
            Picker(selection: $projectID) {
                Text("Ohne Projekt (Inbox)").tag(ProjectID?.none)
                ForEach(projects) { Text(verbatim: $0.name).tag(ProjectID?.some($0.id)) }
            } label: {
                Text("Projekt")
            }
            Button("Speichern") { Task { await save(thenDraft: false) } }
                .disabled(editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Speichern und mit KI ausarbeiten") { Task { await save(thenDraft: true) } }
                .disabled(editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } header: {
            Text("Transkript korrigieren")
        } footer: {
            Text("Gespeichert werden Ihre korrigierte Fassung als Originalnotiz und das unveränderte Transkript. Ein KI-Entwurf startet nie einen Agenten.")
        }
    }

    private func savedSection(_ item: WorkItem) -> some View {
        Section {
            Label("Gespeichert: \(item.title)", systemImage: "checkmark.circle").foregroundStyle(.green)
            Button("Aufgabe öffnen") { model.openTask(item.uuid) }
            Button("Neue Aufnahme") {
                savedItem = nil
                rawTranscript = nil
                editedText = ""
                usage = nil
            }
        }
    }

    // MARK: Logic

    private var canTranscribe: Bool {
        switch method {
        case .appleSpeech:
            if case .installed = appleAvailability { return true }
            return false
        case .openAI:
            if case .stored = model.keys.status(provider: .openai, purpose: .transcription) { return true }
            return false
        }
    }

    /// Every recording goes through the permission flow (spec Q4).
    private func startRequested() {
        error = nil
        savedItem = nil
        let flow = PermissionFlow(required: method.requiredPermissions, authorizer: model.permissions)
        permissionFlow = flow
        flow.begin()
        if flow.step == .granted {
            flow.reset()
            recorder?.start()
        } else {
            showsPermissionScreen = true
        }
    }

    private func transcribeRequested() {
        error = nil
        if method.uploadsAudio {
            var gate = consentGate?.method == method ? consentGate! : UploadConsentGate(method: method)
            if case .denied = gate.consent { gate = UploadConsentGate(method: method) }
            consentGate = gate
            if gate.needsDecision {
                showsConsent = true
                return
            }
        }
        Task { await transcribe() }
    }

    private func transcribe() async {
        guard let recorder, let file = recorder.fileURL else { return }
        isTranscribing = true
        defer {
            isTranscribing = false
            progress = nil
        }
        let hints = TranscriptionHints.sanitized(model.settings.transcriptionHints)
        do {
            switch method {
            case .appleSpeech:
                guard case let .installed(locale, module) = appleAvailability else { return }
                let text = try await AppleSpeechService.transcribe(file: file, localeIdentifier: locale, module: module, hints: hints)
                rawTranscript = text
                editedText = text
            case .openAI:
                guard let gate = consentGate else { return }
                let provider = try model.keys.transcriptionProvider()
                let segmentDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("Segments-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: segmentDirectory) }
                let service = ConsentedTranscriptionService(
                    transcriber: ChunkedTranscriber(provider: provider, segmenter: AVAudioSegmenter(outputDirectory: segmentDirectory))
                )
                let template = TranscriptionRequest(
                    audio: try AudioPayload(fileURL: file), model: model.settings.transcriptionModel, keywords: hints
                )
                let result = try await service.transcribe(file: file, duration: recorder.duration, template: template, gate: gate) { done, total in
                    Task { @MainActor in progress = (done, total) }
                }
                rawTranscript = result.text
                editedText = result.text
                usage = result.usage
            }
        } catch AppleSpeechError.emptyResult {
            error = String(localized: "Es wurde keine Sprache erkannt. Bitte erneut aufnehmen.")
        } catch {
            self.error = errorMessage(error)
        }
    }

    private func save(thenDraft: Bool) async {
        guard let database = model.database else { return }
        let note = editedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = WorkItem(projectId: projectID, type: type, title: CaptureTitle.make(from: note), originalNote: note,
                            transcript: rawTranscript, status: projectID == nil ? .inbox : .open, createdAt: .now)
        do {
            try await database.workItems.insert(item, actor: model.actor, at: .now)
            applyRetention(item: item, database: database)
            savedItem = item
            rawTranscript = nil
            editedText = ""
            model.noteLocalChange()
            if thenDraft || model.settings.autoDraftAfterDictation { showsDrafting = true }
        } catch {
            self.error = errorMessage(error)
        }
    }

    /// Spec H2: by default the recording is deleted after successful processing; otherwise it stays on the
    /// device (audio never syncs, `AudioNote` is device-local).
    private func applyRetention(item: WorkItem, database: AppDatabase) {
        guard let recorder, let file = recorder.fileURL else { return }
        let policy = model.settings.audioRetention
        if AudioRetention.shouldDelete(policy: policy, transcriptionSucceeded: true, recordedAt: recorder.recordedAt ?? .now, now: .now) {
            recorder.discardFile()
            return
        }
        let note = AudioNote(workItemId: item.uuid, localAssetRef: file.lastPathComponent, provider: method.domainProvider,
                             consent: consentGate?.consent ?? method.initialConsent, transcriptionState: .completed,
                             retentionPolicy: policy, createdAt: recorder.recordedAt ?? .now)
        Task { try? await database.aiRecords.saveAudioNote(note, at: .now) }
        recorder.detachFile()
    }

    private func refreshAppleAvailability() async {
        appleAvailability = await AppleSpeechService.availability(localeIdentifier: model.settings.speechLocaleIdentifier)
    }

    private func downloadModel(locale: String, module: AppleSpeechModule) async {
        isDownloadingModel = true
        defer { isDownloadingModel = false }
        do {
            try await AppleSpeechService.downloadModel(localeIdentifier: locale, module: module)
            await refreshAppleAvailability()
        } catch {
            self.error = String(localized: "Das Sprachmodell konnte nicht geladen werden: \(error.localizedDescription)")
        }
    }
}
