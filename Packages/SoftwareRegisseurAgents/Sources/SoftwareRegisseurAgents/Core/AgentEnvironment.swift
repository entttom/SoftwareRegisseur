import Darwin
import Foundation
import SoftwareRegisseurProcess

/// Builds the explicit child environment for agent processes (ADR-0021, spike claude-code §2.1,
/// spec L3/Q1). Starts from `ProcessEnvironment.minimal` – nothing is inherited – and additionally
/// filters caller-supplied passthrough variables against a deny list, so an override such as
/// `CLAUDE_CODE_EFFORT_LEVEL` or `ANTHROPIC_BASE_URL` can never reach the agent.
public enum AgentEnvironment {
    /// Prefixes that are never passed to any agent: provider overrides that change model/effort,
    /// endpoints, credentials or telemetry gates (spike claude-code §0.3, §2.1; spike codex §5) and
    /// Git variables that would redirect the agent to another repository (spec L3).
    public static let forbiddenPrefixes: [String] = [
        "ANTHROPIC_", "CLAUDE_", "CLAUDECODE", "OPENAI_", "CODEX_", "DISABLE_", "GIT_",
    ]
    public static let forbiddenNames: Set<String> = [
        "DO_NOT_TRACK", "CLAUDE_EFFORT", "CLAUDE_CODE_EFFORT_LEVEL", "ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY",
        "ANTHROPIC_MODEL", "CLAUDE_CODE_SIMPLE", "CLAUDE_CODE_OAUTH_TOKEN", "OPENAI_API_KEY", "CODEX_API_KEY",
        "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "NODE_OPTIONS",
    ]

    public static func isForbidden(_ name: String) -> Bool {
        forbiddenNames.contains(name) || name.hasPrefix("DYLD_")
            || forbiddenPrefixes.contains { name.hasPrefix($0) }
    }

    /// - Parameters:
    ///   - pathDirectories: ordered `PATH` entries (deduplicated; system dirs are appended).
    ///   - passthrough: optional extra variables (e.g. `LANG`); forbidden names are dropped.
    public static func make(pathDirectories: [URL], passthrough: [String: String] = [:]) -> ProcessEnvironment {
        var seen = Set<String>()
        var entries: [String] = []
        let system = ProcessEnvironment.safeSystemPath.split(separator: ":").map(String.init)
        for path in pathDirectories.map({ Self.directoryPath($0) }) + system
        where !path.isEmpty && !path.contains(":") && seen.insert(path).inserted {
            entries.append(path)
        }
        var environment = ProcessEnvironment.minimal(path: entries.joined(separator: ":"))
        environment["LANG"] = "en_US.UTF-8"
        if let shell = userShell() { environment["SHELL"] = shell }
        for (name, value) in passthrough where !isForbidden(name) && name != "PATH" {
            environment[name] = value
        }
        return environment
    }

    /// Absolute directory path without trailing slash.
    static func directoryPath(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static func userShell() -> String? {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
        let value = String(cString: shell)
        return value.isEmpty ? nil : value
    }
}
