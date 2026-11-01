import Foundation

/// Fake agent executables speaking the real wire formats over stdio. Shapes are taken from the
/// spike reports and the Codex schema generated for codex-cli 0.164.0.
enum FakeAgents {
    static func codex(scenario: String, directory: URL) -> String {
        codexTemplate
            .replacingOccurrences(of: "__SCENARIO__", with: scenario)
            .replacingOccurrences(of: "__DIR__", with: directory.path(percentEncoded: false))
    }

    static func claude(scenario: String, directory: URL) -> String {
        claudeTemplate
            .replacingOccurrences(of: "__SCENARIO__", with: scenario)
            .replacingOccurrences(of: "__DIR__", with: directory.path(percentEncoded: false))
    }

    /// Stand-in for the npm `codex.js` shim: needs `node` from PATH.
    static let nodeShim = "#!/usr/bin/env node\n// fake npm shim\n"

    /// Fake `node` that runs the fake Codex logic for any `*.js` argument.
    static func fakeNode(codexScript: URL) -> String {
        "#!/bin/sh\nshift\nexec \"\(codexScript.path(percentEncoded: false))\" \"$@\"\n"
    }

    private static let codexTemplate = #"""
    #!/usr/bin/python3 -I
    import json, os, sys
    SCENARIO = "__SCENARIO__"
    DIR = "__DIR__"
    args = sys.argv[1:]

    def log(obj):
        with open(os.path.join(DIR, "received.jsonl"), "a") as f:
            f.write(json.dumps(obj) + "\n")

    log({"argv": args, "env": sorted(os.environ.keys())})
    if args == ["--version"]:
        print("codex-cli 0.164.0")
        sys.exit(0)
    if args[:2] == ["login", "status"]:
        if SCENARIO == "loggedout":
            print("Not logged in")
            sys.exit(1)
        print("Logged in using ChatGPT")
        sys.exit(0)
    if args != ["app-server", "--listen", "stdio://", "--disable", "hooks"]:
        sys.stderr.write("unexpected arguments\n")
        sys.exit(64)

    def send(obj):
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()

    def read():
        line = sys.stdin.readline()
        if not line:
            sys.exit(0)
        with open(os.path.join(DIR, "raw.jsonl"), "a") as f:
            f.write(line)
        msg = json.loads(line)
        log(msg)
        if "jsonrpc" in msg:
            sys.stderr.write("unexpected jsonrpc member\n")
            sys.exit(65)
        if "rateLimitResetCredit" in str(msg.get("method")):
            sys.exit(66)
        return msg

    def effort(level, text):
        return {"reasoningEffort": level, "description": text}

    PAGE1 = [{
        "id": "gpt-6.1-sol", "model": "gpt-6.1-sol", "upgrade": None, "upgradeInfo": None, "availabilityNux": None,
        "displayName": "GPT-6.1-Sol", "description": "Latest workhorse model", "modelSpecialty": None, "hidden": False,
        "supportedReasoningEfforts": [effort("low", "Fast"), effort("medium", "Balanced"), effort("high", "Deep"),
                                      effort("xhigh", "Extra"), effort("max", "Max"), effort("ultra", "Delegation")],
        "defaultReasoningEffort": "low", "inputModalities": ["text", "image"], "supportsPersonality": False,
        "multiAgentVersion": "v2", "additionalSpeedTiers": [], "serviceTiers": [], "defaultServiceTier": None,
        "availableAccessPrograms": None, "isDefault": True}]
    PAGE2 = [{
        "id": "gpt-6-luna", "model": "gpt-6-luna", "upgrade": None, "upgradeInfo": None, "availabilityNux": None,
        "displayName": "GPT-6-Luna", "description": "Smaller", "modelSpecialty": None, "hidden": False,
        "supportedReasoningEfforts": [effort("low", "Fast"), effort("medium", "Balanced"), effort("high", "Deep"),
                                      effort("xhigh", "Extra"), effort("max", "Max")],
        "defaultReasoningEffort": "medium", "inputModalities": ["text"], "supportsPersonality": False,
        "multiAgentVersion": None, "additionalSpeedTiers": [], "serviceTiers": [], "defaultServiceTier": None,
        "availableAccessPrograms": None, "isDefault": False}]

    THREAD = "019a0000-0000-7000-8000-000000000001"
    TURN = "019a0000-0000-7000-8000-000000000002"
    initialized = False

    def turn(status, error=None):
        return {"id": TURN, "rootTurnId": None, "items": [], "itemsView": "full", "status": status, "error": error,
                "startedAt": 1793000000, "completedAt": None, "durationMs": None}

    while True:
        msg = read()
        method = msg.get("method")
        mid = msg.get("id")
        if method == "initialize":
            send({"id": mid, "result": {"userAgent": "software_regisseur/0.164.0 (Mac OS 27.0.0; arm64)",
                                        "codexHome": "/tmp/codex-home", "platformFamily": "unix", "platformOs": "macos"}})
            continue
        if method == "initialized":
            initialized = True
            continue
        if not initialized and mid is not None and method is not None:
            send({"id": mid, "error": {"code": -32600, "message": "Not initialized"}})
            continue
        if method == "model/list":
            if SCENARIO == "badcatalog":
                send({"id": mid, "result": {"nothing": True}})
            elif (msg.get("params") or {}).get("cursor") is None:
                send({"id": mid, "result": {"data": PAGE1, "nextCursor": "page-2"}})
            else:
                send({"id": mid, "result": {"data": PAGE2, "nextCursor": None}})
        elif method == "thread/start":
            p = msg["params"]
            if p.get("sandbox") != "workspace-write" or p.get("approvalPolicy") != "on-request":
                send({"id": mid, "error": {"code": -32600, "message": "unsafe start parameters"}})
                continue
            model = "gpt-rerouted" if SCENARIO == "mismatch" else p.get("model")
            send({"id": mid, "result": {
                "thread": {"id": THREAD, "sessionId": "019a0000-0000-7000-8000-0000000000ss", "forkedFromId": None,
                           "parentThreadId": None, "preview": "", "ephemeral": False, "modelProvider": "openai",
                           "model": model, "reasoningEffort": (p.get("config") or {}).get("model_reasoning_effort"),
                           "createdAt": 1793000000, "updatedAt": 1793000000, "status": {"type": "idle"}, "path": None,
                           "cwd": p["cwd"], "cliVersion": "0.164.0", "source": "vscode", "gitInfo": None, "name": None,
                           "turns": []},
                "model": model, "modelProvider": "openai", "serviceTier": None, "disabledPluginIds": [],
                "cwd": p["cwd"], "instructionSources": [], "approvalPolicy": p["approvalPolicy"],
                "approvalsReviewer": "user",
                "sandbox": {"type": "workspaceWrite", "writableRoots": [], "networkAccess": False},
                "reasoningEffort": (p.get("config") or {}).get("model_reasoning_effort")}})
        elif method == "turn/start":
            send({"id": mid, "result": {"turn": turn("inProgress")}})
            send({"method": "turn/started", "params": {"threadId": THREAD, "turn": turn("inProgress")}})
            if SCENARIO == "quota":
                err = {"message": "You've hit your usage limit.", "codexErrorInfo": "usageLimitExceeded",
                       "additionalDetails": None, "misalignment": None}
                send({"method": "error", "params": {"error": err, "willRetry": False, "threadId": THREAD, "turnId": TURN}})
                send({"method": "turn/completed", "params": {"threadId": THREAD, "turn": turn("failed", err)}})
                continue
            if SCENARIO == "hang":
                continue
            send({"method": "item/started", "params": {"threadId": THREAD, "turnId": TURN, "startedAtMs": 1,
                  "item": {"type": "commandExecution", "id": "item-1", "command": "swift test", "cwd": "/w",
                           "status": "inProgress", "commandActions": [], "aggregatedOutput": None,
                           "exitCode": None, "durationMs": None, "processId": None, "source": "agent",
                           "pluginId": None, "scriptPath": None}}})
            send({"id": 0, "method": "item/commandExecution/requestApproval", "params": {
                "kind": "command", "threadId": THREAD, "turnId": TURN, "itemId": "item-1", "startedAtMs": 1,
                "environmentId": None, "reason": "needs network", "command": "swift test", "cwd": "/w"}})
            if SCENARIO == "crash":
                sys.stderr.write("thread 'main' panicked: simulated crash token=sk-abcdefghijklmnopqrstuvwx\n")
                sys.stderr.flush()
                os._exit(3)
        elif mid == 0 and "result" in msg:
            decision = msg["result"].get("decision")
            send({"method": "serverRequest/resolved", "params": {"threadId": THREAD, "requestId": 0}})
            status = "completed" if decision in ("accept", "acceptForSession") else "declined"
            send({"method": "item/completed", "params": {"threadId": THREAD, "turnId": TURN, "completedAtMs": 2,
                  "item": {"type": "commandExecution", "id": "item-1", "command": "swift test", "cwd": "/w",
                           "status": status, "commandActions": [], "aggregatedOutput": "ok", "exitCode": 0,
                           "durationMs": 5, "processId": None, "source": "agent", "pluginId": None, "scriptPath": None}}})
            send({"method": "item/agentMessage/delta", "params": {"threadId": THREAD, "turnId": TURN, "itemId": "m1", "delta": "Fertig"}})
            send({"method": "item/completed", "params": {"threadId": THREAD, "turnId": TURN, "completedAtMs": 3,
                  "item": {"type": "agentMessage", "id": "m1", "text": "Fertig: decision=" + str(decision),
                           "phase": None, "memoryCitation": None, "delivery": None, "questions": None}}})
            send({"method": "turn/completed", "params": {"threadId": THREAD, "turn": turn("completed")}})
        elif method == "turn/interrupt":
            send({"id": mid, "result": {}})
            send({"method": "turn/completed", "params": {"threadId": THREAD, "turn": turn("interrupted")}})
        elif method == "account/rateLimits/read":
            send({"id": mid, "result": {"ordinaryUsageAllowed": False, "rateLimits": {
                "limitId": "codex", "limitName": None, "normalModelSlug": None,
                "primary": {"usedPercent": 100, "windowDurationMins": 300, "resetsAt": 1793363552},
                "secondary": {"usedPercent": 73, "windowDurationMins": 10080, "resetsAt": 1793798493},
                "credits": None, "individualLimit": None, "spendControlReached": False, "planType": "plus",
                "rateLimitReachedType": None}, "rateLimitsByLimitId": None, "rateLimitResetCredits": None,
                "accountId": None, "rateLimitUpsell": None}})
        elif mid is not None and method is not None:
            send({"id": mid, "error": {"code": -32601, "message": "method not found"}})
    """#

    private static let claudeTemplate = #"""
    #!/usr/bin/python3 -I
    import json, os, sys
    SCENARIO = "__SCENARIO__"
    DIR = "__DIR__"
    args = sys.argv[1:]

    def log(obj):
        with open(os.path.join(DIR, "received.jsonl"), "a") as f:
            f.write(json.dumps(obj) + "\n")

    log({"argv": args, "env": sorted(os.environ.keys())})
    if args == ["--version"]:
        print("2.1.212 (Claude Code)")
        sys.exit(0)
    if args == ["--help"]:
        if SCENARIO == "noisolation":
            print("Usage: claude [options]\n  --settings <file-or-json>  Settings")
        else:
            print("Usage: claude [options]\n  --setting-sources <sources>  Comma-separated list\n  --strict-mcp-config  Only use MCP servers from --mcp-config")
        sys.exit(0)
    if "-p" in args and "--input-format" in args and "--session-id" in args:
        if args[args.index("--setting-sources") + 1] != "user" or "--strict-mcp-config" not in args:
            sys.stderr.write("missing isolation flags\n")
            sys.exit(72)
    if args[:2] == ["auth", "status"]:
        if SCENARIO == "expired":
            print(json.dumps({"loggedIn": False, "authMethod": "none", "apiProvider": "firstParty"}))
            sys.exit(1)
        print(json.dumps({"loggedIn": True, "authMethod": "claude.ai", "apiProvider": "firstParty"}))
        sys.exit(0)
    FORBIDDEN = {"-w", "--worktree", "--bg", "--dangerously-skip-permissions", "bypassPermissions", "--remote-control", "--rc"}
    if any(a in FORBIDDEN for a in args):
        sys.stderr.write("forbidden flag\n")
        sys.exit(70)
    for name in os.environ:
        if name.startswith("ANTHROPIC_") or name.startswith("CLAUDE_"):
            sys.stderr.write("leaked environment variable " + name + "\n")
            sys.exit(71)

    def send(obj):
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()

    def read():
        line = sys.stdin.readline()
        if not line:
            sys.exit(0)
        msg = json.loads(line)
        log(msg)
        return msg

    def drain():
        while True:
            line = sys.stdin.readline()
            if not line:
                sys.exit(0)
            log(json.loads(line))

    MODELS = [
        {"value": "default", "resolvedModel": "claude-opus-4-8[1m]", "displayName": "Default", "description": "Recommended",
         "supportsEffort": True, "supportedEffortLevels": ["low", "medium", "high", "xhigh", "max"]},
        {"value": "sonnet", "resolvedModel": "claude-sonnet-5", "displayName": "Sonnet", "description": "Everyday",
         "supportsEffort": True, "supportedEffortLevels": ["low", "medium", "high", "xhigh", "max"]},
        {"value": "haiku", "resolvedModel": "claude-haiku-4-5-20251001", "displayName": "Haiku", "description": "Fast"}]

    if "--no-session-persistence" in args:
        if SCENARIO == "catalogfail":
            sys.stderr.write("initialize not supported\n")
            sys.exit(1)
        m = read()
        if m.get("type") != "control_request" or m["request"].get("subtype") != "initialize":
            sys.exit(72)
        send({"type": "system", "subtype": "hook_started", "hook_name": "SessionStart"})
        send({"type": "control_response", "response": {"subtype": "success", "request_id": m["request_id"], "response": {
            "commands": [], "agents": [], "models": MODELS, "account": {"tokenSource": "none"}, "output_style": "default",
            "available_output_styles": [], "pid": os.getpid(), "remote_control_auto_enable": False}}})
        drain()

    sid = args[args.index("--session-id") + 1]
    model = args[args.index("--model") + 1] if "--model" in args else "default"
    resolved = {m["value"]: m["resolvedModel"] for m in MODELS}.get(model, model)
    if SCENARIO == "wrongsession":
        sid = "00000000-0000-0000-0000-000000000000"
    user = read()
    if user.get("type") != "user":
        sys.exit(73)
    send({"type": "system", "subtype": "init", "session_id": sid, "model": resolved, "permissionMode": "default",
          "cwd": os.getcwd(), "tools": ["Bash", "Edit", "Write"], "claude_code_version": "2.1.212", "uuid": "u-1"})
    if SCENARIO == "quota":
        send({"type": "rate_limit_event", "rate_limit_info": {"status": "rejected", "resetsAt": 1793363552,
              "rateLimitType": "five_hour", "utilization": 1.0}, "session_id": sid, "uuid": "u-2"})
        send({"type": "result", "subtype": "success", "is_error": True, "result": "Claude AI usage limit reached",
              "session_id": sid, "duration_ms": 10, "num_turns": 1, "total_cost_usd": 0, "api_error_status": 429,
              "permission_denials": [], "usage": {}, "modelUsage": {}})
        drain()
    send({"type": "assistant", "session_id": sid, "parent_tool_use_id": None, "message": {"id": "msg_1", "role": "assistant",
          "model": resolved, "content": [{"type": "text", "text": "Ich lege die Datei an."},
          {"type": "tool_use", "id": "toolu_1", "name": "Write", "input": {"file_path": "probe.txt", "content": "x"}}]}})
    send({"type": "control_request", "request_id": "perm-1", "request": {"subtype": "can_use_tool", "tool_name": "Write",
          "input": {"file_path": "probe.txt", "content": "x"}, "tool_use_id": "toolu_1", "permission_suggestions": []}})
    if SCENARIO == "crash":
        sys.stderr.write("FATAL: simulated crash\n")
        sys.stderr.flush()
        os._exit(3)
    while True:
        msg = read()
        if msg.get("type") == "control_request" and msg["request"].get("subtype") == "interrupt":
            send({"type": "control_response", "response": {"subtype": "success", "request_id": msg["request_id"], "response": {}}})
            send({"type": "result", "subtype": "error_during_execution", "is_error": True, "session_id": sid,
                  "permission_denials": [], "errors": ["interrupted"]})
            drain()
        if msg.get("type") == "control_response":
            break
    behavior = msg["response"]["response"]["behavior"]
    if SCENARIO == "hang":
        drain()
    send({"type": "user", "session_id": sid, "message": {"role": "user", "content": [{"type": "tool_result",
          "tool_use_id": "toolu_1", "is_error": behavior != "allow", "content": "ok" if behavior == "allow" else "denied"}]}})
    send({"type": "assistant", "session_id": sid, "message": {"role": "assistant", "content": [{"type": "text", "text": "Fertig."}]}})
    denials = [] if behavior == "allow" else [{"tool_name": "Write", "tool_use_id": "toolu_1", "tool_input": {}}]
    send({"type": "result", "subtype": "success", "is_error": False, "result": "Fertig: " + behavior, "session_id": sid,
          "duration_ms": 10, "num_turns": 2, "total_cost_usd": 0.01, "permission_denials": denials,
          "usage": {}, "modelUsage": {resolved: {}}})
    drain()
    """#
}
