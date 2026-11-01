# Bedrohungsmodell – Software Regisseur 1.0

**Stand:** 2026-10-30 · **Grundlage:** Pflichtenheft A.4, I, L2, L3, N1, N2, Q1, Q2, Q3; ADR-0009, 0014, 0017, 0019, 0020, 0021, 0023, 0024; Spike-Protokolle unter `docs/integration-spikes/`.
**Zugehöriger Prüfbericht:** [audit-2026-10-30.md](audit-2026-10-30.md) (Befund-IDs `SR-SEC-xx`, mit Behebungsstand). Geräte-Eigentum: [ADR-0026](../adr/0026-geraete-eigentum-host-pfade-job-branch-commits.md).

Dieses Dokument beschreibt, was geschützt wird, wo Vertrauensgrenzen verlaufen, welche Bedrohungen modelliert sind, welche Gegenmaßnahmen im Code stehen (mit Datei und Test) und welche Restrisiken bewusst getragen werden. Es ist kein Nachweis, dass Gegenmaßnahmen wirken; dieser Nachweis steht im Prüfbericht und in den genannten Tests.

> Hinweis zur Prüftiefe: Während der Erstellung hatte der Mac das Prozesslimit pro Benutzer erreicht. Es konnten weder Tests ausgeführt noch eine vollständige `grep`-Suche über alle Quellen gemacht werden. Die Zuordnung „Gegenmaßnahme → Code“ beruht auf dem gezielten Lesen der genannten Dateien. Einträge mit „nicht verifiziert“ müssen nachgeprüft werden.

---

## 1. Systemüberblick und Annahmen

- **Einsatz:** Eigengebrauch eines Entwicklers (ADR-0014). Ein Apple-Account, ein oder mehrere iPhones/iPads, ein oder mehrere Macs.
- **Mac:** UI-App (Menüleiste, ohne Sandbox bis zum Spike) und **Agent Service** (LaunchAgent über `SMAppService`, ohne Sandbox, Hardened Runtime, Developer ID, ADR-0020). Der Dienst ist einziger Datenbankschreiber und einziger Besitzer der `CKSyncEngine` (ADR-0019).
- **Agenten:** `codex app-server` (JSON-RPC über stdio) und `claude -p` mit stream-json (ADR-0021). Beide laufen im Benutzerkontext mit den Rechten des angemeldeten Benutzers.
- **Sync:** private CloudKit-Datenbank, eigene Zone, Payload in `encryptedValues`; Polling ohne sichtbare Push-Mitteilungen (ADR-0011).
- **Annahme A1:** Der Mac-Benutzeraccount ist nicht kompromittiert. Ein lokaler Angreifer mit Benutzerrechten kann ohnehin alles, was der Dienst kann; davor schützt Software Regisseur nicht.
- **Annahme A2:** Die Apple-ID ist durch Zwei-Faktor-Authentifizierung geschützt. Ein **fremdes oder kompromittiertes Gerät im selben iCloud-Account** (verlorenes iPhone ohne Sperre, Schadsoftware in einer eigenen Test-App mit demselben Container) ist dennoch als Angreifer modelliert, weil es beliebige Records in die private Datenbank schreiben kann.
- **Annahme A3:** Repositories und ihr Inhalt (Markdown, `AGENTS.md`, `.claude/`, `.codex/`, `.git/config`, Hooks) sind **nicht vertrauenswürdig**. Das gilt auch für eigene Repos, sobald ein Agent darin gearbeitet hat.

## 2. Schutzgüter

| ID | Schutzgut | Ort | Schutzziel |
|----|-----------|-----|-----------|
| S1 | Provider-API-Schlüssel (OpenAI, Anthropic, Gemini) | Keychain iOS/macOS | Vertraulichkeit |
| S2 | Agenten-Anmeldungen (Codex-/Claude-Login, `~/.codex`, `~/.claude`, GitHub-`gh`-Token) | Dateien/Keychain der jeweiligen CLI | Vertraulichkeit; Software Regisseur liest sie nie (ADR-0014, ADR-0021) |
| S3 | Quellcode und Git-Historie der Benutzer-Repositories, nicht committete Änderungen im Haupt-Working-Tree | lokale Repos | Integrität, Verfügbarkeit |
| S4 | Rechner des Benutzers (Codeausführung außerhalb der Agenten-Sandbox) | Mac | Integrität |
| S5 | Aufgaben, Notizen, Transkripte, Audio, ADRs | SQLite, CloudKit, Markdown | Vertraulichkeit, Integrität |
| S6 | Freigabeentscheidungen (Approvals) | SQLite, CloudKit | Integrität, Authentizität |
| S7 | Job-, Lock- und Host-Zustand | SQLite, CloudKit | Integrität (keine Doppelstarts, kein falscher Repo-Pfad) |
| S8 | Kontingente/Abos der Coding-Agenten | Provider | Verfügbarkeit, keine ungewollten Kosten |
| S9 | Update-Kanal (Sparkle-Appcast, EdDSA-Schlüssel) | GitHub Releases, Release-Mac-Keychain | Integrität |
| S10 | Logs, Diagnose, Exporte | os_log, Exportdateien | keine Geheimnisse, keine unnötigen Personendaten |

## 3. Vertrauensgrenzen

```
 iPhone/iPad ──(TLS, Apple-ID)──▶ iCloud private DB ◀──(CKSyncEngine)── Agent Service (Mac, unsandboxed)
     │                                                                     │  ▲
     │ TLS + eigener API-Key                                               │  │ XPC (Mach-Service, Peer: gleiches Team)
     ▼                                                                     │  │
 KI-Anbieter (OpenAI/Anthropic/Gemini) ◀──TLS──────────────────────────────┤  Mac-UI (Sparkle ◀──HTTPS+EdDSA── GitHub Releases)
                                                                           │
                         posix_spawn, explizite Argumente, bereinigte Env  ▼
                       git ◀──▶ Benutzer-Repos / Worktrees ◀──▶ codex / claude ──TLS──▶ OpenAI / Anthropic
                                                                  │
                                                                  └─(gh CLI)──▶ GitHub
```

| ID | Grenze | Was überquert sie | Wer ist auf der anderen Seite vertrauenswürdig? |
|----|--------|-------------------|-----------------------------------------------|
| T1 | iPhone ↔ iCloud | Records (Aufgaben, Job-Wünsche, Freigaben, Reviews, Einstellungen) | Apple-Infrastruktur ja; **jedes Gerät im Account kann jeden Record schreiben** |
| T2 | iCloud ↔ Agent Service | dieselben Records, inklusive Records, die eigentlich dem Mac gehören (Jobs, Locks, Pfade) | eingehende Records sind **Daten mit eingeschränktem Vertrauen** |
| T3 | Mac-UI ↔ Agent Service (XPC) | alle Befehle inklusive Programmpfade, Löschung, Integration | nur Prozesse, die die XPC-Peer-Anforderung erfüllen |
| T4 | Agent Service → Kindprozesse (`git`, `codex`, `claude`, `gh`) | Argumente, Umgebung, Arbeitsverzeichnis, stdin | Kindprozesse lesen Repo-Konfiguration → **nicht vertrauenswürdige Eingaben** |
| T5 | Agent ↔ Repository/Worktree | Dateien, Hooks, `AGENTS.md`/`CLAUDE.md`, `.claude/settings.json`, `.mcp.json`, `.codex/` | Repo-Inhalt ist nicht vertrauenswürdig |
| T6 | Agent ↔ Agenten-Anbieter | Prompt, Repo-Inhalt, Tool-Ergebnisse | Anbieter vertraglich; Inhalte verlassen den Mac |
| T7 | App/Dienst ↔ KI-Anbieter (BYOK) | Notizen, Transkripte, Repo-Auszüge, API-Key | TLS; Inhalt ist Prompt-Injection-Quelle (Spec I) |
| T8 | Agent Service ↔ GitHub (`gh`) | Issue-Texte, Labels | GitHub-Inhalte sind nicht vertrauenswürdig |
| T9 | Mac-UI ↔ Sparkle-Feed | Appcast, Update-Archiv | nur mit gültiger EdDSA-Signatur und Developer-ID-Signatur |
| T10 | Dienst → Logs/Export/Diagnose | Fehlertexte, Pfade, Befehle | Logs können geteilt werden (Sysdiagnose, Feedback) |

## 4. Angreifermodell

| ID | Angreifer | Fähigkeiten |
|----|-----------|-------------|
| A-Repo | Autor eines fremden oder präparierten Repositories (auch als ZIP kopiertes Repo mit `.git/`) | kontrolliert Dateien, Markdown, `AGENTS.md`, `.claude/`, `.mcp.json`, `.gitattributes`; bei kopierten Repos auch `.git/config` und `.git/hooks` |
| A-Inj | Prompt-Injection über Notiz, Transkript, Issue-Text, Markdown, Webseite, Tool-Ausgabe | steuert Text, den ein Modell liest |
| A-Agent | ein Coding-Agent, der fehlgeleitet ist oder injiziert wurde | kann im Rahmen der Freigaben Dateien schreiben und Befehle ausführen; kann um Freigaben bitten |
| A-Dev | weiteres Gerät im selben iCloud-Account (verloren, kompromittiert, fehlerhafte ältere App-Version) | schreibt beliebige Records in die private Zone |
| A-Team | anderes Programm, das mit derselben Team-ID signiert ist (andere eigene App, Hilfswerkzeug, Debug-Build) | kann sich als XPC-Peer verbinden, wenn nur „gleiches Team“ geprüft wird |
| A-Net | Netzwerkangreifer | MITM ohne gültiges TLS-Zertifikat nicht möglich |
| A-Upd | Angreifer auf den Update-Kanal (GitHub-Account, CDN) | kann Appcast/Archiv austauschen |
| A-Shoulder | jemand mit kurzzeitigem Zugriff auf das entsperrte iPhone | kann Freigaben erteilen, Jobs anlegen |

## 5. Bedrohungen und Gegenmaßnahmen

Spalten: **Gegenmaßnahme im Code** (Datei:Zeile), **Test** (vorhandener Test oder „neu“), **Status** (✅ umgesetzt und gelesen · ⚠️ teilweise · ❌ Lücke, siehe Befund).

### 5.1 Pflichtliste aus Q1

| ID | Bedrohung | Gegenmaßnahme im Code | Test | Status / Befund |
|----|-----------|----------------------|------|-----------------|
| B01 | **Nicht vertrauenswürdige lokale Repos / `AGENTS.md`**: Repo-Inhalt bringt Agenten oder Dienst dazu, Code auszuführen | Agent nur im eigenen Worktree (`WorktreeManager.swift:126-155`); Codex mit explizitem `sandbox: workspace-write`, `approvalPolicy: on-request`, `approvalsReviewer: user` und Gegenprüfung der Antwort (`CodexProtocol.swift:98-160`); Claude mit `--permission-mode manual --permission-prompt-tool stdio` (`ClaudeCodeCommand.swift:20-37`), Abbruch bei anderem `permissionMode` (`ClaudeCodeSession.swift:134-137`); verwalteter AGENTS.md-Block nicht destruktiv (ADR-0004) | `Packages/SoftwareRegisseurGit/Tests/.../WorktreeManagerTests.swift`; Agenten-Tests: neu für Argumentliste | ⚠️ **SR-SEC-03** teilweise: Claude mit `--setting-sources user --strict-mcp-config` (Erkennung verlangt die Flags), Codex mit `--disable hooks`; realer Spike und Codex-Projektkonfiguration offen. ✅ **SR-SEC-04**: Hooks bei jedem Dienst-Git-Aufruf aus (`GitClient.hardeningConfig`, Test `GitHardeningTests`) |
| B02 | **Prompt-Injection aus Markdown/Notizen/Repo** in KI-Ausarbeitung und Agenten-Prompt | KI: Nonce-begrenzte Datenblöcke, Neutralisierung von `<<<`/`>>>`, Sicherheitsregeln im Systemprompt, nur JSON-Ausgabe, keine Werkzeuge (`PromptSafety.swift:6-56`); Kontextfilter und Redaction (`AIContext.swift:129-133`, `RepoContextBuilder.swift:104-211`, Symlinks ausgeschlossen). Agent: Nonce-Begrenzung, Regeln vor und nach dem Datenblock (`AgentPromptBuilder.swift:37-90`). Keine Ausführung, nur weil Markdown es verlangt: Jobs entstehen nur durch Benutzeraktion | `Packages/SoftwareRegisseurAI/Tests/.../DraftAndConversationTests.swift`, `FilterAndCostTests.swift` | ⚠️ Prompt-Härtung ist heuristisch; ein Coding-Agent liest Repo-Dateien ohnehin selbst. Wirksame Grenze sind Freigaben und Sandbox, nicht der Prompt. **SR-SEC-12**: Agenten-Prompt wird nicht redigiert |
| B03 | **Shell-Injection** | Keine Shell: `posix_spawn` mit Argumentvektor, `POSIX_SPAWN_CLOEXEC_DEFAULT`, eigene Prozessgruppe, NUL-Prüfung (`ProcessExecution.swift:34-108`, `InteractiveProcess.swift:58-125`); `git -C <dir> … -- <pfad>`; Referenzen mit `refs/heads/`-Präfix bzw. `--end-of-options` (`WorktreeManager.swift:144-147`, `IntegrationService.swift:306-311`); Diff-Referenzen dürfen nicht mit `-` beginnen (`GitDiffLoader.swift:22-34`) | `Packages/SoftwareRegisseurProcess/Tests` (vorhanden laut Paketstruktur; nicht ausgeführt) | ✅ keine `sh -c`/`bash -c`-Stelle in den Quellen gefunden |
| B04 | **Path-Injection / Traversal / Symlinks** | `PathGuard` (realpath, keine `..` im neuen Teil, keine hängenden Symlinks, Wurzelprüfung; `PathGuard.swift:22-107`); iPhone-Projektanlage mit Symlink-Verbot je Komponente (`ProjectSetupService.swift:259-292`); `RelativePath` gegen `..`, absolute Pfade, `~`, Steuerzeichen (`Markdown/Layout/Paths.swift:20-42`); `AtomicFileWriter` ersetzt keinen Symlink als Ziel (`AtomicFileWriter.swift:33-38`) | `PathGuardTests.swift`, `CatalogAndSetupTests.swift`, `RequestMaterializerTests.swift` | ⚠️ **SR-SEC-07** teilweise: Workspace-Paket prüft jede Komponente (`SymlinkConfinementTests`); ADR-Schreibstellen im Dienst offen |
| B05 | **Unberechtigte CloudKit-Jobwünsche** (A-Dev) | Nur private DB und eigene Zone; Mac führt nur Projekte mit eigener `hostId` aus (`JobOrchestrator.swift:434-436`); Modell/Effort werden vor Start gegen frische Capability geprüft (`JobOrchestrator.swift:462-480`); Abhängigkeiten, Locks, Limits | `SchedulingTests.swift`, `TwoDeviceSyncTests.swift` | ✅ **SR-SEC-01/02** behoben (ADR-0026): Eigentumsprüfung beim Empfang, Pfade nur aus dem lokalen Index, Worktree host-berechnet (`RemoteOwnershipTests`, `OwnershipSyncTests`, `SecurityAuditJobTests`) |
| B06 | **Verlorene / abgeflossene API-Keys** | Keychain `AfterFirstUnlockThisDeviceOnly`, Data-Protection-Keychain am Mac, iCloud-Schlüsselbund nur per Opt-in (`SystemKeychainStore.swift:145-175`); Schlüssel nur im Header, nie in URL (z. B. `GeminiTextClient.swift:26-28`); `SecretGuard` blockiert ausgehende Sync-Payloads mit Schlüsselmaterial (`SyncRecordMapping.swift:176-181`); Payload in `encryptedValues` (`:196-200`); Löschung mit Vorschau und Einmal-Token (`LocalDataEraser.swift:58-138`) | `CloudDataDeletionTests.swift`, `DataPortabilityTests.swift`, Persistence `SyncHardeningTests.swift` | ⚠️ **SR-SEC-11**: Muster-Lücken in `SecretRedactor`/`SecretGuard` |
| B07 | **Git-Datenverlust** | Agent nur im Worktree; Übernahme in temporärem Worktree, Vorrücken per `update-ref <neu> <alt>` oder `merge --ff-only` nur bei sauberem Tree (`IntegrationService.swift:114-198`); `reset --hard`/`clean -fdq`/`worktree remove --force` nur für den eigenen temporären Worktree (`:294-304`); Worktree-Entfernung verweigert schmutzige Trees ohne `force` (`WorktreeManager.swift:163-178`); ADR-0024-Schutz nicht committeter Dokumente (`IntegrationService.swift:169-179`); Löschfunktionen schützen Repo- und Worktree-Pfade (`ServiceRuntime+DataDeletion.swift:37-50`) | `IntegrationServiceTests.swift`, `IntegrationDocumentPathsTests.swift`, `WorktreeManagerTests.swift`, `DataPortabilityTests.swift` | ✅ **SR-SEC-02** behoben (`verifyManagedWorktree`, `syncedWorktreePathIsIgnored`). ✅ **SR-SEC-06** behoben (`expectedJobTip`, `integrationRefusesMovedBranch`) |
| B08 | **Doppelte Agentenstarts** | Task-/Projekt-Lock mit Lease und Heartbeat, Freigabe nur nach geprüftem Prozessende (`JobOrchestrator.swift:611-620`, `attemptLockRelease`); Idempotenzschlüssel je Job; Inbox-Replay-Schutz (`SyncStore.swift:536-553`); Wiederaufnahme prüft Prozess und Worktree (`JobOrchestrator+Recovery.swift`) | `TaskLockRepositoryTests.swift`, `RecoveryAndIntegrationTests.swift`, `RunLifecycleTests.swift` | ✅ **SR-SEC-01** behoben: Lock-Records mit eigener `hostId` von anderen Geräten werden abgewiesen (`hostOwnedLocksCapabilitiesAndApprovalsAreRejected`) |
| B09 | **Approval-Missbrauch** (Auto-Freigabe, Replay, Freigabe für falsche Anfrage, verdeckter Befehl) | Keine automatische Zustimmung: Timeout pausiert (Standard 3600 s, `.pause`; `Configuration.swift:33-41`) oder bricht ab (`JobOrchestrator+Session.swift:187-190`); nicht unterstützte Agenten-Anfragen werden abgelehnt (`CodexSession.swift:196-202`, `ClaudeCodeSession.swift:182-188`); Entscheidung nur mit `.user`-Akteur (`JobOrchestrator+Control.swift:11-31`); genau eine Weiterleitung, geschlossene/abgelaufene Anfragen werden ignoriert (`Approvals.swift:113-116, 191-195`; `JobOrchestrator.swift:266-305`); UI ohne Standardantwort (`ApprovalCenter.swift:35-39, 74-84`); Vorschau redigiert (`JobOrchestrator+Session.swift:96-131`) | `RunLifecycleTests.swift`, `ContractTests.swift`, `PermissionAndConsentTests.swift` | ⚠️ **SR-SEC-08** teilweise: gekürzte Vorschau → am iPhone nur „Ablehnen“, „Erlauben“ nur am Mac nach Volltext-Bestätigung (Mac-UI offen). ✅ **SR-SEC-16** behoben. Restrisiko: jedes Gerät im Account darf freigeben |
| B10 | **Automatisches Pushen** | Kein `push` im Code des Dienstes (gelesene Git-Aufrufe in `IntegrationService`, `WorktreeManager`, `JobOrchestrator+Session`); Claude: `--disallowedTools "Bash(git push *)" "Bash(git push)"` (`ClaudeCodeCommand.swift:7`), keine `--bg`/Bypass-Flags (`:11-16`, Prüfung `:49-68`); Prompt verbietet Push (`AgentPromptBuilder.swift:63`); Codex braucht für Netz (Push) eine Freigabe, da `workspace-write` ohne Netz | Agenten-Tests (neu: Argumentliste) | ⚠️ Das Muster `git push` ist umgehbar (`git -C . push`, Alias, Skript). Die eigentliche Grenze ist die Freigabe jedes Bash-Befehls. Wird durch Projekt-`permissions.allow` ausgehebelt → **SR-SEC-03** |
| B11 | **Fehlerhafte Repo-Pfade** (Agent im falschen Repo, außerhalb der Stammordner) | Stammordner-Freigabe am Mac; `PathGuard` bei Projektanlage; Worktree-Basis außerhalb der Scan-Wurzeln und außerhalb des Repos (`WorktreeManager.swift:82-92, 136-139`) | `PathGuardTests.swift`, `WorktreeManagerTests.swift` | ✅ **SR-SEC-01** behoben: `repositoryURL(for:)` verlangt eigenen, kanonisch unveränderten Pfad in einem Stammordner (`locationOutsideRootsIsUnavailable`) |

### 5.2 Weitere Bedrohungen

| ID | Bedrohung | Gegenmaßnahme im Code | Test | Status / Befund |
|----|-----------|----------------------|------|-----------------|
| B12 | **XPC-Peer-Spoofing** (A-Team) | `XPCListener`/`XPCSession` mit `XPCPeerRequirement` in beide Richtungen, in allen Build-Konfigurationen (kein `#if DEBUG`-Bypass) (`ServiceXPC.swift:7-45, 123-131`) | `AgentServiceCoreTests.swift` (Dispatcher); Peer-Prüfung nur mit signierten Builds testbar | ⚠️ **SR-SEC-05**: nur `isFromSameTeam()`, ohne Signing-Identifier. Über XPC erreichbar sind u. a. eigene Programmpfade für Agenten (`ServiceRuntime+Settings.swift:99-120`) und Löschungen |
| B13 | **Bösartige Repo-Hooks / `core.fsmonitor` / Git-Konfiguration** | `-c core.fsmonitor=false` bei jedem Aufruf (`GitClient.swift:65`); `core.hooksPath=/dev/null` bei Übernahme (`IntegrationService.swift:145`) und Auto-Commit (`JobOrchestrator+Session.swift:255-258`); `--no-ext-diff` bei Diffs; `GIT_TERMINAL_PROMPT=0`, `GIT_EDITOR=true` (`GitClient.swift:40-50`) | `IntegrationServiceTests.swift` (Hooks-Fall prüfen) | ✅ **SR-SEC-04** behoben. ⚠️ **SR-SEC-10** teilweise: im Dienst neutralisiert (Filter/Merge-Treiber lokal, `--no-ext-diff --no-textconv`, keine Signatur); `GitDiffLoader` der Mac-App offen |
| B14 | **Symlink-Angriffe** | `PathGuard`, `lstat` für Zieldateien, Symlinks im Markdown-Scan und KI-Kontext übersprungen (`WorkspaceEnvironment.swift:184-205`, `RepoContextBuilder.swift:140-211`); Löschung entfernt Links, nie Ziele (`LocalDataEraser.swift:119-131`) | `PathGuardTests.swift`, `RequestMaterializerTests.swift` | ⚠️ **SR-SEC-07** teilweise (Workspace behoben, Dienst-ADR-Schreibstellen offen) |
| B15 | **Geheimnisse in Logs, Exporten, Sync-Payloads, Approval-Vorschauen, Reviews** | `ServiceLog`-Regel: Inhalte nur redigiert und `privacy: .private` (`ServiceLog.swift:7-31`); `SecretRedactor` für Git-Fehler, Approvals, Agenten-Zusammenfassung (`GitClient.swift:84,93`, `JobOrchestrator+Session.swift:101-131, 274-275`); `SecretGuard` vor dem Senden; Payload verschlüsselt | Persistence/Sync `SyncHardeningTests.swift`, AI `FilterAndCostTests.swift` | ⚠️ **SR-SEC-11**, **SR-SEC-18** (Log-Durchsicht unvollständig) |
| B16 | **Manipuliertes Sparkle-Update** (A-Upd) | `SURequireSignedFeed`, `SUVerifyUpdateBeforeExtraction`, `SUPublicEDKey` mit Längenprüfung, nur HTTPS, deaktiviert in Debug/ohne Team-ID/mit Platzhaltern (`SoftwareUpdater.swift:34-77`, `project.yml:183-191`); privater Schlüssel nur im Release-Keychain (`Scripts/make-appcast.sh`); `SUAutomaticallyUpdate = false` | `Apps/SoftwareRegisseur-macOS/Tests` (Verfügbarkeitslogik; nicht ausgeführt) | ✅; Restrisiko **SR-SEC-15** (Dienst-Neustart nach Update) |
| B17 | **CloudKit-Record-Injection durch anderes Gerät** (A-Dev) | Schema-/ID-Prüfung beim Dekodieren (`SyncRecordMapping.swift:220-267`), Payload-ID muss Entity-ID entsprechen (`SyncBookkeeping.swift:233-241`), Replay-Schutz, `executionHostWins` nur bei Konflikt (`MergePolicy.swift:17-29`) | `TwoDeviceSyncTests.swift`, `RecordMappingTests.swift` | ✅ **SR-SEC-01** behoben: Rollen-/Eigentumsprüfung beim Empfang (ADR-0026) |
| B18 | **Vererbte Umgebung der Agenten** (`ANTHROPIC_BASE_URL`, `CLAUDE_CODE_EFFORT_LEVEL`, `DYLD_*`, `GIT_DIR`, Tokens) | Leere Startumgebung + Whitelist + Deny-Liste (`AgentEnvironment.swift:13-45`, `ProcessEnvironment.swift:20-28`) | Agenten-Tests (vorhanden laut Spike; nicht ausgeführt) | ✅; Restrisiko: `env`-Block in `~/.claude/settings.json` |
| B19 | **Gefährliche Benutzer-`config.toml`** (`approval_policy="never"`, `danger-full-access`) | Explizite Overrides bei jedem `thread/start`; Abbruch, wenn Codex andere Werte meldet (`CodexProtocol.swift:98-160`); Effort `auto` auf Katalog-Standard festgelegt (`CodexAgentProvider.swift:259`) | Agenten-Tests (neu: Abweichung → Abbruch) | ✅ |
| B20 | **Missbrauch des eigenen Programmpfads** | Nur lokal über XPC setzbar, nie synchronisiert; Prüfung absolut, existiert, ausführbar (`ServiceRuntime+Settings.swift:99-120`; `ServiceRuntime+Commands.swift:354-356`) | `ServiceRuntimeTests.swift` | ✅ (hängt an B12) |
| B21 | **Kosten/Kontingent-Missbrauch** durch injizierte Jobwünsche | Plausibilitätsprüfung, Limits pro Projekt/Anbieter/global, `account/rateLimitResetCredit/consume` wird lokal verweigert (`JSONRPCConnection.swift:45`) | `SchedulingTests.swift` | ⚠️ Ein Gerät im Account kann beliebig viele gültige Jobs anlegen (by design) |
| B22 | **Datenexport/-löschung durch Fehlbedienung** | Zweistufig mit Vorschau, Einmal-Token, Ablauf 10 min, Repo-/Worktree-Pfade geschützt, laufende Agenten blockieren (`LocalDataEraser.swift:58-138`, `ServiceRuntime+DataDeletion.swift:87-99`) | `DataPortabilityTests.swift`, `CloudDataDeletionTests.swift` | ✅ |
| B23 | **Agent nutzt Freigabe, um aus der Sandbox in den Dienst zu wechseln** (Hook-Datei in `.git/hooks` des gemeinsamen Git-Verzeichnisses schreiben) | Codex `workspace-write` schützt das gemeinsame `.git` außerhalb des Worktrees; Claude fragt jeden Schreibzugriff ab | – | ✅ mit **SR-SEC-04** entschärft: Hooks laufen im Dienst nie |
| B24 | **Ausführbare Dateien aus benutzerbeschreibbaren Pfaden** | Feste Suchreihenfolge ohne Shell-`PATH` (`ExecutableLocator.swift:28-36`) | – | ⚠️ **SR-SEC-14** |

## 6. Restrisiken (bewusst getragen)

1. **Agenten laufen im Benutzerkontext.** Was der Benutzer freigibt, läuft mit seinen Rechten. Codex-Sandbox und Claude-Freigaben sind die einzige technische Grenze; Software Regisseur selbst hat keine Prozess-Sandbox für Agenten (ADR-0020, L3 „soweit technisch möglich“).
2. **Jedes Gerät im iCloud-Account ist gleichberechtigt** für Aufgaben, Job-Wünsche und Freigaben. Es gibt keine Gerätefreigabeliste. Ein verlorenes, entsperrtes iPhone kann Freigaben erteilen. Gegenmaßnahme für den Nutzer: Gerätesperre, Gerät aus der Apple-ID entfernen.
3. **Freigaben haben Minuten-Latenz** (Polling, ADR-0011, ADR-0023). Ein Agent wartet; die Timeout-Regel pausiert.
4. **Prompt-Härtung ist nicht beweisbar.** Modelle können Daten-Blöcke trotzdem als Anweisung lesen. Für KI-Ausarbeitung ist der Schaden begrenzt (nur JSON, keine Werkzeuge); für Coding-Agenten bleibt die Freigabe die Grenze.
5. **Redaction ist heuristisch** und kann unbekannte Token-Formate übersehen.
6. **Experimentelle Schnittstellen** (`codex app-server`, Claude-Steuerprotokoll über `--permission-prompt-tool stdio`) können sich ändern; Abweichungen führen zu Abbruch, nicht zu stillen Fallbacks.
7. **Benutzer-Konfiguration der Agenten** (`~/.claude/settings.json` mit `permissions.allow` oder `env`, `~/.codex/config.toml`-Profile, Plugins, MCP-Server) gilt weiter, soweit die Start-Flags sie nicht überschreiben.
8. **Repo-lokale Git-Konfiguration** von kopierten (nicht geklonten) Repos: Im Dienst sind Hooks, Filter-/Merge-Treiber der lokalen Konfiguration, externe Diffs, Textconv und Signatur abgeschaltet (SR-SEC-04/10). Restrisiko: andere programmstartende Optionen ohne Netzzugriff sind nicht bekannt; `GitDiffLoader` der Mac-App ist noch nicht gehärtet.
9. **Dienst-Neustart nach Sparkle-Update** ist nicht umgesetzt; der alte Dienst läuft bis zum Neustart weiter (SR-SEC-15).
10. **UI-Sandbox offen** bis zum Spike (ADR-0020).

## 7. Pflege

- Neue Befunde: im jeweils neuesten `audit-JJJJ-MM-TT.md` mit ID `SR-SEC-xx`; Status hier in Abschnitt 5 nachziehen.
- Jede Änderung an Agenten-Startargumenten, Git-Aufrufen, Sync-Entitäten oder XPC-Befehlen braucht einen Blick in Abschnitt 5.
- Nach Behebung eines Befunds: Test nennen, dann Status auf ✅ setzen. Ohne Testbeleg kein ✅ (AGENTS.md Nr. 10).
