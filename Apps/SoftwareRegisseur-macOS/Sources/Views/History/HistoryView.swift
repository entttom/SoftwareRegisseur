import SwiftUI
import SoftwareRegisseurDomain

/// Zeitleiste aller Ereignisse der letzten 30 Tage (M2: Nachvollziehbarkeit).
struct HistoryView: View {
    @Environment(LibraryStore.self) private var library
    @State private var kind: TaskEventKind?
    @State private var project: TaskQuery.ProjectScope = .any
    @State private var search = ""

    var body: some View {
        LibraryGate {
            VStack(spacing: 0) {
                HStack {
                    Picker("Ereignis", selection: $kind) {
                        Text("Alle Ereignisse").tag(TaskEventKind?.none)
                        ForEach(TaskEventKind.allCases, id: \.self) { Text($0.displayName).tag(TaskEventKind?.some($0)) }
                    }
                    .frame(maxWidth: 260)
                    ProjectScopePicker(scope: $project).frame(maxWidth: 260)
                    TextField("Suchen", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                    Spacer()
                }
                .padding(10)
                Divider()
                let groups = grouped
                if groups.isEmpty {
                    ContentUnavailableView("Keine Ereignisse", systemImage: "clock.arrow.circlepath",
                                           description: Text("In den letzten 30 Tagen gibt es keine passenden Ereignisse."))
                } else {
                    List {
                        ForEach(groups, id: \.day) { group in
                            Section {
                                ForEach(group.events) { EventRow(event: $0, showTask: true) }
                            } header: {
                                Text(group.day.formatted(date: .complete, time: .omitted))
                            }
                        }
                    }
                }
            }
        }
    }

    private var grouped: [(day: Date, events: [TaskEvent])] {
        let snapshot = library.snapshot
        let needle = search.trimmingCharacters(in: .whitespaces)
        let filtered = snapshot.recentEvents.filter { event in
            if let kind, event.kind != kind { return false }
            let item = snapshot.workItem(event.workItemId)
            switch project {
            case .any: break
            case .inbox: if item?.projectId != nil { return false }
            case let .project(id): if item?.projectId != id { return false }
            }
            if !needle.isEmpty {
                let text = [item?.displayTitle ?? "", event.kind.displayName] + event.payload.values
                return text.contains { $0.localizedStandardContains(needle) }
            }
            return true
        }
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.timestamp) }
        return byDay.keys.sorted(by: >).map { day in
            (day, byDay[day]!.sorted { $0.timestamp > $1.timestamp })
        }
    }
}

struct EventRow: View {
    @Environment(LibraryStore.self) private var library
    @Environment(NavigationModel.self) private var navigation
    let event: TaskEvent
    let showTask: Bool

    var body: some View {
        let item = library.snapshot.workItem(event.workItemId)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.kind.symbolName)
                .frame(width: 20)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(event.kind.displayName).font(.headline)
                    Text(event.timestamp.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary)
                    Spacer()
                    Text(event.actor.displayName).font(.caption).foregroundStyle(.secondary)
                }
                if showTask, let item {
                    Button(item.displayTitle) { navigation.showWorkItem(item) }
                        .buttonStyle(.link)
                }
                if !event.payload.isEmpty {
                    Text(verbatim: EventPayloadText.summary(kind: event.kind, payload: event.payload))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
