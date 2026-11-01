# Capability-Spike M0: Claude Code

- **Datum:** 2026-10-30
- **Getestete Version:** Claude Code `2.1.212` (Homebrew-Cask `claude-code`, Apple Silicon, `darwin-arm64`, Commit `8b2783a8f907`)
- **Bezug:** Pflichtenheft J1, J2a, J3, J5, J6, K2, L2, L3; ADR-0005, ADR-0006, ADR-0010 (proposed), ADR-0014
- **Methode:** `--help`-Ausgaben, nicht-invasive Statusbefehle (`--version`, `auth status`, `doctor`), ein Steuerprotokoll-Handshake **ohne Prompt** (kein Modellaufruf), Textsuche in der installierten Binärdatei (`strings`) sowie offizielle Dokumentation auf code.claude.com / support.claude.com (abgerufen am 2026-10-30).
- **Nicht durchgeführt (Regeln des Spikes):** kein Prompt, der Kontingent verbraucht; keine Remote-Control-Sitzung gestartet; keine Claude-Einstellungen geändert; keine Zugangsdaten gelesen oder ausgegeben (E-Mail/Org in Ausgaben geschwärzt).

## 0. Wichtige Rahmenbefunde vorab

1. **Die installierte Version ist alt.** `brew info --cask claude-code` meldet `2.1.212 → 2.1.308`. Homebrew-Installationen aktualisieren sich nicht selbst (Doku [Setup](https://code.claude.com/docs/en/setup), Abschnitt Homebrew). Mehrere unten dokumentierte Funktionen verlangen neuere Versionen (z. B. natives `AGENTS.md` ab 2.1.277, `--permission-prompts` ab 2.1.259, `claude remote-control --help` ohne Login ab 2.1.302). Der Adapter muss deshalb **versionsabhängig** prüfen; Doku allein reicht nicht.
2. **Die CLI-Anmeldung ist derzeit abgelaufen.** `claude auth status --text` (saubere Umgebung) meldet `Login: Expired — log in again` und `Not logged in`. Alle Ergebnisse, die von der Anmeldung abhängen (Modellkatalog je Konto, Remote Control), sind daher nur im **nicht angemeldeten** Zustand gemessen. Die Anmeldung muss der Benutzer selbst mit `claude auth login` erneuern.
3. **Geerbte Umgebung verfälscht Ergebnisse.** Der Spike-Prozess lief unter der Claude-Desktop-App und erbte u. a. `CLAUDE_CODE_SIMPLE`, `ANTHROPIC_BASE_URL`, `CLAUDECODE`, `CLAUDE_EFFORT`. Mit geerbter Umgebung meldete `claude auth status` `authMethod: none`. Laut Doku setzt `CLAUDE_CODE_EFFORT_LEVEL` sich über `--effort` hinweg, und `ANTHROPIC_BASE_URL` (≠ api.anthropic.com) macht Remote Control unmöglich. **Der Mac-Dienst muss `claude` mit einer bereinigten, expliziten Umgebung starten** (siehe §3).

## 1. Befundtabelle

| # | Frage | Befund | Beleg | Status |
|---|-------|--------|-------|--------|
| 1a | Pfadauflösung | `which -a claude` → nur `/opt/homebrew/bin/claude`, Symlink auf `/opt/homebrew/Caskroom/claude-code/2.1.212/claude` (Mach-O arm64). Kein `~/.local/bin/claude` (nativer Installer), kein npm-Global-Paket. Doku: nativer Installer verwaltet `~/.local/bin/claude` als Symlink nach `~/.local/share/claude/versions/`; Homebrew-Casks `claude-code` (stable) und `claude-code@latest`. `claude doctor` zeigt `Package manager: homebrew`, `Path: …/Caskroom/…`. | lokale Befehle; [Setup](https://code.claude.com/docs/en/setup) | belegt |
| 1b | Versionsabfrage | `claude --version` → `2.1.212 (Claude Code)`. | lokal | belegt |
| 1c | Auth-Status nicht-invasiv | `claude auth status [--json\|--text]` existiert (Hilfe: „Show authentication status“, `--json` default). JSON (nicht angemeldet): Schlüssel `loggedIn`, `authMethod`, `apiProvider`. Exit-Code **1** wenn nicht angemeldet (gemessen), laut Doku 0 wenn angemeldet; Doku nennt zusätzlich `configDirectory`. Zusätzlich liefert `claude doctor` (read-only) einen Abschnitt **Remote Control** mit Eignungsgründen (`Not signed in to claude.ai`, `claude.ai subscription auth not active`, `Sign-in is missing the user:profile scope`). | `claude auth help status`; `claude auth status --json` (Werte geschwärzt); `claude doctor`; [CLI reference](https://code.claude.com/docs/en/cli-reference) | belegt (Feldnamen im angemeldeten Zustand, z. B. `subscriptionType`, **nicht** gemessen) |
| 2a | Headless-Start | `-p/--print`, `--output-format text\|json\|stream-json`, `--input-format text\|stream-json`, `--include-partial-messages`, `--replay-user-messages`, `--verbose`, `--no-session-persistence`, `--max-budget-usd`, `--fallback-model` in `--help` 2.1.212. `--max-turns` ist in der Binärdatei vorhanden, aber nicht in `--help` gelistet. Doku: `system/init`-Event (u. a. `session_id`, `model`, `permissionMode`, `cwd`, `tools`, `claude_code_version`, `capabilities`), abschließendes `result`-Event. | `claude --help`; [Headless](https://code.claude.com/docs/en/headless); [TS-SDK `SDKSystemMessage`](https://code.claude.com/docs/en/agent-sdk/typescript) | belegt (Event-Inhalte eines echten Laufs nicht gemessen) |
| 2b | Session-IDs | `--session-id <uuid>` (muss gültige UUID sein), `-r/--resume [id]`, `-c/--continue`, `--fork-session`. Doku: `--resume` findet Sitzungen per ID projektübergreifend; alternativ Pfad zur `.jsonl`. | `--help`; [CLI reference](https://code.claude.com/docs/en/cli-reference); [Headless](https://code.claude.com/docs/en/headless) | belegt |
| 2c | Agent SDK | Python/TS-Bibliothek, die die Claude-Code-Binärdatei startet; `Options.pathToClaudeCodeExecutable`, `model`, `effort`, `permissionMode`, `canUseTool`, `cwd`, `settingSources`. Die Binärdatei enthält den SDK-Startcode: bei `canUseTool` wird `--permission-prompt-tool stdio` übergeben. | [Agent SDK overview](https://code.claude.com/docs/en/agent-sdk/overview); [TS-Referenz](https://code.claude.com/docs/en/agent-sdk/typescript); `strings` der Binärdatei | belegt |
| 2d | Lizenz / Login | Agent-SDK-Seite: Anthropic erlaubt Drittentwicklern ohne Freigabe nicht, claude.ai-Login in ihren Produkten anzubieten – „does not allow third party developers to offer claude.ai login or rate limits“; stattdessen API-Key. Legal-Seite: OAuth ist für gewöhnliche Nutzung von Claude Code/nativen Anthropic-Apps gedacht; Entwickler dürfen claude.ai-Credentials/Session-Tokens nicht sammeln, speichern oder vermitteln; ausdrücklich **nicht** eingeschränkt ist, dass ein Endnutzer die **unveränderte** Claude-Code-Binärdatei mit dem **eigenen** Abo anmeldet. Pro/Max-Limits setzen gewöhnliche, individuelle Nutzung voraus. | [Agent SDK overview](https://code.claude.com/docs/en/agent-sdk/overview) (Hinweisbox); [Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance) | belegt (rechtliche Bewertung, keine Rechtsberatung) |
| 3a | `claude remote-control` Optionen | Unterbefehl existiert, aber `claude remote-control --help` (auch `rc`) bricht in 2.1.212 ohne Login ab: `Error: You must be logged in to use Remote Control.` Die eingebettete Hilfe in der Binärdatei nennt: `--name`, `--remote-control-session-name-prefix`, `-c/--continue`, `--session-id <id>`, `--permission-mode`, `--debug-file`, `-v/--verbose`, `--spawn same-dir\|worktree\|session` (default same-dir), `--capacity <N>`, `--[no-]create-session-in-dir`, sowie im Parser `--sandbox/--no-sandbox` (in Doku: entfernt ab 2.1.300). **Keine** Option für Modell, Effort oder Initial-Prompt. | lokaler Aufruf; `strings` (Hilfetext „Remote Control - Control local sessions from claude.ai/code or the Claude mobile app“); [Remote Control](https://code.claude.com/docs/en/remote-control) | belegt |
| 3b | Varianten | Drei Modi: (1) Server-Modus `claude remote-control` (kein lokaler Chat, mehrere Sitzungen); (2) **interaktiv** `claude --remote-control [name]` / `--rc` (normale interaktive Sitzung + Remote Control); (3) `/remote-control` in laufender Sitzung. Zusätzlich Setting `remoteControlAtStartup` (nur in User-/Managed-Settings wirksam). | `--help` (`--remote-control [name]`, `--remote-control-session-name-prefix`); [Remote Control](https://code.claude.com/docs/en/remote-control); [Settings](https://code.claude.com/docs/en/settings-reference) | belegt |
| 3c | Nicht-interaktiver Start durch anderen Prozess | Server-Modus: Doku – ohne Terminal an stdin/stdout kann die Vertrauensabfrage nicht gestellt werden → `Workspace not trusted`; einmalige Bestätigung `Enable Remote Control? (y/n)` braucht ein Terminal. Interaktiver Modus braucht per Definition ein TTY. → Ein Fremdprozess muss eine **Pseudo-TTY** bereitstellen und Vertrauen/Bestätigung vorher (einmalig, durch den Benutzer) erledigt haben. Kein dokumentierter Headless-RC-Modus (`-p` + `--remote-control` nicht dokumentiert). | [Remote Control](https://code.claude.com/docs/en/remote-control) (Requirements, Start) | teilweise (PTY-Start nicht real getestet) |
| 3d | Initial-Prompt programmatisch | Server-Modus: **nein** (keine Option). Interaktiver Modus: dokumentiert sind `claude "query"` (interaktive Sitzung mit Initial-Prompt) und `claude --remote-control "Name"`; die **Kombination** ist plausibel, aber nicht explizit dokumentiert und nicht getestet. | [CLI reference](https://code.claude.com/docs/en/cli-reference) (`claude "query"`, `--remote-control`) | nicht belegt (Testbedarf) |
| 3e | Ausgegebener Link | Server-Modus zeigt eine Session-URL und auf Leertaste einen QR-Code; interaktiv: `/rc active`-Indikator, `/remote-control` zeigt URL/QR. Die Remote-Session-ID ist der Teil der claude.ai/code-URL zwischen `/code/` und `?` – **nicht** identisch mit der lokalen UUID (`--session-id` lokal verlangt UUID). Wiederaufnahme `claude remote-control --session-id <id>` / `--continue` ca. 4 h nach Stopp. | [Remote Control](https://code.claude.com/docs/en/remote-control) (Connect, Resume) | belegt (konkretes URL-Format nicht beobachtet) |
| 3f | Voraussetzungen | Pro, Max, Team, Enterprise; **keine API-Keys**; bei Team/Enterprise Owner-Toggle; nicht mit Bedrock/Vertex/Foundry oder `ANTHROPIC_BASE_URL` ≠ api.anthropic.com; nicht mit `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`/`DISABLE_GROWTHBOOK`; `DISABLE_TELEMETRY`/`DO_NOT_TRACK` erst ab 2.1.283 kompatibel; Managed-Setting `disableRemoteControl`; HIPAA-Konfiguration schaltet RC ab. Lokaler Prozess muss weiterlaufen; Server-Modus beendet sich nach ca. 10 min Netzausfall. Transkript wird bei RC auf Anthropic-Servern gespeichert. | [Remote Control](https://code.claude.com/docs/en/remote-control); [Settings `disableRemoteControl`](https://code.claude.com/docs/en/settings-reference); `claude doctor` | belegt |
| 3g | `--model`/`--effort` für RC | Server-Modus: globale Flags vor `remote-control` werden **nicht** an die erzeugten Sitzungen weitergegeben; `--model` wird lediglich toleriert. → Modell/Effort im Server-Modus **nicht** setzbar. Interaktiver Modus `claude --remote-control … --model … --effort …`: Flags gehören zur normalen interaktiven Sitzung (dokumentiert je Flag); Wirkung in der mobilen Sicht ungetestet. Init-Message an RC-Clients enthält `effort`. | [Remote Control](https://code.claude.com/docs/en/remote-control) (Absatz zu globalen Flags); [TS `SDKSystemMessage.effort`](https://code.claude.com/docs/en/agent-sdk/typescript) | teilweise |
| 4a | `--model` | `--model <model>`: Alias (Hilfe nennt `fable`, `opus`, `sonnet`) oder voller Name (z. B. `claude-fable-5`). Priorität: `/model` > `--model` > `ANTHROPIC_MODEL` > Setting `model` > `ANTHROPIC_DEFAULT_MODEL`. Admin-Einschränkung über `availableModels`. | `--help`; [Model config](https://code.claude.com/docs/en/model-config) | belegt |
| 4b | Modelle dynamisch auflisten | **Kein** CLI-Unterbefehl zum Auflisten. Aber: SDK-Methoden `supportedModels()` / `initializationResult()` → `ModelInfo[]` mit `value`, `resolvedModel`, `displayName`, `description`, `supportsEffort`, `supportedEffortLevels`, … Das zugrundeliegende Steuerprotokoll ist mit der CLI direkt nutzbar: **real getestet** mit `claude -p --input-format stream-json --output-format stream-json --verbose --no-session-persistence` und stdin `{"type":"control_request","request_id":"spike-1","request":{"subtype":"initialize"}}` → `control_response` `success` mit Schlüsseln `account, agents, available_output_styles, commands, models, output_style, pid, remote_control_auto_enable, remote_control_auto_on_by_default, ide_rc_auto_enable_gate`. **Kein Modellaufruf, kein `result`-Event**, Exit 0. Gemessener Katalog (nicht angemeldet, `tokenSource: none`): `default` (→ `claude-opus-4-8[1m]`), `opus[1m]` (→ `claude-opus-4-8[1m]`), `claude-fable-5-1[1m]` (→ `claude-fable-5-1`), `sonnet` (→ `claude-sonnet-5`), `haiku` (→ `claude-haiku-4-5-20251001`, **ohne** Effort-Felder); alle anderen mit `supportedEffortLevels: [low, medium, high, xhigh, max]`. | lokaler Handshake (Skript im Scratchpad, siehe §5); [TS `ModelInfo`, `SDKControlInitializeResponse`](https://code.claude.com/docs/en/agent-sdk/typescript) | belegt für Mechanismus; Katalog **im angemeldeten Zustand nicht gemessen** |
| 5a | `--effort` | `--effort <level>` (low, medium, high, xhigh, max) in `--help` 2.1.212. Doku zusätzlich `ultracode` (ab 2.1.203; Binärdatei enthält `ultracode`). Weitere Wege: `CLAUDE_CODE_EFFORT_LEVEL` (höchste Priorität!), Settings `effortLevel` (low–xhigh, nicht `max`), `modelSettings.<modell>.effortLevel` (ab 2.1.251), `maxEffortLevel` als Deckel (ab 2.1.267), `/effort` in Sitzung. Standard: `high`; Opus/Sonnet/Haiku 5.5: `medium`; Opus 4.7: `xhigh`. | `--help`; [Model config](https://code.claude.com/docs/en/model-config); [CLI reference](https://code.claude.com/docs/en/cli-reference); [Settings](https://code.claude.com/docs/en/settings-reference) | belegt |
| 5b | Stille Fallbacks | **Gemessen:** `claude -p --effort bogus …` → nur stderr-Warnung `Unknown --effort value 'bogus' — ignoring it and using the default effort.`, Exit 0. **Doku:** nicht unterstützte Stufe → „falls back to the highest supported level at or below“ (z. B. `xhigh` → `high` auf Opus 4.6). Ungültiges `--permission-mode` dagegen → harter Fehler. | lokaler Aufruf (ohne Prompt); [Model config](https://code.claude.com/docs/en/model-config) | belegt |
| 5c | Effektives Modell/Effort bestätigen | Modell: `system/init.model` (Hauptmodell) und `result.modelUsage` (Schlüssel = tatsächlich genutzte Modelle, inkl. Hilfsmodelle). Effort: `system/init.effort` wird laut Doku **nur** an Remote-Control-Clients gesendet und in der Init-Message für die eigene Anwendung **weggelassen** → im Headless-Modus **nicht bestätigbar**. | [TS `SDKSystemMessage`, `SDKResultMessage`, `ModelUsage`](https://code.claude.com/docs/en/agent-sdk/typescript) | belegt (Doku); realer Lauf ausstehend |
| 6a | Permission-Modi | `--permission-mode` Auswahl in 2.1.212: `acceptEdits, auto, bypassPermissions, manual, dontAsk, plan` (`manual` = Alias für `default`). `--allowedTools`, `--disallowedTools`, `--tools`, `--add-dir`, Settings `permissions.allow/deny`. `--dangerously-skip-permissions` und `--allow-dangerously-skip-permissions` existieren – **nicht verwenden**. | `--help`; [Headless](https://code.claude.com/docs/en/headless); [Permission modes](https://code.claude.com/docs/en/permission-modes) | belegt |
| 6b | Freigaben im Headless-Modus | Ohne Host wird im Manual-Modus jede freigabepflichtige Aktion **abgelehnt**. Dokumentierter Host: `--permission-prompt-tool mcp__<server>__<tool>` (MCP-Tool) oder `PermissionRequest`-Hook. Das SDK nutzt intern `--permission-prompt-tool stdio`; dann sendet die CLI `control_request` (`can_use_tool`) über stdout und erwartet `control_response` auf stdin (Binärdatei-Code belegt; Doku beschreibt Envelope `{type:"control_request", request_id, request}`). `--permission-prompt-tool` steht **nicht** in `--help` 2.1.212, ist aber in der Binärdatei vorhanden. `--permission-prompts none` erst ab 2.1.259 (in 2.1.212 nicht vorhanden). Ablehnungen erscheinen in `result.permission_denials`. | [Headless](https://code.claude.com/docs/en/headless); [CLI reference](https://code.claude.com/docs/en/cli-reference); [TS-Referenz](https://code.claude.com/docs/en/agent-sdk/typescript); `strings` | teilweise (Roundtrip nicht real getestet) |
| 6c | Sicherheit `-p` | `-p` überspringt den Workspace-Trust-Dialog und führt Projekt-Hooks/`.mcp.json` aus (Hilfe-Text und Doku). | `--help` (`-p`); [Headless](https://code.claude.com/docs/en/headless) | belegt |
| 7a | Arbeitsverzeichnis | Prozess-cwd ist das Arbeitsverzeichnis (SDK `cwd`, Default `process.cwd()`); `--add-dir` für Zusatzpfade. Gelöschtes cwd → Warnung im Stream. | [TS-Referenz](https://code.claude.com/docs/en/agent-sdk/typescript); [Headless](https://code.claude.com/docs/en/headless) | belegt |
| 7b | Eingebaute Worktrees | `-w/--worktree [name]` → `<repo>/.claude/worktrees/<name>` auf Branch `worktree-<name>`; `--tmux`; Tool `EnterWorktree` (Claude kann selbst wechseln); Subagent-`isolation: worktree`; RC-Server `--spawn worktree`; Hintergrundsitzungen (`--bg`) isolieren per Worktree und **committen und pushen ohne Nachfrage**, wenn ein Remote existiert. | `--help`; [Worktrees](https://code.claude.com/docs/en/worktrees); [Agent view](https://code.claude.com/docs/en/agent-view) | belegt |
| 8 | Kontingent-/Limit-Signale | Stream-Events: `rate_limit_event` mit `rate_limit_info.status` (`allowed`/`allowed_warning`/`rejected`), optional `resetsAt`, `utilization`, `errorCode: credits_required` (ab 2.1.181); `system/api_retry` mit `error: rate_limit` u. a., `retry_delay_ms`, `error_status`; `result.is_error`, `api_error_status`, `total_cost_usd` (Client-Schätzung). `rate_limit_event` ist in der 2.1.212-Binärdatei vorhanden. | [TS `SDKRateLimitEvent`, `SDKResultMessage`](https://code.claude.com/docs/en/agent-sdk/typescript); [Headless (api_retry)](https://code.claude.com/docs/en/headless); `strings` | teilweise (nie real beobachtet; `resetsAt` ist **optional**) |
| 9 | Deep Link `claude://code/{session-id}` | Support-Artikel listet `claude://code`, `claude://code/{session-id}`, `claude://code/new[?q=…&mode=…&repo=…&branch=…]` und Universal Links `https://claude.ai/code/…`. Unbekannte ID → Sitzungsliste. Erfordert Claude-Code-Zugang. Der Artikel sagt **nicht**, für welche Sitzungstypen; die App-Code-Ansicht enthält laut Doku Cloud-Sitzungen und Remote-Control-Sitzungen. Lokale Headless-/SDK-Sitzungen erscheinen dort nicht (nur RC-verbundene Sitzungen sind in der App). `?q=` füllt nur den Composer (nicht abgesendet; zudem für Cloud/GitHub-Repos gedacht). | [Support: Open the Claude mobile app with a link](https://support.claude.com/en/articles/14898120-open-the-claude-mobile-app-with-a-link); [Mobile](https://code.claude.com/docs/en/mobile); [Remote Control](https://code.claude.com/docs/en/remote-control) | teilweise (Funktion mit RC-ID auf iPhone nicht getestet) |
| 10 | Instruktionsdateien | `CLAUDE.md`/`.claude/CLAUDE.md`/`CLAUDE.local.md`, `~/.claude/CLAUDE.md`; Importe per `@pfad` (nicht in Code-Spans/Fences; externe Importe brauchen einmalige Freigabe). Natives Lesen von `AGENTS.md` (wenn kein CLAUDE.md vorhanden) erst **ab 2.1.277** – 2.1.212 enthält die Meldung `AGENTS.md loaded` nicht. → Für 2.1.212 muss ein `CLAUDE.md` mit `@AGENTS.md` existieren. Dieses Repo hat inzwischen ein `CLAUDE.md`, dessen erste Zeile `@AGENTS.md` ist (Stand 2026-10-30, nicht im Spike angelegt). | [Memory](https://code.claude.com/docs/en/memory); `strings` | belegt |

## 2. Empfehlung für den Swift-Adapter (`ClaudeCodeProvider`)

### 2.1 Erkennung (J1, ADR-0005) – nur nicht-invasive Aufrufe

1. **Kandidatenpfade** in fester Reihenfolge, jeweils `FileManager.isExecutableFile` + Symlink auflösen (Anzeige), gestartet wird aber der stabile Symlink: benutzerdefinierter Pfad → `~/.local/bin/claude` (nativ) → `/opt/homebrew/bin/claude` → `/usr/local/bin/claude` → npm-Global-Bin (nur wenn vom Benutzer bestätigt). Nicht auf LaunchAgent-`PATH` verlassen.
2. `claude --version` → Regex `^(\d+\.\d+\.\d+) \(Claude Code\)`.
3. `claude auth status --json` → `loggedIn`, `authMethod`, `apiProvider` (+ optionale Felder tolerant parsen); Exit 1 = nicht angemeldet. Nie Tokens lesen.
4. `claude doctor` → Abschnitt „Remote Control“ als Diagnose-Text für `remoteControllable` (Textparser defensiv, nur als Hinweis; endgültig erst nach realem RC-Test).
5. **Modell-/Effort-Katalog** per `initialize`-Handshake (siehe 2.2) – kein Kontingentverbrauch.
6. Auffrischen bei macOS-Start, Versionswechsel (Pfad-Ziel ändert sich, z. B. `Caskroom/claude-code/<ver>`), Login-Wechsel (`auth status`), vor jedem Jobstart.
7. Feature-Detection zusätzlich über `system/init.capabilities` (ab 2.1.205) und Versionsschwellen (Tabelle im Code, nicht in UI).

**Bereinigte Umgebung für jeden Start** (`Process.environment` explizit setzen): nur `HOME`, `USER`, `LOGNAME`, `TMPDIR`, `LANG`/`LC_*`, `PATH` (kontrolliert), `SHELL`, `TERM` (nur PTY). **Nicht** vererben: `ANTHROPIC_*`, `CLAUDE_CODE_*`, `CLAUDECODE`, `CLAUDE_EFFORT`, `DISABLE_*`, `DO_NOT_TRACK`. Falls der Benutzer solche Variablen in `settings.json` (`env`-Block) setzt, als Diagnose anzeigen – nicht ändern.

### 2.2 Modell-Katalog (ADR-0006, keine fest eingebaute Liste)

Start ohne Prompt, cwd = Ziel-Worktree bzw. Projektordner:

```
claude -p --input-format stream-json --output-format stream-json --verbose --no-session-persistence
stdin: {"type":"control_request","request_id":"<uuid>","request":{"subtype":"initialize"}}
```

`control_response.response.models[]` verlustfrei speichern (`value` als provider-native ID, `resolvedModel`, `displayName`, `description`, `supportsEffort`, `supportedEffortLevels`, …). `supportsEffort == nil/false` → UI „Anbieterstandard – nicht einstellbar“. Danach stdin schließen; Prozess endet mit Exit 0. Hinweis: Der Handshake führt `SessionStart`-Hooks des Benutzers aus (gemessen: `hook_started`/`hook_response`).

Ehrliche Einordnung: Das Steuerprotokoll ist das Protokoll des offiziellen Agent SDK; die Typen sind dokumentiert, die Rohnachrichten aber nicht als eigenständige CLI-Schnittstelle zugesichert. Deshalb: Antwort strikt validieren, bei Fehlschlag **keine** Ersatzliste, sondern Agent als „Modellwahl nicht verfügbar – Anbieterstandard“ markieren und Jobs mit explizitem Modell blockieren (`needs_configuration`). Optional echte Alternative: kleiner Node-Helper mit `@anthropic-ai/claude-agent-sdk` `supportedModels()` und `pathToClaudeCodeExecutable` = erkannte Binärdatei.

### 2.3 Startmodus A – „Headless-Job“ (vollautomatisch, eigene Freigabe-UI) – **Standard für v1**

```
claude -p
  --input-format stream-json --output-format stream-json --verbose
  --session-id <job-uuid>
  --model <ModelInfo.value>
  [--effort <level>]                      # nur wenn in supportedEffortLevels; sonst weglassen
  --permission-mode manual                # oder acceptEdits je Projektprofil
  --permission-prompt-tool stdio          # Freigaben als control_request can_use_tool
  --disallowedTools "Bash(git push *)" "Bash(git push)" "EnterWorktree"
  [--allowedTools <Projektprofil, z. B. "Bash(swift test *)">]
  [--max-budget-usd <optional>]
```

- cwd = von Software Regisseur angelegter Worktree; Prompt als `{"type":"user","message":{"role":"user","content":"…"}}` auf stdin.
- Vor Start: Modell ∈ Katalog, Effort ∈ `supportedEffortLevels` – sonst blockieren (Doku-Fallback ist still). stderr auf `Unknown --effort value` prüfen → Job abbrechen, nicht weiterlaufen lassen.
- Persistieren: `session_id`, `system/init.model` als `effectiveModelId`, `effectiveEffort = nicht bestätigt`, `claude_code_version`, `permissionMode`, `capabilities`, `result.*`, `rate_limit_event`s.
- Freigaben: `can_use_tool` → Job-Status `waiting_approval` → iPhone/Mac-UI → `control_response` allow/deny. Zeitlimit ohne Auto-Allow (L3); bei Timeout deny + Job pausieren.
- Dokumentierter Ersatz für `stdio`: `--mcp-config <json> --permission-prompt-tool mcp__regisseur__approve` mit einem kleinen gebündelten stdio-MCP-Server, der per XPC an den Mac-Dienst weiterreicht.
- **Kein** `--bg` (auto-commit/push), **kein** `-w`, **kein** `bypassPermissions`/`--dangerously-skip-permissions`.
- Nicht in der Claude-App sichtbar (ehrlich so anzeigen).

### 2.4 Startmodus B – „Remote-Control-Sitzung“ (mobile Weiterführung in der Claude-App) – Ziel nach Bestehen der Tests

```
(PTY) claude --remote-control "<Job-Kurzname>"
             --session-id <job-uuid>
             --model <ModelInfo.value> [--effort <level>]
             --permission-mode manual
             --settings '<JSON nur mit Hooks für Statussignale>'
             "<Initial-Prompt>"
```

- Start über `openpty`/`posix_spawn` mit Pseudo-TTY (Argumentarray, keine Shell). Voraussetzungen vorher in der UI prüfen und vom Benutzer einmalig selbst erledigen lassen: Login, RC-Bestätigung, Workspace-Trust für den Worktree-Wurzelpfad.
- Session-URL aus PTY-Ausgabe (`https://claude.ai/code/<remote-id>`) extrahieren → Deep Link `claude://code/<remote-id>`; sonst nur `claude://code` (Sitzungsliste). Lokale `job-uuid` **nie** als Deep-Link-ID verwenden.
- Freigaben erfolgen in der Claude-App bzw. im Terminal; Software Regisseur zeigt nur Status (über dokumentierte Hooks `Notification`/`Stop`/`SessionEnd`).
- Server-Modus `claude remote-control` **nicht** für Jobs mit Modell-/Effort-Vorgabe verwenden (Flags werden nicht übernommen, kein Prompt).

### 2.5 V1-Fallback, falls Modus B keinen programmatischen Erst-Prompt annimmt

1. **Bevorzugt – „Headless starten, dann übergeben“:** Job läuft in Modus A (Modell/Effort gesetzt, erster Turn vollautomatisch). Auf Wunsch „In Claude-App fortsetzen“: Mac-Dienst beendet den Headless-Prozess sauber nach Turn-Ende (stdin schließen bzw. SIGINT, nicht SIGTERM mitten im Turn) und startet in PTY `claude --resume <job-uuid> --remote-control "<Name>" --model … --effort …` (ohne Prompt). Danach Deep Link wie oben. Testbedarf siehe §4.
2. **Manuell-transparent:** Mac startet `claude --remote-control "<Name>" --model … --effort …` in PTY **ohne** Prompt; iPhone zeigt den vorbereiteten Prompt mit „Kopieren“ und öffnet `claude://code/<remote-id>` bzw. die Sitzungsliste. Klar als „Prompt in Claude-App einfügen und senden“ beschriftet (vorbefüllt ≠ abgesendet).
3. `claude://code/new?q=…` ist **kein** Fallback für lokale Mac-Jobs (Cloud-/GitHub-Sitzungen, nur vorbefüllt).

### 2.6 Worktrees (L2)

Software Regisseur erzeugt den Worktree selbst (`software-regisseur/<task-id>/<job-short-id>`, außerhalb des Scan-Stamms) und startet `claude` mit cwd dort. Claude-eigene Worktree-Schichten unterbinden: kein `-w`, kein RC `--spawn worktree`, `--disallowedTools EnterWorktree`, kein `--bg`; zusätzlich Hinweis in der verwalteten CLAUDE.md-Sektion. Subagenten mit `isolation: worktree` bleiben ein Restrisiko (Diagnose: `.claude/worktrees/` im Worktree beobachten).

### 2.7 Instruktionsdateien (G)

Für 2.1.212: im Projekt-`CLAUDE.md` (nicht-destruktiv, verwaltete Sektion) `@AGENTS.md` importieren bzw. ein minimales `CLAUDE.md` nur mit diesem Import anlegen (Zustimmung nach AGENTS.md Regel 7). Ab ≥ 2.1.277 wird `AGENTS.md` nativ gelesen, solange kein `CLAUDE.md` existiert – der Import bleibt kompatibel.

## 3. Lizenz-/Policy-Einordnung (J5, ADR-0014)

- v1 = Eigengebrauch: Software Regisseur startet die **unveränderte** Claude-Code-Binärdatei, angemeldet mit dem **eigenen** Abo des Benutzers über Anthropics eigenen Login-Flow. Das ist nach der Legal-Seite ausdrücklich nicht eingeschränkt.
- Software Regisseur darf **keine** claude.ai-Tokens lesen, speichern, synchronisieren oder setzen (kein `claude setup-token`/`CLAUDE_CODE_OAUTH_TOKEN` durch die App, kein Keychain-Zugriff, keine Weitergabe per CloudKit).
- Das Agent SDK selbst mit claude.ai-Login in ein an Dritte verteiltes Produkt einzubetten, ist ohne Freigabe nicht erlaubt; ein späterer Vertrieb braucht API-Key-Authentifizierung oder eine Freigabe von Anthropic und einen neuen ADR, der ADR-0014 ersetzt.
- Pro/Max-Limits setzen gewöhnliche, individuelle Nutzung voraus → Warteschlange ohne aggressive Parallelität/Retry-Schleifen (K2).

## 4. Offene Punkte – reale Tests mit Kontingentverbrauch

Vorbedingung: Benutzer meldet sich selbst an (`claude auth login`); idealerweise vorher `brew upgrade claude-code` (2.1.308), dann alle Tests mit der Zielversion wiederholen. Testordner: neues Scratch-Git-Repo, einmal interaktiv `claude` dort gestartet und Vertrauen akzeptiert.

| # | Ziel | Minimaler Befehl / Ablauf | Erwartung / Abnahme |
|---|------|---------------------------|---------------------|
| T0 | Katalog im angemeldeten Zustand (kein Kontingent) | Handshake aus §2.2 | `account.subscriptionType` gesetzt; Modellliste je Abo dokumentieren |
| T1 | Headless-Grundlauf, effektives Modell | `printf '%s\n' '{"type":"user","message":{"role":"user","content":"Antworte nur mit OK."}}' \| claude -p --input-format stream-json --output-format stream-json --verbose --session-id <uuid> --model sonnet --effort low --permission-mode manual --max-turns 1` | `system/init.session_id == <uuid>`, `init.model`, kein `init.effort`, `result.modelUsage`, ggf. `rate_limit_event` |
| T2 | Freigabe-Roundtrip | wie T1 mit `--permission-prompt-tool stdio` und Prompt „Lege die Datei probe.txt mit Inhalt x an.“; auf `control_request` `can_use_tool` mit deny antworten | Request-Felder dokumentieren; Datei nicht angelegt; `permission_denials` gefüllt |
| T3 | RC interaktiv mit Erst-Prompt (PTY) | `script -q /dev/null claude --remote-control "SR-Spike" --session-id <uuid> --model sonnet --effort low "Antworte nur mit OK."` | Prompt läuft automatisch; Sitzung in Claude-iOS-App sichtbar; URL-Format notieren; Chat + Freigabe vom iPhone möglich; Modell/Effort in App angezeigt? |
| T4 | Deep Link | auf iPhone `claude://code/<remote-id>` öffnen (aus T3-URL) | öffnet genau diese Sitzung |
| T5 | Übergabe Headless → RC | nach T1: `script -q /dev/null claude --resume <uuid> --remote-control "SR-Spike-Resume" --model sonnet --effort low` | Verlauf aus T1 in der App sichtbar, weiterchattbar |
| T6 | Trust für neue Worktrees | T3 in einem frisch angelegten Worktree unterhalb eines bereits vertrauten Pfads | Erscheint Trust-Abfrage? Davon hängt vollautomatischer Modus B ab |
| T7 | Effort bestätigen | T1 mit `--debug-file <pfad>`; Log auf gesendete Effort-Stufe prüfen | Falls nur Debug-Log: weiterhin „nicht bestätigt“ (Debug-Format ist kein Vertrag) |
| T8 | Limit-Signale | passiv: alle `rate_limit_event`/`api_retry` aus echten Jobs protokollieren | Felder `status`, `resetsAt`, `utilization` belegen |
| T9 | Unbekanntes Modell | wie T1 mit `--model claude-gibt-es-nicht` | Fehlerform (`model_not_found`?) für Status `blocked` dokumentieren |

## 5. Risiken

1. **Versionsdrift:** Doku beschreibt 2.1.30x, installiert ist 2.1.212; Homebrew ohne Auto-Update. Flags erscheinen/verschwinden (z. B. RC `--sandbox` entfernt ab 2.1.300; `--permission-prompts` erst ab 2.1.259). → versionsabhängige Capability-Matrix, Tests je Version.
2. **Steuerprotokoll (`initialize`, `can_use_tool`, `--permission-prompt-tool stdio`)** ist SDK-intern verwendet; Typen dokumentiert, Rohformat aber kein separater CLI-Vertrag. → strikte Validierung, Feature-Detection, MCP-Permission-Tool als dokumentierte Alternative.
3. **Stille Fallbacks** bei Effort (ungültig → ignoriert; nicht unterstützt → herabgestuft) und Env-Override `CLAUDE_CODE_EFFORT_LEVEL` → Vorab-Validierung + bereinigte Umgebung zwingend; effektiver Effort bleibt im Headless-Modus „nicht bestätigt“.
4. **RC-Automatisierung über PTY** ist fragil (TUI-Ausgabe parsen, Einmal-Dialoge, Trust je Verzeichnis, Prozess muss weiterlaufen, Server-Modus endet nach ca. 10 min Netzausfall). Nicht als „automatisch“ bewerben, bevor T3–T6 bestanden sind (J6, ADR-0010 bleibt `proposed`).
5. **Policy/Abo:** RC nur mit claude.ai-Abo, nicht mit API-Key, nicht über Gateway; Team/Enterprise-Admin-Toggles, Trusted Devices, HIPAA. Transkripte von RC-Sitzungen liegen auf Anthropic-Servern.
6. **Sicherheit `-p`:** kein Trust-Dialog, Projekt-Hooks und MCP-Server laufen → nur in autorisierten Worktrees starten; `bypassPermissions` nie verwenden; `git push` per `--disallowedTools` sperren; `--bg` wegen Auto-Commit/Push meiden.
7. **Doppelte Worktrees** durch `EnterWorktree`/Subagent-Isolation trotz Sperre möglich → überwachen.
8. **Remote-ID ≠ lokale Session-ID** → falscher Deep Link führt nur zur Sitzungsliste; ID ausschließlich aus der beobachteten URL ableiten.
9. **Kontingent-Reset** nur, wenn `rate_limit_event.resetsAt` tatsächlich geliefert wird; sonst Backoff mit Jitter (K2). `total_cost_usd` ist eine Client-Schätzung.
10. **Aktueller Zustand:** CLI-Login abgelaufen; `claude doctor` meldet fehlende RC-Eignung. Ohne Neuanmeldung durch den Benutzer ist Claude Code auf diesem Mac **nicht einsatzbereit**.

## Anhang: lokale Belege (Auszüge)

```
$ which -a claude
/opt/homebrew/bin/claude
$ readlink -f /opt/homebrew/bin/claude
/opt/homebrew/Caskroom/claude-code/2.1.212/claude
$ claude --version
2.1.212 (Claude Code)
$ claude auth status --json            # saubere Umgebung, Werte geschwärzt
{'loggedIn': False, 'authMethod': 'none', 'apiProvider': 'firstParty'}   exit=1
$ claude auth status --text
Login: Expired — log in again … Not logged in. Run claude auth login to authenticate.
$ claude remote-control --help
Error: You must be logged in to use Remote Control.
$ claude doctor
Package manager: homebrew … Auto-updates: Managed by package manager
Remote Control
Remote Control requires a claude.ai subscription. …
- Not signed in to claude.ai
- claude.ai subscription auth not active
- Sign-in is missing the user:profile scope
$ claude --help | grep -E -- '--effort|--model|--permission-mode'
--effort <level>   Effort level for the current session (low, medium, high, xhigh, max)
--model <model>    … alias for the latest model (e.g. 'fable', 'opus', or 'sonnet') or a model's full name (e.g. 'claude-fable-5').
--permission-mode <mode>  (choices: "acceptEdits", "auto", "bypassPermissions", "manual", "dontAsk", "plan")
$ claude -p --effort bogus --input-format stream-json --output-format stream-json --verbose </dev/null
Warning: Unknown --effort value 'bogus' — ignoring it and using the default effort. Valid values: low, medium, high, xhigh, max.
$ claude -p --permission-mode bogus …
error: option '--permission-mode <mode>' argument 'bogus' is invalid. …
# initialize-Handshake (kein Prompt): control_response success
MODEL {"value":"default","resolvedModel":"claude-opus-4-8[1m]",…,"supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"],…}
MODEL {"value":"haiku","resolvedModel":"claude-haiku-4-5-20251001","displayName":"Haiku",…}   # ohne Effort-Felder
{'remote_control_auto_enable': False, 'remote_control_auto_on_by_default': False, 'ide_rc_auto_enable_gate': True}
```

Das Handshake-Skript lag nur im Session-Scratchpad (nicht im Repo); es startet `claude` mit `env`-Whitelist (`HOME`, `USER`, `PATH`), schreibt die eine `control_request`-Zeile, liest bis zur `control_response` und schließt stdin.
