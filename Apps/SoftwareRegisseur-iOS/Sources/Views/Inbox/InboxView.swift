import SwiftUI
import SoftwareRegisseurAppCore
import SoftwareRegisseurDomain
import SoftwareRegisseurPersistence

/// „Inbox“ (spec P 3, H1): spontaneous notes without project, captured fast and assigned later.
struct InboxView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var items: [WorkItem] = []
    @State private var text = ""
    @State private var error: String?
    @State private var assigning: WorkItem?
    @FocusState private var focused: Bool

    var body: some View {
        RouteList {
            Section {
                TextField("Neue Notiz …", text: $text, axis: .vertical)
                    .lineLimit(2...8)
                    .focused($focused)
                    .submitLabel(.done)
                    .accessibilityIdentifier("inbox.newNote")
                // Always stacked, full width. Inside a list row `ViewThatFits` chose the side-by-side
                // variant and squeezed both buttons into tall, empty pills (iPad column in the A29 audit,
                // iPhone in the screenshot check, iOS 27).
                stackedCaptureButtons
            } header: {
                Text("Schnell erfassen")
            } footer: {
                Text("Funktioniert auch ohne Internet; die Notiz wird beim nächsten Abgleich übertragen.")
            }
            if let error { ErrorText(message: error) }
            Section {
                if items.isEmpty {
                    ContentUnavailableView("Inbox ist leer", systemImage: "tray",
                                           description: Text("Notizen ohne Projekt landen hier und können später zugewiesen werden."))
                }
                ForEach(items) { item in
                    NavigationLink(value: AppRoute.task(item.uuid)) {
                        WorkItemRow(item: item)
                    }
                    .swipeActions(edge: .trailing) {
                        Button {
                            assigning = item
                        } label: {
                            Label("Zuweisen", systemImage: "folder.badge.plus")
                        }
                        .tint(.blue)
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            Task { await markDone(item) }
                        } label: {
                            Label("Erledigt", systemImage: "checkmark")
                        }
                        .tint(.green)
                    }
                    // Same actions for pointer and keyboard (iPad), where swiping is unusual.
                    .contextMenu {
                        Button {
                            assigning = item
                        } label: {
                            Label("Zuweisen", systemImage: "folder.badge.plus")
                        }
                        Button {
                            Task { await markDone(item) }
                        } label: {
                            Label("Erledigt", systemImage: "checkmark")
                        }
                    }
                }
            } header: {
                Text("Ohne Projekt")
            }
        }
        .navigationTitle("Inbox")
        .sheet(item: $assigning) { AssignProjectView(item: $0) }
        .refreshable { await model.sync(.pullToRefresh) }
        .reloadOnDataChange { await load() }
    }

    private var stackedCaptureButtons: some View {
        VStack(alignment: .leading, spacing: 10) {
            captureButton
            dictateButton
        }
        // Icons take a third of the width at accessibility sizes and clipped „In Inbox ablegen“.
        .titleOnlyLabels(dynamicTypeSize.isAccessibilitySize)
        // System sizing instead of a stretched label frame: the audit reported the stretched labels as clipped.
        .buttonSizing(.flexible)
    }

    private var captureButton: some View {
        Button {
            Task { await capture() }
        } label: {
            Label("In Inbox ablegen", systemImage: "tray.and.arrow.down")
        }
        .buttonStyle(.borderedProminent)
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityIdentifier("inbox.capture")
    }

    private var dictateButton: some View {
        Button {
            model.show(.dictation)
        } label: {
            Label("Diktieren", systemImage: "mic")
        }
        .buttonStyle(.bordered)
        // Label colour on the tinted capsule: blue on light blue failed the contrast audit (A29).
        .foregroundStyle(Color(.label))
    }

    private func load() async {
        guard let database = model.database else { return }
        do {
            items = try await database.workItems.list(WorkItemFilter(project: .withoutProject, statuses: [.inbox, .open]))
            error = nil
        } catch {
            self.error = errorMessage(error)
        }
    }

    private func capture() async {
        guard let database = model.database else { return }
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = WorkItem(type: .note, title: CaptureTitle.make(from: note), originalNote: note, status: .inbox, createdAt: .now)
        do {
            try await database.workItems.insert(item, actor: model.actor, at: .now)
            text = ""
            model.noteLocalChange()
        } catch {
            self.error = errorMessage(error)
        }
    }

    private func markDone(_ item: WorkItem) async {
        guard let database = model.database else { return }
        do {
            _ = try await TaskEditor(workItems: database.workItems).changeStatus(item, to: .done, actor: model.actor, at: .now)
            model.noteLocalChange()
        } catch {
            self.error = errorMessage(error)
        }
    }
}
