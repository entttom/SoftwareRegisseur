import Foundation
import SoftwareRegisseurAppCore
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC

/// Zeitplanoptionen beim Start/Planen eines Jobs (K1).
enum ScheduleChoice: String, CaseIterable, Identifiable, Hashable, Sendable {
    case immediate
    case at
    case notBefore
    case whenQuotaAvailable
    case saveOnly

    var id: Self { self }

    var title: String {
        switch self {
        case .immediate: String(localized: "Sofort starten")
        case .at: String(localized: "Zu einem Zeitpunkt")
        case .notBefore: String(localized: "Frühestens ab")
        case .whenQuotaAvailable: String(localized: "Bei verfügbarem Kontingent")
        case .saveOnly: String(localized: "Nur speichern (manuell freigeben)")
        }
    }
}

enum ScheduleBuildError: Error, Hashable, Sendable {
    case invalidTimeZone(String)
    case inPast
    case invalidLocalTime

    var message: String {
        switch self {
        case let .invalidTimeZone(zone): String(localized: "Unbekannte Zeitzone „\(zone)“.")
        case .inPast: String(localized: "Der gewählte Zeitpunkt liegt in der Vergangenheit.")
        case .invalidLocalTime: String(localized: "Datum und Uhrzeit sind ungültig.")
        }
    }
}

/// Baut aus den Eingaben des Dialogs einen ``JobSchedule`` (K1, K3: IANA-Zeitzone, Nachholregel).
struct ScheduleForm: Hashable, Sendable {
    var choice: ScheduleChoice = .immediate
    var date: Date
    var timeZoneIdentifier: String
    var missedRunPolicy: MissedRunPolicy = .ask

    init(choice: ScheduleChoice = .immediate, date: Date, timeZoneIdentifier: String = TimeZone.current.identifier,
         missedRunPolicy: MissedRunPolicy = .ask) {
        self.choice = choice
        self.date = date
        self.timeZoneIdentifier = timeZoneIdentifier
        self.missedRunPolicy = missedRunPolicy
    }

    func makeSchedule(now: Date) throws(ScheduleBuildError) -> JobSchedule {
        switch choice {
        case .immediate:
            return JobSchedule(kind: .immediate, missedRunPolicy: missedRunPolicy)
        case .saveOnly:
            return JobSchedule(kind: .manualPause, missedRunPolicy: missedRunPolicy)
        case .notBefore:
            guard date > now else { throw .inPast }
            return JobSchedule(kind: .notBefore(date), missedRunPolicy: missedRunPolicy)
        case .whenQuotaAvailable:
            guard date > now else { throw .inPast }
            return JobSchedule(kind: .whenQuotaAvailable(expectedReset: date, requestedAt: now), missedRunPolicy: missedRunPolicy)
        case .at:
            let local = try localDateTime()
            guard let planned = try? local.resolve().date else { throw .invalidLocalTime }
            guard planned > now else { throw .inPast }
            return JobSchedule(kind: .at(local), missedRunPolicy: missedRunPolicy)
        }
    }

    /// Wandzeit des gewählten Zeitpunkts in der gewählten Zone (bleibt über Sommerzeitwechsel stabil).
    func localDateTime() throws(ScheduleBuildError) -> ZonedLocalDateTime {
        guard let zone = TimeZone(identifier: timeZoneIdentifier) else { throw .invalidTimeZone(timeZoneIdentifier) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day, let hour = parts.hour,
              let minute = parts.minute else { throw .invalidLocalTime }
        do {
            return try ZonedLocalDateTime(year: year, month: month, day: day, hour: hour, minute: minute,
                                          timeZoneIdentifier: timeZoneIdentifier)
        } catch {
            throw .invalidLocalTime
        }
    }
}

/// Eingaben des Dialogs „Mit Agent umsetzen“ (J2a: Agent → Modell → Stufe, `nil` = Standard übernehmen).
struct JobRequestForm: Hashable, Sendable {
    var providerId: ProviderID?
    var model: ModelSelection?
    var effort: EffortLevel?
    var priority: Priority = .medium
    var schedule: ScheduleForm
    /// Einmal pro geöffnetem Dialog erzeugt (IPC-README: Wiederholung liefert denselben Job).
    let idempotencyKey: IdempotencyKey

    init(providerId: ProviderID?, schedule: ScheduleForm, idempotencyKey: IdempotencyKey = IdempotencyKey()) {
        self.providerId = providerId
        self.schedule = schedule
        self.idempotencyKey = idempotencyKey
    }
}

/// Prüft eine Jobanfrage mit derselben Logik wie das iPhone (AppCore `JobRequestPlanner`) und baut den
/// Dienstbefehl. Unzulässige Kombinationen werden nie gesendet (ADR-0006).
struct JobRequestValidation: Hashable, Sendable {
    var blockers: [String]
    var resolved: ResolvedAgentConfiguration?
    var command: JobRequestCommand?

    static func evaluate(
        form: JobRequestForm, workItem: WorkItem, snapshot: LibrarySnapshot, hostId: HostID?, now: Date
    ) -> JobRequestValidation {
        var messages: [String] = []
        let schedule: JobSchedule?
        do {
            schedule = try form.schedule.makeSchedule(now: now)
        } catch {
            schedule = nil
            messages.append(error.message)
        }
        let entry = snapshot.project(workItem.projectId)
        let context = JobRequestContext(
            workItem: workItem,
            project: entry?.project,
            capabilities: snapshot.capabilities(hostId: hostId),
            hosts: snapshot.hosts,
            globalPreferences: Dictionary(snapshot.globalPreferences.map { ($0.providerId, $0) }, uniquingKeysWith: { first, _ in first }),
            projectPreferences: entry?.settings?.agentModelPreferencesByProvider ?? [:],
            hasActiveJob: snapshot.activeJob(for: workItem.uuid) != nil
        )
        // Zeitplanprüfung oben; der Planner bekommt eine neutrale Option.
        let input = JobRequestInput(providerId: form.providerId, modelOverride: form.model, effortOverride: form.effort,
                                    launchOption: .startNow, priority: form.priority)
        let evaluation = JobRequestPlanner.evaluate(input, context: context, now: now)
        messages += evaluation.blockers.map { blockerText($0) }
        guard messages.isEmpty, let schedule, let provider = form.providerId, evaluation.canSubmit else {
            return JobRequestValidation(blockers: messages, resolved: evaluation.resolution, command: nil)
        }
        let command = JobRequestCommand(
            workItemId: workItem.uuid, providerId: provider, model: form.model, effort: form.effort,
            schedule: schedule, priority: form.priority, idempotencyKey: form.idempotencyKey
        )
        return JobRequestValidation(blockers: [], resolved: evaluation.resolution, command: command)
    }

    static func blockerText(_ blocker: JobRequestBlocker) -> String {
        switch blocker {
        case .noAgentSelected:
            String(localized: "Bitte einen Agenten wählen.")
        case .workItemWithoutProject:
            String(localized: "Die Aufgabe gehört noch zu keinem Projekt. Bitte zuerst einem Projekt zuordnen.")
        case let .agentNotReported(provider):
            String(localized: "\(ProviderNames.displayName(provider)) wurde auf diesem Mac nicht erkannt.")
        case let .agentNotReady(provider):
            String(localized: "\(ProviderNames.displayName(provider)) ist nicht einsatzbereit (Installation oder Anmeldung prüfen).")
        case let .workItemNotStartable(status):
            String(localized: "Aus dem Status „\(status.germanDisplayName)“ kann kein Job gestartet werden.")
        case .activeJobExists:
            String(localized: "Für diese Aufgabe läuft bereits ein Job.")
        case let .configuration(issues):
            issues.map(\.germanDescription).joined(separator: " ")
        case .scheduleInvalid:
            String(localized: "Der Zeitplan ist ungültig.")
        case .scheduleInPast:
            ScheduleBuildError.inPast.message
        }
    }
}

/// Auswahllisten für Modell und Stufe (J2a: nur unterstützte Stufen freischalten).
enum ModelEffortChoices {
    static func models(for capability: AgentCapability?) -> [ModelChoice] {
        guard let capability else { return [] }
        return JobRequestPlanner.modelChoices(for: capability)
    }

    /// Stufen für das tatsächlich wirksame Modell; ohne Adapterunterstützung nur `auto`.
    static func efforts(for capability: AgentCapability?, model: ModelSelection) -> [EffortLevel] {
        guard let capability else { return [.auto] }
        return JobRequestPlanner.effortChoices(for: capability, model: model)
    }

    /// Wirksames Modell, wenn der Auftrag nichts überschreibt (Projekt > Global > Anbieterstandard).
    static func inheritedModel(project: AgentModelPreference?, global: AgentModelPreference?) -> ModelSelection {
        if let project, !project.inheritsDefault, let model = project.model { return model }
        if let global, !global.inheritsDefault, let model = global.model { return model }
        return .providerDefault
    }
}
