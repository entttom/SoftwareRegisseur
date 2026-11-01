import AppKit
import SwiftUI
import SoftwareRegisseurDomain
import SoftwareRegisseurIPC

/// Projekt anlegen oder verknüpfen wie vom iPhone (E2): vorhandener Ordner oder neuer Unterordner eines
/// Stammordners. `git init` nur nach ausdrücklicher Zustimmung; der Dienst prüft Pfade erneut.
struct ProjectSetupSheet: View {
    enum Target: String, CaseIterable, Identifiable {
        case existing, newSubfolder
        var id: Self { self }
    }

    @Environment(CommandCenter.self) private var commands
    @Environment(\.dismiss) private var dismiss
    @State private var target: Target = .existing
    @State private var name = ""
    @State private var folderPath = ""
    @State private var parentPath = ""
    @State private var folderName = ""
    @State private var scope: RepositoryScopeChoice?
    @State private var initializeGit = false
    @State private var gitConsent = false
    @State private var isSubmitting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Projekt anlegen oder verknüpfen").font(.title2.bold())
            Picker("Ziel", selection: $target) {
                Text("Vorhandener Ordner").tag(Target.existing)
                Text("Neuer Unterordner").tag(Target.newSubfolder)
            }
            .pickerStyle(.segmented)
            Form {
                TextField("Projektname", text: $name)
                switch target {
                case .existing:
                    HStack {
                        TextField("Ordner", text: $folderPath)
                        Button("Wählen …") { if let path = choose() { folderPath = path; if name.isEmpty { name = URL(filePath: path).lastPathComponent } } }
                    }
                    Picker("Bei Unterordner eines Repositorys", selection: $scope) {
                        Text("Nicht zutreffend").tag(RepositoryScopeChoice?.none)
                        Text("Ganzes Repository").tag(RepositoryScopeChoice?.some(.wholeRepository))
                        Text("Nur diesen Unterordner").tag(RepositoryScopeChoice?.some(.subfolderOnly))
                    }
                case .newSubfolder:
                    HStack {
                        TextField("Übergeordneter Ordner", text: $parentPath)
                        Button("Wählen …") { if let path = choose() { parentPath = path } }
                    }
                    TextField("Name des neuen Ordners", text: $folderName)
                }
                Toggle("Git-Repository anlegen (git init)", isOn: $initializeGit)
                if initializeGit {
                    Toggle("Ich stimme zu, dass im Ordner „git init“ ausgeführt wird.", isOn: $gitConsent)
                }
            }
            .formStyle(.grouped)
            if let error {
                Text(error).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    submit()
                } label: {
                    if isSubmitting { ProgressView().controlSize(.small) } else { Text("Projekt einrichten") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit || isSubmitting)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var canSubmit: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if initializeGit && !gitConsent { return false }
        switch target {
        case .existing: return !folderPath.isEmpty
        case .newSubfolder: return !parentPath.isEmpty && !folderName.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func choose() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path(percentEncoded: false)
    }

    private func submit() {
        let setupTarget: ProjectSetupTarget = switch target {
        case .existing: .indexedFolder(path: folderPath)
        case .newSubfolder: .newSubfolder(parentPath: parentPath, folderName: folderName.trimmingCharacters(in: .whitespaces))
        }
        let command = ProjectSetupCommand(
            kind: .createProject, projectName: name.trimmingCharacters(in: .whitespaces), target: setupTarget,
            repositoryScope: target == .existing ? scope : nil, initializeGitRepository: initializeGit,
            gitInitConsent: initializeGit && gitConsent ? GitInitConsent(grantedBy: nil, grantedAt: .now) : nil,
            createdAt: .now
        )
        do {
            try command.validateStructure()
        } catch {
            self.error = error.message
            return
        }
        isSubmitting = true
        Task {
            let outcome = await commands.perform(String(localized: "Projekt einrichten"), .submitProjectSetup(command))
            isSubmitting = false
            if outcome.succeeded { dismiss() } else { error = outcome.feedback.message }
        }
    }
}
