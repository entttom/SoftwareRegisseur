import Foundation
import SoftwareRegisseurGit

/// Liest Diffs selbst per `git` im Repository (IPC-README: „Diff-Inhalte liest die UI selbst“).
/// Explizite Argumente, keine Shell und keine String-Interpolation in Kommandos (L3); gehärtet wie der Dienst.
enum GitDiffLoader {
    static let maximumBytes = 4 * 1024 * 1024

    enum Failure: Error, Equatable {
        case invalidReference
        case gitFailed(String)
        case tooLarge

        var message: String {
            switch self {
            case .invalidReference: String(localized: "Ungültige Commit-Angabe.")
            case let .gitFailed(detail): String(localized: "git diff fehlgeschlagen: \(detail)")
            case .tooLarge: String(localized: "Der Diff ist zu groß für die Anzeige. Bitte im Terminal oder Editor ansehen.")
            }
        }
    }

    /// Argumente für `git diff` einer Datei zwischen Basis und Kopf (ohne `-C`; das Verzeichnis setzt `GitClient`).
    /// Referenzen dürfen nicht mit „-“ beginnen. Externe Diff-Programme und Textconv-Filter sind immer aus.
    static func arguments(base: String?, defaultBranch: String, head: String, path: String?) throws(Failure) -> [String] {
        for reference in [base, defaultBranch, head].compactMap({ $0 }) {
            guard !reference.isEmpty, !reference.hasPrefix("-"), !reference.contains(".."),
                  reference.allSatisfy({ !$0.isWhitespace }) else { throw .invalidReference }
        }
        let range = base.map { "\($0)..\(head)" } ?? "\(defaultBranch)...\(head)"
        var arguments = ["diff", "--no-color", "--no-ext-diff", "--no-textconv", range]
        if let path {
            arguments += ["--", path]
        }
        return arguments
    }

    /// Lädt den Diff über den gehärteten `GitClient` (SR-SEC-10/13): `git` über `ExecutableLocator` statt fest
    /// `/usr/bin/git`, minimale Umgebung, `core.hooksPath=/dev/null`, `core.fsmonitor=false`, `protocol.ext.allow=never`,
    /// Filter-/Merge-Treiber aus der Repository-Konfiguration neutralisiert, stdout und stderr gleichzeitig gelesen.
    static func diff(repository: String, base: String?, defaultBranch: String, head: String, path: String?,
                     git: GitClient? = nil) async -> Result<String, Failure> {
        let arguments: [String]
        do {
            arguments = try Self.arguments(base: base, defaultBranch: defaultBranch, head: head, path: path)
        } catch {
            return .failure(error)
        }
        let client: GitClient
        do {
            client = try git ?? GitClient.locate()
        } catch {
            return .failure(.gitFailed(String(localized: "git wurde auf diesem Mac nicht gefunden.")))
        }
        do {
            let result = try await client.run(arguments, in: URL(filePath: repository, directoryHint: .isDirectory))
            guard result.standardOutputData.count <= maximumBytes else { return .failure(.tooLarge) }
            return .success(result.standardOutput)
        } catch let error as GitError {
            return .failure(.gitFailed(String(error.description.prefix(400))))
        } catch {
            return .failure(.gitFailed(String(error.localizedDescription.prefix(400))))
        }
    }
}
