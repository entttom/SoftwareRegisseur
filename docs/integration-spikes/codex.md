# Capability-Spike: OpenAI Codex (M0)

| Feld | Wert |
|---|---|
| Datum | 2026-10-30 |
| Host | macOS 27.0 (Darwin 27.0.0), Apple Silicon (`arm64`) |
| Getestete CLI | `codex-cli 0.164.0` (npm-global unter Homebrew-Node, `/opt/homebrew/bin/codex`) |
| Zusätzlich gefunden | Desktop-App `/Applications/ChatGPT.app`, Bundle-ID `com.openai.codex`, Version `26.1023.50603`, mit gebündelter CLI `0.165.0-alpha.1.2` |
| Login | ChatGPT-Konto (`codex login status` → `Logged in using ChatGPT`) |
| Bezug | Pflichtenheft J1, J2a, J3, J4, J6, K2, L2, L3; ADR-0005, ADR-0006, ADR-0010; Abnahme A12, A13, A20, A31, A35, A37, A40, A41 |

**Methodik.** Nur `--help`-Ausgaben, lokal erzeugte Protokollschemata, offizielle Dokumentation (`developers.openai.com/codex/*` leitet per HTTP 308 auf `learn.chatgpt.com/docs/*` um; beides wird hier als offizielle OpenAI-Quelle gezählt) und **nicht abrechnungsrelevante** app-server-Requests (`initialize`, `model/list`, `account/read`, `account/rateLimits/read`, `remoteControl/status/read`, `permissionProfile/list`, `modelProvider/capabilities/read`, `collaborationMode/list`, `thread/start` mit `ephemeral: true`). **Es wurde kein `turn/start` und kein `codex exec` mit Prompt ausgeführt**; kein Modellkontingent verbraucht. `~/.codex/auth.json` wurde nicht gelesen. Kontodaten (E-Mail, Account-IDs, Installations-ID) sind in diesem Dokument bewusst weggelassen.

Generierte Schemata (nicht im Repo, nur Scratch): `/private/tmp/claude-501/codex-spike/{schema,schema-exp,ts,ts-exp}` via

```sh
codex app-server generate-json-schema --out <dir>            # stabil: 106 Client-Requests
codex app-server generate-json-schema --experimental --out <dir>   # inkl. experimentell: 175
codex app-server generate-ts [--experimental] --out <dir>
```

Statuslegende: **belegt** = durch Doku und/oder lokalen Lauf nachgewiesen; **teilweise** = Schema/Doku vorhanden, Laufzeitverhalten noch nicht real geprüft oder Doku widersprüchlich; **nicht belegt** = weder dokumentiert noch nachgewiesen.

---

## 1. Erkennung (Pfad, Version, Authentifizierung)

| Thema | Befund | Beleg | Status |
|---|---|---|---|
| Installationswege | Offiziell: `npm install -g @openai/codex`, `brew install --cask codex`, Binary-Release von GitHub; Desktop-App über `codex app`. | github.com/openai/codex README (Abschnitt Installation) | belegt |
| Pfad auf diesem Mac | `/opt/homebrew/bin/codex` → Symlink auf `../lib/node_modules/@openai/codex/bin/codex.js` (npm-global unter Homebrew-Node). Kein Homebrew-Cask installiert (`brew list --cask` ohne codex), kein `/usr/local/bin/codex`. | `which -a codex; ls -la $(which codex)` | belegt |
| npm-Shim braucht Node | `codex.js` beginnt mit `#!/usr/bin/env node`; das native Binary liegt unter `…/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex` (Mach-O arm64). Unter einem LaunchAgent-`PATH` ohne `/opt/homebrew/bin` scheitert der Shim, weil `node` fehlt. | `head -1 …/bin/codex.js`; `codex doctor --summary` → `runtime npm (package …/vendor/aarch64-apple-darwin …)` | belegt (lokal) |
| Desktop-App | Heißt auf diesem System **„ChatGPT.app“**, Bundle-ID **`com.openai.codex`**, Team-ID `2DC432GLL2`, registriert URL-Schemata `codex`, `http`, `https`. Enthält eine eigene CLI unter `Contents/Resources/codex-cli/bin/codex` (Shell-Wrapper → `CodexCLI.app/Contents/MacOS/codex`), Version `codex-cli 0.165.0-alpha.1.2`. Die Bundle-interne Struktur ist **nicht dokumentiert**. | `PlistBuddy … Info.plist`; `codesign -dv`; `…/codex-cli/codex-package.json`; `…/bin/codex --version` | belegt (lokal), Layout undokumentiert |
| Version | `codex --version` → `codex-cli 0.164.0`. Zusätzlich liefert `initialize` den `userAgent` mit Version (`software_regisseur_spike/0.164.0 (Mac OS 27.0.0; arm64) …`). Laufender Daemon: `codex app-server daemon version` (JSON) – hier „kein Socket“, da kein Daemon läuft. | lokale Ausgabe | belegt |
| Auth-Status nicht-invasiv | `codex login status`: Exit `0` + `Logged in using ChatGPT`; mit leerem `CODEX_HOME` Exit `1` + `Not logged in`. Doku: Exit 0, wenn „credentials are present“. Detaillierter: app-server `account/read` → `{account: {type: "chatgpt"\|"apiKey"\|"amazonBedrock", planType…}, requiresOpenaiAuth}` (ohne `refreshToken: true` kein Token-Refresh). | `codex login status; echo $?`; `CODEX_HOME=<leer> codex login status`; learn.chatgpt.com/docs/developer-commands; learn.chatgpt.com/docs/app-server (`account/read`) | belegt |
| Diagnose | `codex doctor --json` liefert einen redigierten maschinenlesbaren Bericht (Installation, Auth, Sandbox, Desktop-App, Konnektivität, Daemon). Führt Netzwerk-Reachability-Checks aus → nicht bei jeder Erkennung, nur auf Anforderung. | `codex doctor --help`; `codex doctor --summary` | belegt |

## 2. Programmatischer Start: `exec` vs. `app-server` vs. SDK

| Thema | Befund | Beleg | Status |
|---|---|---|---|
| Empfohlene Einbettung | app-server ist „the interface Codex uses to power rich clients“ und wird für eine tiefe Integration (Auth, Verlauf, Approvals, gestreamte Events) empfohlen; für Automatisierung/CI wird das Codex SDK empfohlen. | learn.chatgpt.com/docs/app-server | belegt |
| Stabilität | Doku: „The app-server command and WebSocket transport are experimental and aren't supported for production workloads.“ CLI-Hilfe: `app-server [experimental]`. Methoden/Felder hinter `capabilities.experimentalApi` sind zusätzlich instabil. | learn.chatgpt.com/docs/app-server; `codex app-server --help` | belegt (Risiko) |
| SDKs | TypeScript-Library (Node ≥ 18) und Python-Library; das Python-SDK „controls the local Codex app-server over JSON-RPC“. Ein Swift-SDK gibt es nicht. | learn.chatgpt.com/docs/codex-sdk | belegt |
| `codex exec` | Stabil, nicht-interaktiv, `--json` liefert JSONL-Events (`thread.started` mit `thread_id`, `turn.started`, `turn.completed` mit `usage`, `turn.failed`, `item.*`, `error`). Fortsetzen per `codex exec resume <SESSION_ID>`. **Keine interaktiven Approvals** (nur `never`/automatischer Review) → für J4/L3 (mobile Freigaben) ungeeignet als Hauptweg. | `codex exec --help`; learn.chatgpt.com/docs/non-interactive-mode | belegt |
| Protokollform | JSON-RPC 2.0 **ohne** `jsonrpc`-Feld, Transport `stdio://` (JSONL, Default), `unix://[PATH]`, `ws://IP:PORT`, `off`. Pflicht-Handshake: Request `initialize` (`clientInfo{name,title,version}`, `capabilities{experimentalApi, requestAttestation, optOutNotificationMethods?}`) → Notification `initialized`; vorher „Not initialized“. | Doku + lokaler Lauf: `initialize` → `{userAgent, codexHome, platformFamily:"unix", platformOs:"macos"}` | belegt |
| Thread/Turn | `thread/start` (Felder u. a. `model`, `modelProvider`, `serviceTier`, `cwd`, `approvalPolicy`, `approvalsReviewer`, `sandbox`, `config` (freie Overrides), `baseInstructions`, `developerInstructions`, `ephemeral`, `serviceName`) → `{thread{id (UUIDv7), sessionId, source, cwd, cliVersion, gitInfo, status…}, model, reasoningEffort, approvalPolicy, sandbox, cwd, instructionSources}`. `turn/start` (`threadId`, `input[]`, Overrides `model`, `effort`, `cwd`, `approvalPolicy`, `sandboxPolicy`, `summary`, `outputSchema`, `clientUserMessageId`). Weiter: `turn/steer`, `turn/interrupt`, `thread/resume` (bevorzugt per `threadId`, `excludeTurns`), `thread/fork`, `thread/read`, `thread/list`, `thread/turns/list`, `thread/items/list`, `thread/archive`. | generiertes Schema `ClientRequest.json`, `v2/ThreadStartParams.ts`, `v2/TurnStartParams.ts`, `v2/ThreadResumeParams.ts`; Doku app-server | belegt (Schema+Doku), Turn-Lauf offen |
| Streaming-Events | Notifications u. a. `thread/started`, `thread/status/changed`, `thread/settings/updated`, `turn/started`, `turn/completed`, `turn/diff/updated`, `turn/plan/updated`, `item/started`, `item/completed`, `item/agentMessage/delta`, `item/commandExecution/outputDelta`, `item/fileChange/patchUpdated`, `thread/tokenUsage/updated`, `account/rateLimits/updated`, `model/rerouted`, `error`, `warning`, `serverRequest/resolved`. | `ServerNotification.json` (85 Methoden) | belegt (Schema) |
| Persistente IDs / Resume | `Thread.id` (UUIDv7) und `sessionId`; Resume über `thread/resume {threadId}`; nicht-ephemere Threads werden auf Platte (Rollouts unter `~/.codex`) persistiert, `ephemeral: true` verhindert das (lokal geprüft: keine neuen Session-Dateien). | Schema `Thread.ts`; lokaler Lauf | belegt |
| Gemeinsamer Daemon | 0.164.0 hat einen geteilten lokalen app-server-Daemon (`codex app-server daemon start|stop|version|enable-remote-control…`, Control-Socket `~/.codex/app-server-control/app-server-control.sock`), `codex app-server proxy` (stdio ↔ Daemon-Socket), `codex agents` (Kommandozentrale über alle Sitzungen des Daemons). Daemon ist experimentell. | `codex app-server daemon --help`; `codex app-server proxy --help`; github.com/openai/codex/blob/main/codex-rs/app-server-daemon/README.md | teilweise |

## 3. Modellwahl und dynamische Modellliste

| Thema | Befund | Beleg | Status |
|---|---|---|---|
| CLI/Config | `-m, --model <MODEL>` (TUI und `exec`), Config-Key `model`, Override `-c model="…"`. | `codex --help`, `codex exec --help`; Config-Referenz learn.chatgpt.com/docs/config-file/config-reference | belegt |
| app-server | `thread/start.model`, `thread/resume.model`, `turn/start.model` („for this turn and subsequent turns“). | Schema | belegt |
| **Dynamische Liste** | `model/list {limit, cursor, includeHidden}` → `data[]` mit `id`, `model`, `displayName`, `description`, `hidden`, `isDefault`, **`supportedReasoningEfforts[{reasoningEffort, description}]`**, **`defaultReasoningEffort`**, `inputModalities`, `serviceTiers`, `upgrade`/`upgradeInfo`, `nextCursor`. Nicht abrechnungsrelevant. Doku: Default liefert nur Picker-sichtbare Modelle; `includeHidden: true` für alles. | Doku app-server (`model/list`); lokaler Lauf (unten) | belegt |
| Lokaler Lauf (Konto dieses Macs) | 9 sichtbare + 2 versteckte Modelle (`gpt-reserve`, `codex-auto-review`), eine Seite (`nextCursor: null`). Default: `gpt-6.1-sol` (`isDefault: true`). Die Liste ist konto-/versionsabhängig und darf **nicht** hart kodiert werden. | `probe.py` → `model/list {includeHidden:true, limit:100}` | belegt |

## 4. Reasoning-Effort

| Thema | Befund | Beleg | Status |
|---|---|---|---|
| Config-Key | `model_reasoning_effort` (String). Doku: „Reasoning effort advertised by the selected model, such as `low`, `medium`, `high`, `xhigh`, `max`, or `ultra`“; verfügbare Stufen hängen von Modell und Client ab. Daneben `plan_mode_reasoning_effort`. | learn.chatgpt.com/docs/config-file/config-reference | belegt |
| CLI | **Kein eigenes `--effort`-Flag** in 0.164.0 (weder TUI noch `exec`); nur `-c model_reasoning_effort="high"`. | `codex --help`, `codex exec --help` | belegt |
| app-server | `turn/start.effort` (Typ `ReasoningEffort = string`, offen); bei `thread/start`/`thread/resume` nur über `config: {"model_reasoning_effort": "…"}` (lokal geprüft: Antwort `reasoningEffort` übernimmt den Wert). | Schema `TurnStartParams.ts`, `ReasoningEffort.ts`; `probe2.py` | belegt (thread/start), turn/start offen |
| Pro Modell & entdeckbar | Ja, über `model/list.supportedReasoningEfforts` + `defaultReasoningEffort`. Lokal unterschiedlich: z. B. `gpt-6.1-sol` → `low, medium, high, xhigh, max, ultra` (Default `low`); `gpt-6-luna`, `gpt-5.6-luna`, `gpt-reserve` → `low … max` **ohne `ultra`** (Default `medium`). Doku: „use the values returned by `model/list`“. | `probe.py`; Doku app-server | belegt |
| **Keine Validierung beim Thread-Start** | `thread/start` akzeptiert **ohne Fehler**: unbekannte Modell-ID (`does-not-exist-model`), nicht beworbene Stufe (`gpt-6-luna` + `ultra`) und Fantasiewert (`model_reasoning_effort: "bogus"`); die Antwort spiegelt die Werte nur zurück. Ob/wie `turn/start` dann scheitert, ist offen (Quota-Test nötig). → Der Adapter **muss selbst** gegen `model/list` validieren (ADR-0006: kein stiller Fallback). | `probe2.py` (lokal, ohne Turn) | belegt |
| Effektive Werte bestätigen | `thread/start`-Antwort `model`/`reasoningEffort` und `thread/settings/updated` (`ThreadSettings.model`, `.effort`) = **konfigurierte** Werte. Schema-Hinweis zu `Thread.model`: „This is not per-turn execution telemetry.“ Serverseitige Umleitung wird per `model/rerouted {fromModel, toModel, reason}` gemeldet. Ein Feld „tatsächlich ausgeführtes Modell/Effort pro Turn“ existiert im Schema nicht. `exec --json` dokumentiert ebenfalls kein Modell-/Effort-Feld. | Schema `Thread.ts`, `ThreadSettings.ts`, `ModelReroutedNotification.ts`; Doku non-interactive-mode | teilweise |
| `auto` / Anbieterstandard | Ohne Overrides erbt `thread/start` die Benutzer-`config.toml` (lokal: `model=gpt-6-luna`, `model_reasoning_effort=high`), nicht zwingend `defaultReasoningEffort` des Modells. | `probe2.py` Fall „no overrides“ | belegt |

## 5. Approvals und Sandbox

| Thema | Befund | Beleg | Status |
|---|---|---|---|
| Sandbox-Modi | `read-only`, `workspace-write`, `danger-full-access` (CLI `-s`, Config `sandbox_mode`, app-server `thread/start.sandbox` in **kebab-case**). Die Doku-Beispielanfrage verwendet `"sandbox": "workspaceWrite"` – lokal **abgelehnt**: `-32600 unknown variant workspaceWrite, expected one of read-only, workspace-write, danger-full-access`. Feinsteuerung pro Turn über `turn/start.sandboxPolicy` (`{type:"workspaceWrite", writableRoots[], networkAccess, …}`). `workspace-write` → Antwort `networkAccess: false`. | `codex --help`; Schema `SandboxMode.ts`, `SandboxPolicy.ts`; `probe2.py` | belegt (Doku-Beispiel fehlerhaft) |
| Approval-Policies | CLI `-a`: `on-request`, `never`. Config: `on-request \| never \| {granular = {…}}`; Doku: `untrusted` „unsupported“, `on-failure` deprecated. app-server-Schema kennt zusätzlich `untrusted` und `{granular}`; `untrusted` wurde von `thread/start` lokal akzeptiert. | `codex --help`; Config-Referenz; `AskForApproval.ts`; `probe2.py` | teilweise (Doku vs. Schema) |
| Approval-Reviewer | `approvalsReviewer: "user" \| "auto_review" \| "guardian_subagent"` (Default `user`); `--approve-for-me` = automatischer KI-Review. Für Software Regisseur nicht als Default. | `ApprovalsReviewer.ts`; `codex --help` | belegt |
| Approval-Requests im app-server | Server→Client-Requests: `item/commandExecution/requestApproval` (u. a. `threadId`, `turnId`, `itemId`, `command`, `cwd`, `reason`, `commandActions`, `proposedExecpolicyAmendment`), Antwort `{decision: "accept"\|"acceptForSession"\|"decline"\|"cancel"\|{acceptWithExecpolicyAmendment}…}`; `item/fileChange/requestApproval` (`accept\|acceptForSession\|decline\|cancel`); `item/permissions/requestApproval`; `item/tool/requestUserInput`; `mcpServer/elicitation/request`. Ablauf: `item/started` → Request → Entscheidung → `serverRequest/resolved` → `item/completed`. | `ServerRequest.json`; Doku app-server | belegt (Schema+Doku), Laufzeit offen |
| Gefahr durch Benutzer-Config | Die globale `~/.codex/config.toml` dieses Macs setzt `approval_policy = "never"` und `sandbox_mode = "danger-full-access"`; `thread/start` ohne Overrides übernimmt das (`approval=never`, `sandbox={type:dangerFullAccess}`). | `probe2.py`; `codex doctor --summary` („unrestricted fs + enabled network · approval Never“) | belegt |
| Sicherer Default | `sandbox: "workspace-write"` (kein Netz), `approvalPolicy: "on-request"`, `approvalsReviewer: "user"` **immer explizit** setzen; nie `danger-full-access`, `--dangerously-bypass-approvals-and-sandbox`, `--dangerously-bypass-hook-trust` oder `auto_review` als Default. | Ableitung aus L3 + obigen Belegen | Empfehlung |

## 6. Arbeitsverzeichnis / Worktrees

| Thema | Befund | Beleg | Status |
|---|---|---|---|
| cwd | CLI `-C, --cd <DIR>`, `--add-dir <DIR>` (zusätzlich schreibbar); app-server `thread/start.cwd`, `turn/start.cwd`. `exec` verlangt standardmäßig ein Git-Repo (`--skip-git-repo-check`). | `codex exec --help`; Schema | belegt |
| Eigene Worktrees von Codex | CLI `--worktree`: „Run the session in a new managed Git worktree“ (nur neue Sitzungen, nicht mit `resume`/`review`/`--ephemeral`/`--ignore-user-config`). Desktop-Doku: verwaltete Worktrees unter `$CODEX_HOME/worktrees`, **detached HEAD**, automatische Aufräumung (Standard: 15 neueste). Im app-server-Schema (stabil und experimentell) gibt es **kein** Worktree-Feld. | `codex exec --help`; learn.chatgpt.com/docs/developer-commands; learn.chatgpt.com/docs/environments/git-worktrees; `grep -ri worktree ts-exp` → leer | belegt |
| Koordination (L2) | Software Regisseur legt Worktree/Branch `software-regisseur/<task-id>/<job-short-id>` selbst an und übergibt ihn als `cwd`; Codex-eigenes `--worktree` nicht verwenden (sonst doppelte Worktree-Schicht und Fremd-Aufräumung). | Ableitung | Empfehlung |
| AGENTS.md-Erkennung pro cwd | `thread/start` mit `cwd` = Repo liefert `instructionSources: [".../SoftwareRegisseur/AGENTS.md"]`. | `probe2.py` | belegt |

## 7. Kontingent-/Rate-Limit-Signale

| Thema | Befund | Beleg | Status |
|---|---|---|---|
| Abfrage | `account/rateLimits/read` (stabil, nicht abrechnungsrelevant) → `ordinaryUsageAllowed`, `rateLimits`/`rateLimitsByLimitId{limitId…}` mit `primary`/`secondary` `{usedPercent, windowDurationMins, resetsAt}`, `credits`, `spendControlReached`, `rateLimitReachedType`, `rateLimitResetCredits`. Doku: „`resetsAt` is a Unix timestamp (seconds) for the next reset.“ Schema-Hinweis: bei `ordinaryUsageAllowed == null` dürfen Clients „not infer recovery from percentages or reset times“. Lokal: Fenster 300 min und 10 080 min mit `resetsAt` geliefert. | Doku app-server; Schema `GetAccountRateLimitsResponse.ts`; `probe.py` | belegt (für ChatGPT-Login) |
| Push-Update | `account/rateLimits/updated` (sparse; mit letztem Snapshot zusammenführen oder neu lesen). | Schema-Kommentar | belegt (Schema) |
| Fehler im Turn | `error`-Notification `{error: TurnError, willRetry, threadId, turnId}`, `TurnError.codexErrorInfo` u. a. `usageLimitExceeded`, `rateLimitExceeded`, `sessionBudgetExceeded`, `serverOverloaded`, `unauthorized`, `contextWindowExceeded`, `{httpConnectionFailed{httpStatusCode}}`, `{responseTooManyFailedAttempts{httpStatusCode}}`. Doku listet `UsageLimitExceeded` u. a., aber nicht `rateLimitExceeded`. Ein **Retry-After**-Feld ist weder dokumentiert noch im Schema. | `CodexErrorInfo.ts`, `ErrorNotification.ts`; Doku app-server | teilweise (reales Limit nicht ausgelöst) |
| Verboten | `account/rateLimitResetCredit/consume` verbraucht ein Reset-Guthaben des Benutzers → niemals automatisch (K2: Limits nicht umgehen). | Methodenliste | Empfehlung |

## 8. Mobile Weiterführung (ADR-0010, A31)

| Thema | Befund | Beleg | Status |
|---|---|---|---|
| Offizieller Mobil-Weg | Codex in der ChatGPT-iOS-App mit Cloud **oder** verbundenem Mac/PC; Verbindung über die Desktop-App (Settings › Connections › „Control this Mac or PC“, QR-Code, gleiches Konto/Workspace, Rechner wach & online). Mobil: laufende Aufgaben verfolgen, „pick up existing conversations“, neue Aufgaben starten, Approvals (Approve / Always approve / Deny), Diffs prüfen. Verfügbarkeit „depends on rollout and your workspace settings“. | learn.chatgpt.com/docs/mobile | belegt (Desktop-App-Weg) |
| CLI-Host | `codex remote-control start|stop|pair [--json]` (experimentell) startet den app-server-Daemon mit Remote Control; `pair --json` liefert `pairingCode`, `manualPairingCode`, `environmentId`, `expiresAt`. Doku: für „managed remote-control clients and SSH workflows“, ersetzt nicht `codex app-server --listen` für eigene Protokoll-Clients. Experimentelle RPCs: `remoteControl/enable|disable|status/read|pairing/start|pairing/status|client/list|client/revoke`. Lokal: `remoteControl/status/read` → `status: "disabled"`. | `codex remote-control --help`; learn.chatgpt.com/docs/developer-commands; Schema `ts-exp/v2/RemoteControl*.ts`; `probe.py` | belegt (Befehle), Wirkung offen |
| Sichtbarkeit von CLI/app-server-Threads auf dem iPhone | **Nicht dokumentiert.** Weder Mobil-Doku noch Daemon-README sagen, ob Threads eines eigenen `codex app-server`-Prozesses bzw. eines Daemon-Clients in der ChatGPT-App erscheinen. Plausibler, aber ungetesteter Weg: Daemon mit Remote Control + Software Regisseur verbindet sich über `codex app-server proxy` mit **demselben** Daemon. Ein separater stdio-`app-server`-Prozess ist sehr wahrscheinlich nicht mobil sichtbar. Lokal beobachtet: per app-server gestartete Threads haben `source: "vscode"`; `thread/list` filtert standardmäßig auf „interactive sources“. GitHub-Issues/Diskussionen (#21935, #35928, #27565) zeigen offene Fragen bzw. Doku-Widersprüche; keine Staff-Antwort. | learn.chatgpt.com/docs/mobile; Daemon-README; github.com/openai/codex/discussions/21935; issues/35928 | **unklar** |
| Deep Links | **Nicht dokumentiert.** Die macOS-App registriert lokal das Schema `codex://`, aber es gibt keine dokumentierten Pfade/Parameter; für die iOS-ChatGPT-App ist kein Deep Link dokumentiert. → Gemäß J4/ADR-0010 nicht verwenden. | `PlistBuddy -c 'Print :CFBundleURLTypes'`; learn.chatgpt.com/docs/mobile | nicht belegt |

## 9. Anweisungsdateien

| Thema | Befund | Beleg | Status |
|---|---|---|---|
| AGENTS.md | Global: in `~/.codex` erste nicht-leere Datei von `AGENTS.override.md`, `AGENTS.md`. Projekt: vom Projekt-Root bis zum cwd höchstens eine Datei pro Verzeichnis (`AGENTS.override.md` > `AGENTS.md` > `project_doc_fallback_filenames`), Verkettung Root → cwd (näher = später = gewichtiger). Limit `project_doc_max_bytes`, Default 32 KiB. **CLAUDE.md wird nicht gelesen**, außer per `project_doc_fallback_filenames`. | learn.chatgpt.com/docs/agent-configuration/agents-md | belegt |
| Nachweis geladener Dateien | app-server `thread/start` → `instructionSources[]` (lokal: Repo-`AGENTS.md`; globale `~/.codex/AGENTS.md` ist hier 0 Byte und erscheint daher nicht). Zusätzlich `baseInstructions`/`developerInstructions` pro Thread setzbar. | `probe2.py`; Schema | belegt |

---

## Empfehlung für den Swift-Adapter (`CodexAgentProvider`)

**Schnittstelle:** `codex app-server --listen stdio://` als Kindprozess (Foundation `Process`, explizites Executable + Argument-Array, keine Shell), JSONL über stdin/stdout, stderr nur in redigierte Diagnoselogs. `codex exec --json` nur als Fallback-Diagnose, nicht für Jobs mit Approvals. TypeScript-/Python-SDK nicht verwenden (Node/Python-Abhängigkeit, setzen selbst auf app-server auf). Weil app-server offiziell „experimental“ ist: Protokollschicht versioniert kapseln, beim Start `codex --version` prüfen und gegen die mit `generate-json-schema` erzeugte Schema-Revision dieser Version testen (CI-Fixture pro unterstützter Version); unbekannte Notifications tolerant ignorieren.

**Erkennung (J1):**
1. Kandidaten in fester Reihenfolge: benutzerdefinierter Pfad → `/opt/homebrew/bin/codex` → `/usr/local/bin/codex` → `~/.local/bin/codex` → Ergebnis von `/usr/bin/env PATH=<Login-PATH> which codex` (Login-PATH einmalig aus `zsh -l -c 'echo $PATH'` ohne Interpolation ermitteln) → Desktop-App über `NSWorkspace.urlsForApplications(withBundleIdentifier: "com.openai.codex")` (getrennt als „Codex Desktop-App“ ausweisen; deren gebündelte CLI nur als Fallback und mit Hinweis „undokumentierter Pfad, Version x.y-alpha“).
2. Für npm-Installationen den Prozess mit `PATH` = Verzeichnis des aufgelösten Symlinks + `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin` starten (Shim braucht `node`).
3. `codex --version` (Regex `codex-cli (\S+)`), `codex login status` (Exit 0/≠0) – beide ohne Seiteneffekte. Danach app-server-Sitzung: `initialize` → `account/read` (nur `account.type`, `planType` speichern; **keine E-Mail in CloudKit**) → `model/list` → `account/rateLimits/read`.

**Handshake:**
```json
{"id":1,"method":"initialize","params":{"clientInfo":{"name":"software_regisseur","title":"Software Regisseur","version":"<app-version>"},"capabilities":{"experimentalApi":false,"requestAttestation":false}}}
{"method":"initialized"}
```
`experimentalApi: true` nur in einer separaten Verbindung für `remoteControl/status/read`, solange ADR-0010 offen ist.

**Modellkatalog (ADR-0006):** `model/list {"includeHidden": false, "limit": 100}` paginiert bis `nextCursor == null`. Pro Modell speichern: `id` (verlustfrei), `displayName`, `description`, `isDefault`, `hidden`, `supportedReasoningEfforts[].reasoningEffort` (+ `description` als Anzeigetext-Quelle), `defaultReasoningEffort`, `capabilityRevision = hash(cliVersion + Antwort)`. Auffrischen bei App-Start, Versionswechsel (`--version`), `account/updated`-Notification und **unmittelbar vor jedem Jobstart**. Stufen-UI: nur Werte aus `supportedReasoningEfforts`; Übersetzung `low→Niedrig`, `medium→Mittel`, `high→Hoch`, `xhigh→Extra hoch`, `max→Maximal`, `ultra→Ultra (mit automatischer Delegation)`; unbekannte zukünftige Werte roh anzeigen.

**Jobstart (J3):**
1. Vorab-Validierung gegen frischen Katalog: `requestedModelId ∈ model/list.data[].id` **und** `requestedEffort ∈ supportedReasoningEfforts` – sonst `needs_configuration` (app-server validiert selbst nicht, siehe §4).
2. `thread/start`:
```json
{"id":10,"method":"thread/start","params":{
  "cwd":"<worktree-pfad>",
  "model":"<resolvedModelId>",
  "config":{"model_reasoning_effort":"<resolvedEffort>"},
  "sandbox":"workspace-write",
  "approvalPolicy":"on-request",
  "approvalsReviewer":"user",
  "serviceName":"software_regisseur",
  "ephemeral":false}}
```
   Bei `effort = auto`: `config.model_reasoning_effort` = `defaultReasoningEffort` des gewählten Modells explizit setzen (sonst greift die Benutzer-`config.toml`); in der UI als „Anbieterstandard (aufgelöst: …)“ dokumentieren.
3. Antwort prüfen: `model == resolvedModelId`, `reasoningEffort == resolvedEffort`, `approvalPolicy == "on-request"`, `sandbox.type == "workspaceWrite"`, `cwd` korrekt – sonst abbrechen. Speichern: `thread.id`, `thread.sessionId`, `thread.cliVersion`, `instructionSources`, `thread.path`.
4. `turn/start {"threadId": "...", "input":[{"type":"text","text":"<prompt>","text_elements":[]}], "effort":"<resolvedEffort>", "model":"<resolvedModelId>", "clientUserMessageId":"<job-uuid>"}`; `UserInput` laut Schema 0.164.0: `{type:"text", text, text_elements[]}` (`text_elements` ist Pflichtfeld).
5. Events: `turn/started`, `item/*`, `turn/diff/updated`, `thread/tokenUsage/updated`, `turn/completed` (`turn.status`, `turn.error.codexErrorInfo`), `model/rerouted` (→ `effectiveModelId = toModel`, Hinweis anzeigen), `thread/settings/updated` (→ konfigurierte Werte). `effectiveModelId/effectiveEffort` nur als „konfiguriert, nicht umgeleitet“ markieren, solange Codex keine Pro-Turn-Telemetrie liefert.
6. Approvals: Server-Requests `item/commandExecution/requestApproval`, `item/fileChange/requestApproval`, `item/permissions/requestApproval`, `item/tool/requestUserInput` an iPhone/Mac weiterreichen; Antwort `{"decision":"accept"|"acceptForSession"|"decline"|"cancel"}`; nach Timeout `cancel` + Job `waiting_approval`/`failed`, nie automatisch `accept`.
7. Abbruch: `turn/interrupt`; Fortsetzen nach App-Neustart: `thread/resume {"threadId": "...", "excludeTurns": true}` + `thread/turns/list`.

**Kontingent (K2):** `codexErrorInfo ∈ {usageLimitExceeded, rateLimitExceeded, sessionBudgetExceeded}` → `waiting_quota`; danach `account/rateLimits/read`; `resetsAt` nur als „vom Anbieter gemeldet“ anzeigen und nur nutzen, wenn `ordinaryUsageAllowed != null`; sonst begrenzter Backoff mit Jitter. `account/rateLimitResetCredit/consume` nie aufrufen.

**Mobile (J4/J6):** Bis zum E2E-Nachweis ehrlich „Status/Approvals in Software Regisseur“ als V1-Weg; „Im offiziellen Codex fortsetzen“ nur nach bestandenem Test (siehe O6) freischalten. Keine `codex://`-Links.

## Offene Punkte – benötigen echten, kontingentverbrauchenden Lauf

Alle Läufe in einem Wegwerf-Git-Repo (`/private/tmp/claude-501/codex-spike/repo`, `git init` + 1 Commit), `ephemeral` wo möglich, Prompt minimal.

| # | Frage | Vorgeschlagener minimaler Test |
|---|---|---|
| O1 | Werden `model`/`effort` real angewendet, und welche Events/Felder erscheinen in einem echten Turn? | app-server: `thread/start {cwd:<repo>, model:"gpt-6.1-sol", config:{model_reasoning_effort:"low"}, sandbox:"read-only", approvalPolicy:"on-request", ephemeral:true}` → `turn/start {threadId, input:[{type:"text",text:"Antworte nur mit OK.",text_elements:[]}], effort:"low"}`; alle Notifications mitschneiden. |
| O2 | Scheitert `turn/start` bei unbekannter Modell-ID bzw. nicht beworbener Stufe – mit welchem `codexErrorInfo`? Oder stiller Fallback? | Wie O1, aber `model:"does-not-exist-model"`; zweiter Lauf `model:"gpt-6-luna"`, `effort:"ultra"`. |
| O3 | Approval-Roundtrip und Ablehnung | Wie O1 mit `sandbox:"workspace-write"`, Prompt „Führe `curl -sI https://example.com` aus und nenne den Statuscode.“ → `item/commandExecution/requestApproval` erwarten, mit `decline` beantworten, `serverRequest/resolved` und `item/completed` prüfen. |
| O4 | `exec`-Parität (Fallback/Diagnose) | `codex exec --json --ephemeral -C <repo> -s read-only -m gpt-6.1-sol -c model_reasoning_effort="low" -c approval_policy="never" "Antworte nur mit OK."` |
| O5 | Resume nach Prozessneustart | O1 mit `ephemeral:false`, app-server beenden, neu starten, `thread/resume {threadId, excludeTurns:true}`, zweiter Turn „Antworte nur mit OK2.“; danach `codex archive <id>`. |
| O6 | **A31 – mobile Sichtbarkeit** eines von Software Regisseur gestarteten Threads | `codex remote-control start --json` → `codex remote-control pair --json` → iPhone (ChatGPT-App, Codex) koppeln → Software Regisseur verbindet sich über `codex app-server proxy` mit dem Daemon → O1-Turn mit `ephemeral:false` → prüfen, ob Thread in der iOS-App sichtbar ist, dort eine Folgenachricht senden und eine Approval aus O3 auf dem iPhone erteilen. Gegenprobe: separater `codex app-server --listen stdio://`-Prozess. Danach `codex remote-control stop`. Vor dem Test die vom Desktop-App-Setup stammende, in 0.164.0 ignorierte Config-Einstellung `remote_connections` klären. |
| O7 | Quota-Fehlerform | Nicht künstlich auslösbar; beim ersten natürlichen Auftreten `error`-Notification, `turn.error` und `account/rateLimits/read` redigiert protokollieren. |

## Risiken

1. **app-server ist experimentell** („aren't supported for production workloads“); Feldnamen ändern sich zwischen Versionen (Desktop-App bündelt bereits 0.165.0-alpha, Doctor meldet 0.166.0). Gegenmaßnahme: Versions-Gate + Schema-Snapshot-Tests pro unterstützter CLI-Version, `capabilitySource = "app-server model/list @ <version>"`.
2. **Doku ≠ Implementierung:** Doku-Beispiel `sandbox: "workspaceWrite"` wird von 0.164.0 abgelehnt; `untrusted` laut Doku unsupported, im Schema aber vorhanden. Maßgeblich ist das lokal generierte Schema.
3. **Keine serverseitige Validierung** von Modell/Effort bei `thread/start` → ohne eigene Prüfung droht genau der verbotene stille Fallback bzw. ein später Fehler.
4. **Gefährliche Benutzer-Config** (`never` + `danger-full-access`) wird ohne explizite Overrides geerbt. Zusätzlich `config.toml`-Profile/`-p` und `projects.<path>.trust_level` beachten.
5. **Nebenwirkungen von `thread/start`:** Es startet die im Benutzerprofil konfigurierten MCP-Server und Plugin-Server (lokal u. a. `xcode`, `node_repl`, `cua_repl`, `codex_apps`, `xcodebuildmcp`), auch mit `-c mcp_servers={}`. Für isolierte Jobs prüfen, ob Plugin-/MCP-Deaktivierung pro Thread möglich ist (`disabledPluginIds` an `turn/start`, `--disable <FEATURE>`), sonst in der UI ausweisen.
6. **npm-Shim + LaunchAgent-PATH**: ohne `node` im PATH nicht startbar.
7. **Mobile Weiterführung unbelegt**; Remote Control ist experimentell, rollout- und workspaceabhängig; Daemon-Modell bedeutet geteilten Zustand mit TUI/Desktop-App des Benutzers.
8. **Rate-Limit-Zeitpunkte** (`resetsAt`) sind Anbieterangaben ohne Garantie; nur Hinweis, keine harte Planung.
9. **Datenschutz:** `account/read` liefert E-Mail und Account-ID; nicht loggen, nicht nach CloudKit synchronisieren.

## Quellen

- learn.chatgpt.com/docs/app-server (Redirect von developers.openai.com/codex/app-server)
- learn.chatgpt.com/docs/codex-sdk (Redirect von developers.openai.com/codex/sdk)
- learn.chatgpt.com/docs/developer-commands
- learn.chatgpt.com/docs/non-interactive-mode (Redirect von developers.openai.com/codex/noninteractive)
- learn.chatgpt.com/docs/config-file/config-reference (Redirect von developers.openai.com/codex/config-reference)
- learn.chatgpt.com/docs/agent-configuration/agents-md (Redirect von developers.openai.com/codex/guides/agents-md)
- learn.chatgpt.com/docs/environments/git-worktrees
- learn.chatgpt.com/docs/mobile
- github.com/openai/codex – README.md, codex-rs/app-server-daemon/README.md, Discussion #21935, Issue #35928
- Lokale Befehle: `codex --help`, `codex exec --help`, `codex app-server --help`, `codex app-server daemon --help`, `codex remote-control --help`, `codex login status`, `codex doctor --summary`, `codex app-server generate-json-schema`/`generate-ts`; Probe-Skripte `/private/tmp/claude-501/codex-spike/probe.py`, `probe2.py` (nicht im Repo).
