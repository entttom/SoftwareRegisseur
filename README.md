# Software Regisseur 1.0

Software Regisseur ist eine native, über iCloud synchronisierte Schaltzentrale für iPhone, iPad und Mac: Sie erfassen Ideen unterwegs per Text oder Diktat, lassen sie mit eigenen API-Schlüsseln von einer KI zu Aufgaben oder ADRs ausarbeiten und von den auf Ihrem Mac installierten Coding-Agenten (OpenAI Codex, Claude Code) in isolierten Git-Worktrees umsetzen – sofort, zeitgesteuert oder nach Kontingent-Rücksetzung, mit Freigaben, Review und nachvollziehbarer Übernahme. Die Mac-App lebt in der Menüleiste; ein eigener Hintergrunddienst führt Git- und Agentenarbeit aus. Aufgaben und ADRs bleiben als menschenlesbares Markdown in Ihren Repositories. Entwickelt wird mit Claude Code; die Spezifikation ist historisch an Codex adressiert, gilt aber unverändert für jeden Implementierungs-Agenten.

## Stand von Version 1.0 (ehrlich)

- **Implementiert:** iOS-/iPadOS-App, macOS-Menüleisten-App, Agent Service und alle gemeinsamen Pakete unter `Packages/` sind vorhanden, bauen unsigniert (`Scripts/build.sh`) und haben automatisierte Tests (`Scripts/test.sh`, CI unter `.github/`).
- **Abnahme:** Alle Kriterien A01–A42 stehen in der [Abnahmematrix](docs/acceptance/abnahmematrix.md) noch auf `offen`. Ohne konkreten Beleg gilt nichts als bestanden.
- **Nicht verifiziert – mobile Weiterführung:** Ob ein von Software Regisseur gestarteter Agentenlauf in der offiziellen ChatGPT-/Codex- oder Claude-App weitergeführt werden kann, ist nicht nachgewiesen ([ADR-0010](docs/adr/0010-offizielle-mobile-agenten-sitzungen.md) ist `proposed`). Der umgesetzte V1-Weg: Status und Freigaben laufen über Software Regisseur auf Mac und iPhone ([ADR-0023](docs/adr/0023-freigaben-ueber-icloud-weiterleiten.md)). Es werden keine Deep Links in die offiziellen Apps verwendet.
- **Echte Agentenläufe** mit Kontingentverbrauch (Spike-Tests O1–O7 für Codex, T0–T9 für Claude Code) stehen aus; Modellkatalog-Abfrage und Startparameter sind nur ohne Prompt bzw. per Unit-Test geprüft.
- **Signierter Build nötig:** iCloud-Synchronisierung (CloudKit), Registrierung des Hintergrunddienstes als Login-Agent, die XPC-Verbindung zwischen App und Dienst und die gemeinsame Schlüsselbund-Gruppe funktionieren nur in Builds, die mit Ihrem eigenen Apple-Developer-Team signiert sind. Unsignierte Prüf-Builds starten, melden diese Funktionen aber als nicht verfügbar.
- **Notarisierung ausstehend:** Die Release-Skripte für Developer-ID-Signierung, Notarisierung und Sparkle-Appcast existieren; ein notarisierter Release wurde noch nicht erstellt, weil dafür das Notarisierungsprofil des Benutzers im Schlüsselbund fehlt (siehe [Release-Anleitung](docs/release/README.md)).

Details zu Grenzen: [Handbuch, Kapitel 7](docs/handbuch/07-grenzen-und-faq.md).

## Repository-Aufbau

| Pfad | Inhalt |
|---|---|
| `Software_Regisseur_1.0_Codex_Entwicklungsauftrag.md` | Verbindliches Pflichtenheft (Version-1.0-Spezifikation) mit 42 Abnahmekriterien |
| `AGENTS.md` | Unmittelbar für Coding-Agenten gültige Arbeitsanweisungen |
| `CLAUDE.md` | Bindet `AGENTS.md` für Claude Code ein (`@AGENTS.md`) |
| `project.yml` | XcodeGen-Spezifikation; erzeugt das nicht eingecheckte `SoftwareRegisseur.xcodeproj` ([ADR-0022](docs/adr/0022-xcodegen-projekt-statt-workspace.md)) |
| `Config/` | `Base/Debug/Release.xcconfig`; `Local.xcconfig.template` als Vorlage für Team-ID, Bundle-ID-Präfix, CloudKit-Container und Sparkle-Werte – nach `Config/Local.xcconfig` kopieren und ausfüllen; diese Datei wird nicht eingecheckt ([ADR-0013](docs/adr/0013-mindestversionen-und-lokale-signierkonfiguration.md)) |
| `Apps/SoftwareRegisseur-iOS/` | Universal-App für iPhone und iPad: Erfassung, Diktat, KI-Ausarbeitung, Agentenaufträge, Freigaben, Review-Zusammenfassung |
| `Apps/SoftwareRegisseur-macOS/` | Menüleisten-App mit Hauptfenster (Dashboard, Projekte, Aufgaben, ADRs, Agenten, Warteschlange, Review, Historie, Einstellungen) |
| `Services/SoftwareRegisseurAgentService/` | Hintergrunddienst (LaunchAgent über `SMAppService`, ohne Sandbox): Scanner, Markdown, Jobs, Agenten, Git, CloudKit-Sync; einziger Schreiber der Mac-Datenbank ([ADR-0019](docs/adr/0019-persistenz-grdb-einzelner-schreiber.md), [ADR-0020](docs/adr/0020-agent-service-unsandboxed-xpc.md)) |
| `Packages/SoftwareRegisseurDomain` | Domänenmodelle, getrennte Zustandsmaschinen für Projekt/Aufgabe/Job, Zeitplanung, Kontingent-Backoff, Modell-/Effort-Vererbung |
| `Packages/SoftwareRegisseurPersistence` | Lokale GRDB-/SQLite-Datenbank mit Migrationen, Repositories und Sync-Ablage |
| `Packages/SoftwareRegisseurSync` | CloudKit-Synchronisierung über `CKSyncEngine` mit Polling, Drei-Wege-Merge und Geheimnis-Sperre |
| `Packages/SoftwareRegisseurMarkdown` | Frontmatter-, Request- und ADR-Format, konfigurierbare Ordnerstruktur, verwalteter `AGENTS.md`-Block |
| `Packages/SoftwareRegisseurWorkspace` | Stammordner-Scan, Projektkatalog, Dateiüberwachung und Reconciliation, Anweisungsdateien, Ordnermigration, Repo-Kontext, GitHub über `gh`, Projekteinrichtung |
| `Packages/SoftwareRegisseurGit` | Git über explizite Prozessaufrufe: Status, Worktrees, Diffs, Integration (Squash, Merge-Commit, Cherry-pick) |
| `Packages/SoftwareRegisseurProcess` | Prozessausführung ohne Shell, Programmsuche (`/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, …) |
| `Packages/SoftwareRegisseurAgents` | Adapter für Codex (`app-server`) und Claude Code (headless `stream-json`): Erkennung, Modellkatalog, Start, Freigaben, Agenten-Prompt |
| `Packages/SoftwareRegisseurJobs` | Job-Orchestrator: Warteschlange, Locks, Worktrees, Zeitplan, Kontingent, Freigaben, Recovery, Review-Erfassung |
| `Packages/SoftwareRegisseurAI` | KI-Textausarbeitung (OpenAI, Anthropic, Gemini), OpenAI-Transkription, Kostenschätzung, Geheimnisfilter für Kontext |
| `Packages/SoftwareRegisseurSecrets` | Schlüsselbund-Zugriff, gerätebezogen oder auf Wunsch mit iCloud-Schlüsselbund |
| `Packages/SoftwareRegisseurAppCore` | Gemeinsame App-Logik für iOS und Mac: API-Schlüssel, Entwürfe, Gespräche, Auftragserstellung, Freigaben, Datenportabilität |
| `Packages/SoftwareRegisseurIPC` | XPC-Vertrag zwischen Mac-App und Agent Service ([Paket-README](Packages/SoftwareRegisseurIPC/README.md)) |
| `Packages/SoftwareRegisseurPortability` | Datenexport (JSON, Markdown, ZIP) und kontrolliertes Löschen mit Vorschau |
| `Scripts/` | `build.sh`, `test.sh`, `sync-string-catalogs.sh`, Release-Skripte (`release.sh`, `sign-and-notarize.sh`, `make-appcast.sh`, `sparkle-keys.sh`, `verify-release.sh`), Build-Phasen (`check-signing-config.sh`, `embed-launchd-plist.sh`) |
| `docs/adr/` | `README.md` (ADR-Index und Statuslogik), `TEMPLATE.md` (Vorlage für neue Architekturentscheidungen), `0001-*.md` ff. (Architekturentscheidungen) |
| `docs/acceptance/abnahmematrix.md` | Prüfstand der Abnahmekriterien A01–A42 |
| `docs/integration-spikes/` | Protokolle der Machbarkeitsprüfungen (M0): Apple-Plattform, Codex, Claude Code, KI-Anbieter |
| `docs/release/` | macOS-Release, Notarisierung, Sparkle-Updates |
| `docs/handbuch/` | Benutzerhandbuch |
| `docs/security/` | Bedrohungsmodell |
| `docs/brand/` | Logo und App-Symbole |
| `.github/` | CI-Workflow (Paket-Tests, unsignierte App-Builds) |

## Voraussetzungen

- **Mac:** Apple Silicon, macOS 26 oder neuer (Intel ist nicht getestet).
- **Mobil:** iPhone oder iPad mit iOS/iPadOS 26 oder neuer.
- **Entwicklung:** Xcode 27 (Swift 6.4), [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- **Für signierte Builds:** Mitgliedschaft im Apple Developer Program, ein eigener CloudKit-Container und auf allen Geräten derselbe iCloud-Account.
- **Für Agentenläufe:** Codex CLI und/oder Claude Code CLI auf dem Mac, mit Ihrem eigenen Login angemeldet.

## Schnellstart für Entwickler

```sh
cp Config/Local.xcconfig.template Config/Local.xcconfig   # Werte eintragen, Datei nie committen
xcodegen generate                                         # erzeugt SoftwareRegisseur.xcodeproj aus project.yml
Scripts/build.sh                                          # beide Apps unsigniert bauen, Bundle-Layout prüfen
Scripts/test.sh                                           # swift test je Paket + Xcode-Testtargets
Scripts/sync-string-catalogs.sh                           # UI-Strings in die String Catalogs übernehmen
```

- Einzelne Pakete testen Sie mit `swift test` im jeweiligen Paketordner.
- `Scripts/build.sh` und `Scripts/test.sh` brechen mit Hinweis ab, wenn `Config/Local.xcconfig` fehlt. Mit den Vorlagenwerten laufen unsignierte Builds; signierte Builds verweigert die Build-Phase „Signierkonfiguration prüfen“, solange Platzhalter eingetragen sind.
- Für signierte Builds `SoftwareRegisseur.xcodeproj` in Xcode öffnen und die Schemata `SoftwareRegisseur-macOS` bzw. `SoftwareRegisseur-iOS` mit Ihrem Team ausführen. Projektänderungen erfolgen ausschließlich in `project.yml`.
- Releases der Mac-App: [docs/release/README.md](docs/release/README.md).

## Dokumentation

| Thema | Dokument |
|---|---|
| Pflichtenheft | [Software_Regisseur_1.0_Codex_Entwicklungsauftrag.md](Software_Regisseur_1.0_Codex_Entwicklungsauftrag.md) |
| Architekturentscheidungen | [docs/adr/README.md](docs/adr/README.md) |
| Handbuch (Installation, Einrichtung, Schlüssel, Agenten, Synchronisierung, Datenschutz, Grenzen, FAQ) | [docs/handbuch/README.md](docs/handbuch/README.md) |
| Release, Signierung, Notarisierung, Updates | [docs/release/README.md](docs/release/README.md) |
| Sicherheit | [Bedrohungsmodell](docs/security/bedrohungsmodell.md); für Benutzer: [Handbuch, Kapitel 6](docs/handbuch/06-datenschutz.md) und [Kapitel 4, Abschnitt „Was Agenten nicht dürfen“](docs/handbuch/04-agenten.md#was-agenten-nicht-dürfen) |
| Abnahme | [docs/acceptance/abnahmematrix.md](docs/acceptance/abnahmematrix.md) |
| Machbarkeitsprüfungen | [Apple-Plattform](docs/integration-spikes/apple-platform.md), [Codex](docs/integration-spikes/codex.md), [Claude Code](docs/integration-spikes/claude-code.md), [KI-Anbieter](docs/integration-spikes/ai-providers.md) |
| XPC-Vertrag Mac-App ↔ Dienst | [Packages/SoftwareRegisseurIPC/README.md](Packages/SoftwareRegisseurIPC/README.md) |
| CI | [.github/README.md](.github/README.md) |

## Regeln für Mitwirkende

Verbindlich ist [AGENTS.md](AGENTS.md); Claude Code lädt sie über `CLAUDE.md`. Kurzfassung:

1. Implementierungs-Agent im Repository öffnen; er liest zuerst `AGENTS.md`, das Pflichtenheft und die ADRs (alle `accepted`-ADRs vor Architekturänderungen).
2. Begonnen wurde mit M0 (technische Machbarkeitsprüfungen); danach werden sämtliche v1-Funktionen implementiert. Es gibt keinen funktionsreduzierten MVP.
3. Keine Schlüssel, Team-Zertifikate, Team-IDs oder Geräteinformationen in das Repository committen. Echte Werte stehen nur in `Config/Local.xcconfig`.
4. Neue wesentliche Entscheidungen mit `docs/adr/TEMPLATE.md` festhalten; `accepted`-ADRs nur durch einen neuen ADR ablösen.
5. Ergebnisse in der Abnahmematrix nur mit konkretem Testbeleg als bestanden ausweisen; unbelegte Integrationen offen kennzeichnen.
6. Ohne Zustimmung kein `git push`, kein Force-Reset, keine ungeschützten Shell-Kommandos.

Verbindliche Produktentscheidung: **Keine Verschiebung von bereits bestätigten Anforderungen in eine spätere Version.**
