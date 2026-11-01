import SwiftUI
import SoftwareRegisseurAppCore
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC

/// „Mit Agent umsetzen“ am Mac (J2a, K1): Agent → Modell → Stufe, Zeitplan, Priorität. Die Kombination wird
/// vor dem Senden geprüft; der Dienst prüft erneut und hält nie still auf einen Ersatz (ADR-0006).
struct JobRequestSheet: View {
    @Environment(LibraryStore.self) private var library
    @Environment(ServiceMonitor.self) private var monitor
    @Environment(CommandCenter.self) private var commands
    @Environment(NavigationModel.self) private var navigation
    @Environment(\.dismiss) private var dismiss

    let item: WorkItem
    @State private var form: JobRequestForm
    @State private var isSubmitting = false
    @State private var serviceError: String?

    init(item: WorkItem) {
        self.item = item
        let start = Calendar.current.date(byAdding: .hour, value: 1, to: .now) ?? .now
        _form = State(initialValue: JobRequestForm(providerId: nil, schedule: ScheduleForm(date: start)))
    }

    var body: some View {
        let snapshot = library.snapshot
        let hostId = monitor.currentSummary?.hostId
        let capabilities = snapshot.capabilities(hostId: hostId)
        let capability = capabilities.first { $0.providerId == form.providerId }
        let validation = JobRequestValidation.evaluate(form: form, workItem: item, snapshot: snapshot, hostId: hostId, now: .now)

        VStack(alignment: .leading, spacing: 12) {
            Text("Mit Agent umsetzen").font(.title2.bold())
            Text(item.displayTitle).foregroundStyle(.secondary)
            Form {
                Section {
                    Picker("Agent", selection: $form.providerId) {
                        Text("Bitte wählen").tag(ProviderID?.none)
                        ForEach(capabilities, id: \.providerId) { capability in
                            Text(agentTitle(capability)).tag(ProviderID?.some(capability.providerId))
                                .selectionDisabled(!capability.isReady)
                        }
                    }
                    if capabilities.isEmpty {
                        UnavailableNotice(text: String(localized: "Auf diesem Mac wurde noch kein Coding-Agent erkannt. Unter „Agenten“ können Sie die Erkennung neu starten."))
                    }
                    if let capability {
                        modelPicker(capability, snapshot: snapshot)
                        effortPicker(capability, snapshot: snapshot)
                    }
                } header: {
                    Text("Agent, Modell und Denkstufe")
                } footer: {
                    if let resolved = validation.resolved {
                        Text("Wird ausgeführt mit \(resolved.resolvedModel.germanDisplayName) · \(resolved.effortDisplayText) (Modell aus \(resolved.profileSource.model.displayName), Stufe aus \(resolved.profileSource.effort.displayName)). Spätere Änderungen an Projekt- oder Globalstandards ändern diesen Job nicht.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Section("Zeitplan") {
                    Picker("Start", selection: $form.schedule.choice) {
                        ForEach(ScheduleChoice.allCases) { Text($0.title).tag($0) }
                    }
                    switch form.schedule.choice {
                    case .at:
                        DatePicker("Zeitpunkt", selection: $form.schedule.date)
                        Picker("Zeitzone", selection: $form.schedule.timeZoneIdentifier) {
                            ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text(verbatim: $0).tag($0) }
                        }
                        Picker("Falls der Mac zum Termin schläft", selection: $form.schedule.missedRunPolicy) {
                            ForEach(MissedRunPolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                    case .notBefore:
                        DatePicker("Frühestens ab", selection: $form.schedule.date)
                    case .whenQuotaAvailable:
                        DatePicker("Erwarteter Kontingent-Reset", selection: $form.schedule.date)
                        Text("Der Reset-Zeitpunkt ist Ihre Angabe; er wird nicht vom Anbieter ausgelesen.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .immediate, .saveOnly:
                        EmptyView()
                    }
                    Picker("Priorität", selection: $form.priority) {
                        ForEach(Priority.allCases, id: \.self) { Text($0.germanDisplayName).tag($0) }
                    }
                }
            }
            .formStyle(.grouped)

            ForEach(validation.blockers, id: \.self) { blocker in
                Label(blocker, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let serviceError {
                Label(serviceError, systemImage: "xmark.octagon").foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    submit(validation.command)
                } label: {
                    if isSubmitting { ProgressView().controlSize(.small) } else { Text("Job anlegen") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(validation.command == nil || isSubmitting)
            }
        }
        .padding(20)
        .frame(width: 620, height: 640)
        .onAppear {
            if form.providerId == nil {
                form.providerId = snapshot.globalSettings.preferredAgent(project: snapshot.project(item.projectId)?.settings)
                    ?? capabilities.first(where: \.isReady)?.providerId
            }
        }
        .onChange(of: form.providerId) {
            form.model = nil
            form.effort = nil
        }
        .onChange(of: form.model) {
            form.effort = nil
        }
    }

    private func agentTitle(_ capability: AgentCapability) -> String {
        let name = capability.displayName.isEmpty ? ProviderNames.displayName(capability.providerId) : capability.displayName
        if capability.isReady { return "\(name) \(capability.version)" }
        return String(localized: "\(name) – nicht einsatzbereit")
    }

    private func inheritedModel(_ capability: AgentCapability, snapshot: LibrarySnapshot) -> ModelSelection {
        ModelEffortChoices.inheritedModel(
            project: snapshot.project(item.projectId)?.settings?.modelPreference(for: capability.providerId),
            global: snapshot.globalPreference(for: capability.providerId))
    }

    private func modelPicker(_ capability: AgentCapability, snapshot: LibrarySnapshot) -> some View {
        let inherited = inheritedModel(capability, snapshot: snapshot)
        return Picker("Modell", selection: $form.model) {
            Text("Standard übernehmen (\(inherited.germanDisplayName))").tag(ModelSelection?.none)
            ForEach(ModelEffortChoices.models(for: capability)) { choice in
                Text(modelTitle(choice)).tag(ModelSelection?.some(choice.selection))
                    .selectionDisabled(!choice.isSelectable)
            }
        }
    }

    private func modelTitle(_ choice: ModelChoice) -> String {
        let name = choice.selection == .providerDefault ? ModelSelection.providerDefault.germanDisplayName : choice.displayName
        return choice.isSelectable ? name : "\(name) – \(choice.availability.displayName)"
    }

    @ViewBuilder
    private func effortPicker(_ capability: AgentCapability, snapshot: LibrarySnapshot) -> some View {
        let model = form.model ?? inheritedModel(capability, snapshot: snapshot)
        let efforts = ModelEffortChoices.efforts(for: capability, model: model)
        Picker("Denkstufe", selection: $form.effort) {
            Text("Standard übernehmen").tag(EffortLevel?.none)
            ForEach(efforts, id: \.self) { effort in
                Text(effort.germanDisplayName).tag(EffortLevel?.some(effort))
            }
        }
        if let hint = capability.effortSelectionHint {
            Text(hint).font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Die Denkstufe ist eine Ausführungsressource des Agenten, keine Einschätzung der Aufgabe.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func submit(_ command: JobRequestCommand?) {
        guard let command else { return }
        isSubmitting = true
        serviceError = nil
        Task {
            let outcome = await commands.perform(String(localized: "Job anlegen"), .requestJob(command))
            isSubmitting = false
            if case let .job(info)? = outcome.result {
                dismiss()
                navigation.showJob(info.jobId, filter: QueueFilter.category(of: info.state))
            } else {
                serviceError = outcome.feedback.message
            }
        }
    }
}
