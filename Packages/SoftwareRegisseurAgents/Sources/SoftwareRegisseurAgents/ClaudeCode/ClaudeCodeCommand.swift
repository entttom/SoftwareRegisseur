import Foundation
import SoftwareRegisseurDomain

/// Argument vectors for the `claude` CLI, exactly as decided in ADR-0021 (spike claude-code §2.2, §2.3).
public enum ClaudeCodeCommand {
    /// Tools blocked for every job: no `git push` (spec L2/L3), no agent-managed worktrees (spike §2.6).
    public static let disallowedTools = ["Bash(git push *)", "Bash(git push)", "EnterWorktree"]

    /// Arguments that must never appear: own worktrees, background mode (auto commit+push), bypass
    /// modes, remote control (ADR-0010 still proposed), TTY multiplexing.
    public static let forbiddenArguments: Set<String> = [
        "-w", "--worktree", "--bg", "--background", "--tmux",
        "--dangerously-skip-permissions", "--allow-dangerously-skip-permissions",
        "bypassPermissions", "--permission-prompts",
        "--remote-control", "--rc", "remote-control", "rc",
    ]

    /// Isolation from repository-controlled configuration (SR-SEC-03): only the user's own settings
    /// (`~/.claude/settings.json`) are loaded – never `.claude/settings*.json` of the worktree, whose
    /// hooks would run without approval and whose `permissions.allow` would pre-approve tools – and no
    /// MCP server is started except ones passed with `--mcp-config` (none). Both flags are listed by
    /// `claude --help` of the verified version 2.1.308; detection requires them (`isolationFlags`).
    public static let isolationArguments = ["--setting-sources", "user", "--strict-mcp-config"]

    /// Flags that `claude --help` must list before jobs may start (checked during detection).
    public static let isolationFlags = ["--setting-sources", "--strict-mcp-config"]

    /// Repository files that a plain `claude` would load from the worktree; reported as a diagnostic
    /// before the start (they are not loaded thanks to `isolationArguments`).
    public static let repositoryConfigurationFiles = [".claude/settings.json", ".claude/settings.local.json", ".mcp.json", ".claude/hooks"]

    /// Headless job (ADR-0021): stream-json in/out, explicit session id, explicit model/effort when
    /// set, user settings only and no MCP servers (SR-SEC-03), manual permission mode with approvals
    /// over the stdio control channel.
    public static func sessionArguments(sessionId: UUID, model: ModelID?, effort: EffortLevel?) -> [String] {
        var arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--session-id", sessionId.uuidString.lowercased(),
        ]
        if let model { arguments += ["--model", model.rawValue] }
        if let effort, !effort.isAuto { arguments += ["--effort", effort.rawValue] }
        arguments += isolationArguments
        arguments += [
            "--permission-mode", "manual",
            "--permission-prompt-tool", "stdio",
            // Variadic option: keep it last.
            "--disallowedTools",
        ] + disallowedTools
        return arguments
    }

    /// Catalog handshake without a prompt (spike §2.2): no model call, no session file.
    public static func catalogArguments() -> [String] {
        ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--no-session-persistence"]
    }

    public static func versionArguments() -> [String] { ["--version"] }
    public static func helpArguments() -> [String] { ["--help"] }

    /// Isolation flags missing from `claude --help` output (empty = the installed version supports them).
    public static func missingIsolationFlags(inHelp output: String) -> [String] {
        isolationFlags.filter { flag in
            !output.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "," || $0 == "\t" }).contains { $0 == flag }
        }
    }
    public static func authStatusArguments() -> [String] { ["auth", "status", "--json"] }

    /// Returns every forbidden token in `arguments` (empty = safe). Values of `--disallowedTools`
    /// and `--model`/`--effort` are data, not flags, and are not checked.
    public static func violations(in arguments: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        var inDisallowed = false
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("-") { inDisallowed = argument == "--disallowedTools" }
            if inDisallowed && !argument.hasPrefix("-") { index += 1; continue }
            if ["--model", "--effort", "--session-id"].contains(argument) { index += 2; continue }
            if argument == "--setting-sources" {
                // SR-SEC-03: project/local settings of the worktree must never be loaded.
                let sources = index + 1 < arguments.count ? arguments[index + 1] : ""
                if sources != "user" { result.append("--setting-sources \(sources)") }
                index += 2
                continue
            }
            if argument == "--permission-mode" {
                let mode = index + 1 < arguments.count ? arguments[index + 1] : ""
                if mode != "manual" && mode != "default" { result.append("--permission-mode \(mode)") }
                index += 2
                continue
            }
            if forbiddenArguments.contains(argument) || argument.hasPrefix("--worktree=") || argument.hasPrefix("--setting-sources=") {
                result.append(argument)
            }
            index += 1
        }
        // SR-SEC-03: a job session without isolation from the repository configuration is unsafe.
        if arguments.contains("-p"), arguments.contains("--session-id") {
            if !arguments.contains("--setting-sources") { result.append("missing --setting-sources user") }
            if !arguments.contains("--strict-mcp-config") { result.append("missing --strict-mcp-config") }
        }
        return result
    }

    static func parseVersion(_ output: String) -> SemanticVersion? {
        // `2.1.212 (Claude Code)`
        SemanticVersion.firstMatch(in: output)
    }
}

/// Lines written to Claude's stdin (stream-json input + SDK control protocol).
enum ClaudeCodeInput {
    static func userMessage(_ text: String, sessionId: UUID) -> JSONValue {
        [
            "type": "user",
            "message": ["role": "user", "content": .string(text)],
            "parent_tool_use_id": nil,
            "session_id": .string(sessionId.uuidString.lowercased()),
        ]
    }

    static func controlRequest(id: String, subtype: String) -> JSONValue {
        ["type": "control_request", "request_id": .string(id), "request": ["subtype": .string(subtype)]]
    }

    static func controlSuccess(id: String, response: JSONValue) -> JSONValue {
        ["type": "control_response", "response": ["subtype": "success", "request_id": .string(id), "response": response]]
    }

    static func controlError(id: String, message: String) -> JSONValue {
        ["type": "control_response", "response": ["subtype": "error", "request_id": .string(id), "error": .string(message)]]
    }

    /// `can_use_tool` answer (SDK `PermissionResult`): allow echoes the original input unchanged.
    static func permissionResponse(id: String, decision: AgentApprovalDecision, originalInput: JSONValue) throws -> JSONValue {
        switch decision {
        case .allow:
            return controlSuccess(id: id, response: ["behavior": "allow", "updatedInput": originalInput])
        case let .deny(message):
            return controlSuccess(id: id, response: [
                "behavior": "deny", "message": .string(message ?? "Vom Benutzer in Software Regisseur abgelehnt."),
            ])
        case .cancel:
            return controlSuccess(id: id, response: [
                "behavior": "deny", "message": "Vom Benutzer abgebrochen.", "interrupt": true,
            ])
        case .allowForSession:
            throw AgentSessionError.decisionNotSupported(decision)
        }
    }
}
