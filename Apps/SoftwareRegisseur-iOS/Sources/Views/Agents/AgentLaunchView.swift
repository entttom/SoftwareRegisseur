import SwiftUI
import SoftwareRegisseurAppCore
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

/// „Mit Agent umsetzen“ (spec J2, J2a, K1): agent → model → effort, start option, then an `AgentJob`
/// request with idempotency key and resolved configuration snapshot. The Mac executes it.
struct AgentLaunchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: WorkItem

    private enum LaunchChoice: Hashable {
        case saveOnly, startNow, scheduleAt, quota
    }

    @State private var context: JobRequestContext?
    @State private var submitter: JobRequestSubmitter?
    @State private var input = JobRequestInput()
    @State private var launch: LaunchChoice = .startNow
    @State private var scheduledDate = Date.now.addingTimeInterval(3600)
    @State private var timeZoneID = TimeZone.current.identifier
    @State private var quotaReset = Date.now.addingTimeInterval(3 * 3600)
    @State private var error: String?
    @State private var isSubmitting = false
    @State private var result: JobCreationResult?

    var body: some View {
        NavigationStack {
            Group {
                if let context {
                    if let result {
                        confirmation(result)
                    } else {
                        form(context)
                    }
                } else if let error {
                    ContentUnavailableView {
                        Label("Daten konnten nicht geladen werden", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Mit Agent umsetzen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(result == nil ? "Abbrechen" : "Fertig") { dismiss() }
                        .accessibilityIdentifier("agentLaunch.close")
                }
            }
        }
        .task { await load() }
    }

    private func form(_ context: JobRequestContext) -> some View {
        let evaluation = JobRequestPlanner.evaluate(resolvedInput, context: context, now: .now)
        return Form {
            macSection(context, evaluation: evaluation)
            agentSection(context)
            if let capability = evaluation.capability {
                modelSection(capability, evaluation: evaluation)
                effortSection(capability, evaluation: evaluation)
            }
            launchSection
            Section {
                Picker(selection: $input.priority) {
                    ForEach(Priority.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    Text("Priorität")
                }
            }
            summarySection(evaluation)
            if let error { ErrorText(message: error) }
            Section {
                Button {
                    Task { await submit() }
                } label: {
                    Text(submitTitle).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!evaluation.canSubmit || isSubmitting)
                .accessibilityIdentifier("agentLaunch.submit")
            } footer: {
                Text("Der Auftrag wird lokal gespeichert und beim nächsten Abgleich vom Mac übernommen. Eine KI-Ausarbeitung startet nie einen Agenten.")
            }
        }
        .accessibilityIdentifier("agentLaunch.form")
    }

    @ViewBuilder
    private func macSection(_ context: JobRequestContext, evaluation: JobRequestEvaluation) -> some View {
        let host = evaluation.capability.flatMap { context.host(for: $0) }
        Section {
            if let host {
                LabeledContent {
                    HostReachabilityText(offline: HostAvailability.isOffline(host, now: .now))
                } label: {
                    Text(verbatim: host.name)
                }
                if HostAvailability.isOffline(host, now: .now) {
                    Text("Zuletzt erkannt – Mac derzeit offline. Der Auftrag wartet („Wartet auf Mac“), bis der Mac erreichbar ist.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Noch kein Mac gemeldet. Der Auftrag kann erst angelegt werden, wenn ein Mac seine Agenten synchronisiert hat.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Ausführung am Mac")
        }
    }

    private func agentSection(_ context: JobRequestContext) -> some View {
        Section {
            let providers = context.selectableProviders
            if providers.isEmpty {
                Text("Kein startbereiter Coding-Agent gemeldet. Bitte am Mac Codex oder Claude Code installieren und anmelden.")
                    .foregroundStyle(.secondary)
            }
            ForEach(providers, id: \.self) { provider in
                let capability = context.capability(for: provider)
                OptionRow(title: "\(capability?.displayName ?? provider.rawValue)",
                          detail: capability.map { "\($0.version)" },
                          selected: input.providerId == provider) {
                    if input.providerId != provider {
                        input.providerId = provider
                        input.modelOverride = nil
                        input.effortOverride = nil
                    }
                }
                .accessibilityIdentifier("agentLaunch.provider.\(provider.rawValue)")
            }
        } header: {
            Text("Agent")
        }
    }

    private func modelSection(_ capability: AgentCapability, evaluation: JobRequestEvaluation) -> some View {
        Section {
            OptionRow(title: "Standard übernehmen",
                      detail: inheritedModelDetail(evaluation),
                      selected: input.modelOverride == nil) {
                input.modelOverride = nil
            }
            ForEach(JobRequestPlanner.modelChoices(for: capability)) { choice in
                OptionRow(title: choice.selection.title,
                          detail: choice.isSelectable ? nil : choice.availability.title,
                          selected: input.modelOverride == choice.selection,
                          enabled: choice.isSelectable) {
                    input.modelOverride = choice.selection
                }
            }
            if !capability.supportsModelSelection {
                Text("Dieser Agent erlaubt keine Modellwahl; er verwendet sein Standardmodell.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Modell")
        }
    }

    private func effortSection(_ capability: AgentCapability, evaluation: JobRequestEvaluation) -> some View {
        Section {
            if !capability.supportsEffortSelection {
                Text("Anbieterstandard – nicht einstellbar")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("agentLaunch.effortNotAdjustable")
            } else {
                OptionRow(title: "Standard übernehmen", detail: inheritedEffortDetail(evaluation),
                          selected: input.effortOverride == nil) {
                    input.effortOverride = nil
                }
                ForEach(JobRequestPlanner.effortChoices(for: capability, model: evaluation.effectiveModel), id: \.self) { effort in
                    OptionRow(title: effort.title, detail: effort.explanation, selected: input.effortOverride == effort) {
                        input.effortOverride = effort
                    }
                    .accessibilityIdentifier("agentLaunch.effort.\(effort.rawValue)")
                }
            }
        } header: {
            Text("Denk-/Effort-Stufe")
        } footer: {
            Text("Die Stufe ist eine Ausführungsressource, keine Einschätzung der Aufgabenschwierigkeit.")
        }
    }

    private var launchSection: some View {
        Section {
            Picker(selection: $launch) {
                Text("Nur speichern").tag(LaunchChoice.saveOnly)
                Text("Jetzt starten").tag(LaunchChoice.startNow)
                Text("Für später einplanen").tag(LaunchChoice.scheduleAt)
                Text("Bei Kontingent verfügbar erneut versuchen").tag(LaunchChoice.quota)
            } label: {
                Text("Start")
            }
            .pickerStyle(.inline)
            .labelsHidden()
            switch launch {
            case .saveOnly:
                Text("Auftrag und Konfiguration werden gespeichert; der Mac startet erst nach Ihrer Freigabe.")
                    .font(.caption).foregroundStyle(.secondary)
            case .startNow:
                EmptyView()
            case .scheduleAt:
                DatePicker(selection: $scheduledDate, in: Date.now..., displayedComponents: [.date, .hourAndMinute]) {
                    Text("Zeitpunkt")
                }
                .environment(\.timeZone, TimeZone(identifier: timeZoneID) ?? .current)
                Picker(selection: $timeZoneID) {
                    ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text(verbatim: $0).tag($0) }
                } label: {
                    Text("Zeitzone")
                }
                .pickerStyle(.navigationLink)
            case .quota:
                DatePicker(selection: $quotaReset, in: Date.now..., displayedComponents: [.date, .hourAndMinute]) {
                    Text("Erwartete Kontingent-Rücksetzung")
                }
                Text("Der Rücksetzzeitpunkt ist Ihre Angabe; er wird nicht vom Anbieter ausgelesen. Weitere Kontingentfehler wiederholt der Mac mit begrenztem Backoff.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Start")
        }
    }

    @ViewBuilder
    private func summarySection(_ evaluation: JobRequestEvaluation) -> some View {
        Section {
            if let resolution = evaluation.resolution {
                // Stacked rows instead of LabeledContent: in the iPad form sheet the audit rated the caption in
                // the trailing value column as not scaling with Dynamic Type.
                VStack(alignment: .leading, spacing: 2) {
                    Text("Modell")
                    Text(resolution.resolvedModel.title).foregroundStyle(.secondary)
                    Text("Quelle: \(String(localized: resolution.profileSource.model.title))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Denkstufe")
                    Group {
                        if resolution.effortAdjustable {
                            Text(resolution.resolvedEffort.title)
                        } else {
                            Text("Anbieterstandard – nicht einstellbar")
                        }
                    }
                    .foregroundStyle(.secondary)
                    Text("Quelle: \(String(localized: resolution.profileSource.effort.title))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            ForEach(Array(evaluation.blockers.enumerated()), id: \.offset) { _, blocker in
                ErrorText(message: String(localized: blocker.message))
                    .accessibilityIdentifier("agentLaunch.blocker")
                if case let .configuration(issues) = blocker {
                    ForEach(issues, id: \.self) { issue in
                        Text(issue.message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Wird so beauftragt")
        }
    }

    private func confirmation(_ result: JobCreationResult) -> some View {
        ContentUnavailableView {
            Label(result.wasCreated ? "Auftrag angelegt" : "Auftrag war bereits angelegt", systemImage: "checkmark.circle")
        } description: {
            Text("Status: \(String(localized: result.job.state.title)). Der Mac prüft Modell und Denkstufe vor dem Start erneut und hält den Auftrag an, falls die Kombination nicht mehr verfügbar ist.")
        }
    }

    private var submitTitle: LocalizedStringResource {
        switch launch {
        case .saveOnly: "Auftrag speichern"
        case .startNow: "Jetzt starten"
        case .scheduleAt: "Einplanen"
        case .quota: "Bei Kontingent starten"
        }
    }

    private func inheritedModelDetail(_ evaluation: JobRequestEvaluation) -> LocalizedStringResource {
        "Aktuell: \(String(localized: evaluation.effectiveModel.title))"
    }

    private func inheritedEffortDetail(_ evaluation: JobRequestEvaluation) -> LocalizedStringResource? {
        guard input.effortOverride == nil, let resolution = evaluation.resolution else { return nil }
        return "Aktuell: \(String(localized: resolution.resolvedEffort.title))"
    }

    private var resolvedInput: JobRequestInput {
        var value = input
        value.launchOption = switch launch {
        case .saveOnly: .saveOnly
        case .startNow: .startNow
        case .scheduleAt: zonedSchedule.map(JobLaunchOption.scheduleAt) ?? .startNow
        case .quota: .retryWhenQuotaAvailable(expectedReset: quotaReset)
        }
        return value
    }

    private var zonedSchedule: ZonedLocalDateTime? {
        guard let zone = TimeZone(identifier: timeZoneID) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: scheduledDate)
        guard let year = parts.year, let month = parts.month, let day = parts.day, let hour = parts.hour, let minute = parts.minute
        else { return nil }
        return try? ZonedLocalDateTime(year: year, month: month, day: day, hour: hour, minute: minute, timeZoneIdentifier: timeZoneID)
    }

    private func load() async {
        guard let database = model.database else { return }
        do {
            let catalog = try await model.loadCatalog()
            let current = try await database.workItems.fetch(item.uuid) ?? item
            let project = catalog.project(current.projectId)
            let global = try await database.preferences.preferences(scope: .global)
            var projectPrefs: [AgentModelPreference] = []
            var settings: ProjectSettings?
            if let project {
                projectPrefs = try await database.preferences.preferences(scope: .project(project.id))
                settings = try await database.projects.settings(forProject: project.id)
            }
            let hasActiveJob = try await database.jobs.activeJob(forWorkItem: current.uuid) != nil
            let context = JobRequestContext(
                workItem: current, project: project, capabilities: catalog.capabilities, hosts: catalog.hosts,
                globalPreferences: Dictionary(global.map { ($0.providerId, $0) }, uniquingKeysWith: { a, _ in a }),
                projectPreferences: Dictionary(projectPrefs.map { ($0.providerId, $0) }, uniquingKeysWith: { a, _ in a }),
                hasActiveJob: hasActiveJob
            )
            self.context = context
            if submitter == nil { submitter = JobRequestSubmitter(jobs: database.jobs) }
            if input.providerId == nil {
                let preferred = model.globalSettings.preferredAgent(project: settings)
                input.providerId = preferred.flatMap { context.selectableProviders.contains($0) ? $0 : nil }
                    ?? context.selectableProviders.first
            }
            input.priority = current.priority
        } catch {
            self.error = errorMessage(error)
        }
    }

    private func submit() async {
        guard let context, let submitter else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            result = try await submitter.submit(resolvedInput, context: context, actor: model.actor, now: .now)
            error = nil
            model.noteLocalChange()
        } catch let blocked as JobRequestError {
            if case let .blocked(blockers) = blocked {
                error = blockers.map { String(localized: $0.message) }.joined(separator: "\n")
            }
        } catch {
            self.error = errorMessage(error)
        }
    }
}
