import Foundation
import SoftwareRegisseurProcess

/// Shared, side-effect-free detection helpers (spec J1: no commands with side effects just to detect).
enum AgentDetectionSupport {
    struct Located: Sendable {
        let candidate: ExecutableCandidate
        /// Interpreter named in a `#!` line of the resolved file, e.g. `node` for the npm shim.
        let scriptInterpreter: String?
    }

    /// Finds `name` via the configured override or `ExecutableLocator` (LaunchAgent-safe search dirs).
    static func locate(name: String, override: URL?, locator: ExecutableLocator) -> (Located?, [AgentDiagnostic]) {
        var diagnostics: [AgentDiagnostic] = []
        let candidate: ExecutableCandidate?
        if let override {
            let inspected = ExecutableLocator.inspect(override)
            if inspected.isUsable {
                candidate = inspected
            } else {
                diagnostics.append(AgentDiagnostic(
                    code: "executable.overrideUnusable", severity: .warning,
                    message: String(localized: "Konfigurierter Pfad \(override.path(percentEncoded: false)) ist nicht ausführbar (\(inspected.status.rawValue)).", bundle: .module)
                ))
                candidate = (try? locator.locate(name))?.preferred
            }
        } else {
            let lookup = try? locator.locate(name)
            candidate = lookup?.preferred
            if candidate == nil, let broken = lookup?.candidates.first {
                diagnostics.append(AgentDiagnostic(
                    code: "executable.unusable", severity: .warning,
                    message: "\(broken.url.path(percentEncoded: false)) gefunden, aber nicht nutzbar (\(broken.status.rawValue))."
                ))
            }
        }
        guard let candidate else { return (nil, diagnostics) }
        return (Located(candidate: candidate, scriptInterpreter: scriptInterpreter(of: candidate.resolvedURL ?? candidate.url)), diagnostics)
    }

    /// Reads at most the first 256 bytes of the executable to detect a `#!` interpreter.
    static func scriptInterpreter(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256), data.starts(with: Array("#!".utf8)) else { return nil }
        let line = String(decoding: data.prefix { $0 != UInt8(ascii: "\n") }.dropFirst(2), as: UTF8.self)
        let parts = line.split(separator: " ").map(String.init)
        guard let first = parts.first else { return nil }
        if first.hasSuffix("/env") {
            return parts.dropFirst().first { !$0.hasPrefix("-") }
        }
        return URL(filePath: first).lastPathComponent
    }

    /// Runs a short, side-effect-free command (`--version`, `login status`, `auth status`).
    static func run(_ toolchain: AgentToolchain, _ arguments: [String], timeout: Duration,
                    workingDirectory: URL? = nil) async -> ProcessResult? {
        let request = ProcessRequest(
            executableURL: toolchain.executableURL,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: toolchain.environment,
            timeout: timeout,
            terminationGracePeriod: .seconds(1),
            outputLimit: 1024 * 1024
        )
        return try? await ProcessRunner().run(request)
    }

    static func redactedTail(_ text: String, maxLength: Int = 600) -> String {
        let redacted = SecretRedactor.standard.redact(text.trimmingCharacters(in: .whitespacesAndNewlines))
        return redacted.count > maxLength ? "…" + String(redacted.suffix(maxLength)) : redacted
    }
}

/// Keeps a bounded tail of redacted stderr lines for failure reports.
struct BoundedLineBuffer: Sendable {
    let capacity: Int
    private(set) var lines: [String] = []

    init(capacity: Int = 40) { self.capacity = capacity }

    mutating func append(_ line: String) {
        lines.append(SecretRedactor.standard.redact(line))
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
    }

    var text: String { AgentDetectionSupport.redactedTail(lines.joined(separator: "\n")) }
}

func truncated(_ text: String, to length: Int = 240) -> String {
    let singleLine = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    return singleLine.count > length ? String(singleLine.prefix(length - 1)) + "…" : singleLine
}

/// `realpath`-based canonical path; `URL.resolvingSymlinksInPath` strips `/private` on macOS.
func canonicalPath(_ url: URL) -> String {
    let path = url.standardizedFileURL.path(percentEncoded: false)
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

func canonicalPath(_ path: String) -> String { canonicalPath(URL(filePath: path)) }
