# ADRs – Software Regisseur

In diesem Ordner werden **Architekturentscheidungen und verbindliche technische Produktgrundsätze** seit Projektbeginn versioniert.

- `accepted`: angenommene, verbindliche Entscheidung; Änderungen per neuem ADR mit `supersedes`-Verweis.
- `proposed`: ernsthaft vorgesehen, aber erst nach einem technischen Spike endgültig zu entscheiden.
- `deprecated` / `superseded`: historisch, nicht löschen.

Maßgeblich ist das Feld `status` im YAML-Frontmatter. Die `**Status:**`-Zeile im Text ist nur eine Lesehilfe und wird bei jeder Statusänderung im selben Commit mit angepasst.

Jeder neue relevante Architekturentscheid erhält die nächste freie Nummer und verwendet `TEMPLATE.md`. Nicht jede Todo- oder Feature-Idee ist ein ADR. Die fachliche Produkt-Spezifikation bleibt im Pflichtenheft; die ADRs dokumentieren das *Warum* und die wesentlichen technischen Festlegungen.

## Entscheidungen

| ADR | Titel | Status |
|---|---|---|
| [0001](./0001-version-1-vollumfang-und-adr-governance.md) | Version 1.0 ist vollständig; ADR-Verfahren | `accepted` |
| [0002](./0002-native-apple-menuleiste-hintergrunddienst.md) | Native iOS-App und macOS-Menüleisten-App mit Hintergrunddienst | `accepted` |
| [0003](./0003-git-markdown-und-cloudkit.md) | Git/Markdown als langlebige Projektartefakte; CloudKit für Synchronisierung | `accepted` |
| [0004](./0004-konfigurierbare-verzeichnisse-und-agentenanweisungen.md) | Konfigurierbare Markdown-Pfade und dynamische Agentenanweisungen | `accepted` |
| [0005](./0005-dynamische-coding-agenten-provider.md) | Coding-Agenten automatisch erkennen und mobil auswählbar machen | `accepted` |
| [0006](./0006-modell-und-effort-auswahl.md) | Freie Modellwahl und Denk-/Effort-Stufen je Coding-Agent | `accepted` |
| [0007](./0007-job-queue-locks-worktrees-review.md) | Persistente Agentenwarteschlange, exklusive Locks, Worktrees und Review | `accepted` |
| [0008](./0008-diktat-ki-byok-geraeteunabhaengig.md) | Diktat und KI-Ausarbeitung auf iOS mit eigenen API-Keys | `accepted` |
| [0009](./0009-direktvertrieb-signierung-sandbox-prufung.md) | Direktvertrieb als Developer-ID-signierte und notarisierte macOS-App | `accepted` |
| [0010](./0010-offizielle-mobile-agenten-sitzungen.md) | Offizielle mobile Codex-/Claude-Steuerung bevorzugen | `proposed` |
| [0011](./0011-cloudkit-ohne-sichtbare-push-benachrichtigungen.md) | CloudKit-Synchronisierung ohne sichtbare Push-Benachrichtigungen | `accepted` |
| [0012](./0012-getrennte-status-zustandsmaschinen.md) | Getrennte Zustandsmaschinen für Projekt, Aufgabe und Agentenjob | `accepted` |
| [0013](./0013-mindestversionen-und-lokale-signierkonfiguration.md) | Mindestversionen iOS 26 / macOS 26; Signier- und CloudKit-IDs in lokaler xcconfig | `accepted` |
| [0014](./0014-eigengebrauch-in-version-1.md) | Version 1.0 für Eigengebrauch; Vertrieb an Dritte nur per neuem ADR | `accepted` |
| [0015](./0015-integrationsstrategie-squash.md) | Squash-Merge als Standard-Integration, pro Projekt wählbar | `accepted` |
| [0016](./0016-github-ueber-gh-cli-lokal-fuehrend.md) | GitHub Issues über das gh-Login; lokale Request-Datei ist führend | `accepted` |
| [0017](./0017-sparkle-updates.md) | Mac-Updates über Sparkle mit EdDSA-Signatur | `accepted` |
| [0018](./0018-menschenlesbare-ids-vom-mac.md) | Menschenlesbare Aufgaben-IDs vergibt ausschließlich der Mac-Host | `accepted` |
| [0019](./0019-persistenz-grdb-einzelner-schreiber.md) | Lokale Persistenz mit GRDB (SQLite); Agent Service ist einziger Schreiber am Mac | `accepted` |
| [0020](./0020-agent-service-unsandboxed-xpc.md) | Agent Service als unsandboxed SMAppService-Agent mit XPC; UI-Sandbox nach Spike | `accepted` |
| [0021](./0021-agenten-adapter-schnittstellen.md) | Agenten-Adapter: Codex über app-server, Claude Code headless über stream-json | `accepted` |
| [0022](./0022-xcodegen-projekt-statt-workspace.md) | Xcode-Projekt aus XcodeGen-Spezifikation mit lokalen Swift Packages | `accepted` |
| [0023](./0023-freigaben-ueber-icloud-weiterleiten.md) | Agenten-Freigaben werden vom Mac über iCloud an das iPhone weitergeleitet | `accepted` |
| [0024](./0024-keine-commits-durch-software-regisseur.md) | Software Regisseur committet Request- und ADR-Dateien nie selbst | `accepted` |
| [0025](./0025-ipad-unterstuetzung.md) | Die iOS-App unterstützt iPhone und iPad | `accepted` |
| [0026](./0026-geraete-eigentum-host-pfade-job-branch-commits.md) | Geräte-Eigentum synchronisierter Daten, vom Mac berechnete Pfade und Commits auf dem Job-Branch | `accepted` |
| [0027](./0027-cloudkit-immer-production.md) | Alle Builds verwenden die CloudKit-Umgebung Production | `accepted` |
| [0028](./0028-ordnertiefe-und-ordnerindex-in-icloud.md) | Einstellbare Ordnertiefe; entfernte Ordner-Einträge werden in iCloud gelöscht | `accepted` |

## Arbeitsregel für Implementierungs-Agenten

Zuerst `AGENTS.md` und das Pflichtenheft lesen, dann alle `accepted`-ADRs. `proposed`-ADRs nach technischen Tests entscheiden; niemals stillschweigend akzeptieren. Neue fundamentale Architekturentscheidung = eigener ADR, nicht nur eine Chat-Antwort.
