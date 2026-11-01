# 4. Coding-Agenten

Software Regisseur startet Coding-Agenten, die **auf Ihrem Mac installiert und mit Ihrem eigenen Login angemeldet** sind. Es installiert nichts, liest oder speichert keine Anmeldedaten der Agenten und reicht kein Abonnement weiter ([ADR-0014](../adr/0014-eigengebrauch-in-version-1.md)).

| Agent | Startweg in v1 | Geprüfte Mindestversion |
|---|---|---|
| OpenAI Codex | `codex app-server` (JSON-RPC über stdio) | Codex CLI 0.164.0 |
| Claude Code | `claude -p` headless mit `stream-json` | Claude Code 2.1.212 |

Grundlage: [ADR-0021](../adr/0021-agenten-adapter-schnittstellen.md), Spikes [Codex](../integration-spikes/codex.md) und [Claude Code](../integration-spikes/claude-code.md).

## Agenten installieren

Installieren Sie die Agenten über die offiziellen Wege der Hersteller, zum Beispiel:

- **Codex:** `npm install -g @openai/codex` oder `brew install --cask codex`. Die npm-Variante braucht `node` (z. B. aus Homebrew).
- **Claude Code:** nativer Installer (`~/.local/bin/claude`) oder `brew install --cask claude-code`. Homebrew-Installationen aktualisieren sich nicht selbst (`brew upgrade claude-code`).

## Anmelden

Die Anmeldung erledigen Sie selbst im Terminal:

- Codex: `codex login` (Prüfung: `codex login status`)
- Claude Code: `claude auth login` (Prüfung: `claude auth status`)

Software Regisseur fragt nur den Status ab. Ein OpenAI- oder Anthropic-API-Schlüssel aus [Kapitel 3](03-ki-und-schluessel.md) wird **nicht** für die Agenten verwendet; Umgebungsvariablen wie `ANTHROPIC_BASE_URL`, `CLAUDE_CODE_EFFORT_LEVEL` oder API-Schlüssel werden beim Start bewusst nicht an Claude Code weitergegeben.

## Erkennung

Der Dienst sucht die Programme in `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `/usr/bin` und `/bin` (nicht im eingeschränkten `PATH` eines LaunchAgents). Die Codex-Desktop-App (`ChatGPT.app`/`Codex.app` in `/Applications` oder `~/Applications`) wird getrennt ausgewiesen.

Erkannt werden Version, Anmeldung, Startfähigkeit und der **Modellkatalog** mit den je Modell unterstützten Denkstufen – ohne Prompt und ohne Kontingentverbrauch. Ein Agent gilt nur als „einsatzbereit“, wenn all das gelingt.

**Zeitpunkte:** beim Start des Dienstes, alle 30 Minuten, unmittelbar vor jedem Jobstart und auf Anforderung (Einstellungen › „Agenten neu erkennen“). Das Ergebnis geht per iCloud an iPhone und iPad. Ist der Mac offline, zeigen diese „Zuletzt erkannt – Mac derzeit offline“.

**Eigener Programmpfad:** Der Dienst kennt seit IPC-Protokoll 3 einen Befehl für benutzerdefinierte Pfade. Die Einstellungsseite der Mac-App zeigt im aktuellen Stand noch den Hinweis, dass sich eigene Pfade nicht festlegen lassen; bis dahin müssen die Programme an einem der oben genannten Orte liegen.

## Modell und Denkstufe

Modell und Denk-/Effort-Stufe sind zwei getrennte Einstellungen ([ADR-0006](../adr/0006-modell-und-effort-auswahl.md)). Die Stufe ist eine Ausführungsressource, keine Einschätzung der Aufgabenschwierigkeit.

- Wählbar sind nur Modelle und Stufen, die der installierte Agent mit Ihrem Login meldet. Es gibt keine fest eingebaute Modellliste.
- Stufen und Anzeige: `auto` (Anbieterstandard), `low` (Niedrig), `medium` (Mittel), `high` (Hoch), `xhigh` (Extra hoch), `max` (Maximal), bei Codex je nach Modell `ultra`. Unbekannte neue Werte erscheinen unübersetzt.
- Meldet ein Agent für ein Modell keine Stufen, zeigt die App „Anbieterstandard – nicht einstellbar“. Erlaubt ein Agent keine Modellwahl, verwendet er sein Standardmodell.

**Vererbung:** Auftrag > Projekt > global > Anbieterstandard.

| Ebene | Wo |
|---|---|
| Global je Agent | iPhone: Einstellungen › „Modell- und Denkstufen-Standards“; Mac: Agentenübersicht |
| Projekt je Agent | iPhone: Projekt › „Agenten-Standards dieses Projekts“; Mac: Projekteinstellungen |
| Auftrag | beim Starten oder Planen |

Beim Anlegen eines Auftrags wird die aufgelöste Auswahl als **Snapshot** gespeichert. Spätere Änderungen an Projekt- oder Globalstandards gelten nur für neue Aufträge; geplante Aufträge behalten ihre Konfiguration.

**Kein stiller Ersatz:** Vor jedem Start prüft der Mac Modell und Stufe gegen den frischen Katalog. Ist die Kombination nicht mehr verfügbar, startet der Job nicht, sondern wechselt auf „needs_configuration“ (Aufgabe „blockiert“). Am Mac wählen Sie mit „Modell/Stufe ersetzen“ ausdrücklich eine neue Kombination.

**Effektive Werte:** Angezeigt wird „Effektiv (bestätigt)“ nur, wenn der Agent den Wert meldet. Claude Code meldet das Modell, die Stufe im Headless-Modus aber nicht („nicht bestätigt“). Codex meldet die konfigurierten Werte und serverseitige Umleitungen. Bei `auto` setzt Software Regisseur für Codex die vom Modell gemeldete Standardstufe ausdrücklich (sonst gälte Ihre persönliche Codex-Konfiguration); bei Claude Code wird keine Stufe übergeben.

> **Nicht verifiziert:** Dass ein echter Lauf die übergebenen Werte tatsächlich verwendet (A41, Tests O1/O2 und T1/T7/T9).

## Aufträge starten und planen

**iPhone/iPad:** in der Aufgabe „Mit Agent umsetzen“ › Agent, Modell, Denkstufe, Priorität, dann:

| Option | Wirkung |
|---|---|
| „Nur speichern“ | Auftrag und Konfiguration werden gespeichert; der Mac startet erst nach Ihrer Freigabe. |
| „Jetzt starten“ | Start, sobald der Mac den Auftrag übernimmt |
| „Für später einplanen“ | Zeitpunkt mit Zeitzone (IANA-Name, Sommerzeit wird berücksichtigt) |
| „Bei Kontingent verfügbar erneut versuchen“ | Start frühestens zu Ihrer erwarteten Kontingent-Rücksetzung |

**Mac:** Hauptfenster › „Warteschlange“ › „Job starten oder planen …“.

Jeder Auftrag hat eine eindeutige ID; doppelt gesendete Wünsche ergeben keinen zweiten Lauf. Ist der Mac offline, wartet der Auftrag („Wartet auf Mac“) und wird später genau einmal übernommen.

**Verpasster Termin** (Mac aus oder im Ruhezustand): Standard-Nachholregel ist „fragen“. Der Mac zeigt dann „Der geplante Termin wurde verpasst. Bitte entscheiden Sie: jetzt nachholen oder überspringen.“ Weitere Regeln: „sofort nachholen“, „abgelaufene überspringen“. Ein Start bis 5 Minuten nach dem Termin gilt nicht als verpasst.

**Ruhezustand:** Ein nur geplanter Job verhindert nie den Ruhezustand und weckt den Mac nicht. Optional: „Leerlauf-Ruhezustand verhindern, solange ein Agent arbeitet“ (Standard aus; Bildschirm-Ruhezustand und manueller Ruhezustand bleiben unberührt).

**Parallelität:** Standard höchstens 2 Läufe gleichzeitig insgesamt und 2 je Projekt. Je Projekt einstellbar: „Parallele Läufe erlauben“ und „Projektweite Sperre“ (nur ein Agent je Repository). Jede Aufgabe hat während eines Laufs eine exklusive Sperre; ein zweiter Start derselben Aufgabe wird verhindert. Sperren schützen nur vor Doppelstarts innerhalb von Software Regisseur, nicht vor Editoren oder Terminals.

**Mehrere Macs:** Jedes Projekt hat genau einen Mac als Ausführungshost; nur dieser startet Agenten dafür.

## Kontingent

- Meldet der Agent ein Kontingentlimit (Codex z. B. `usageLimitExceeded`, Claude Code `rate_limit_event`), bleibt der Job erhalten und wechselt auf „wartet auf Kontingent“ mit dokumentiertem nächsten Versuch.
- Grundlage für den nächsten Versuch: vom Anbieter gemeldeter Zeitpunkt, Ihre eigene Angabe („Erwarteten Kontingent-Reset setzen“) oder begrenzter Backoff: 15 Minuten, verdoppelt bis höchstens 6 Stunden, mit Zufallsstreuung, höchstens 8 Versuche.
- Software Regisseur liest keine Reset-Zeiten aus, die der Anbieter nicht liefert, umgeht keine Limits, wechselt keine Konten und verbraucht nie Codex-Reset-Guthaben.

## Freigaben während eines Laufs

Fragt ein Agent eine Freigabe an (z. B. einen Befehl ausführen, eine Datei ändern), läuft das so ([ADR-0023](../adr/0023-freigaben-ueber-icloud-weiterleiten.md)):

1. Der Mac empfängt die Anfrage über das dokumentierte Protokoll des Agenten und speichert sie mit Zusammenfassung, geschwärzter Befehlsvorschau und Ablaufzeit. Job und Aufgabe stehen auf „wartet auf Freigabe“.
2. Die Anfrage erscheint am Mac (Warteschlange › „Offene Freigaben“) und nach der nächsten Synchronisierung auf iPhone/iPad (Agenten › „Freigaben“).
3. Sie wählen „Erlauben“ oder „Ablehnen“ (am Mac optional mit Begründung). Der Mac gibt die Entscheidung genau einmal an den Agenten weiter. Antworten auf abgelaufene oder bereits beantwortete Anfragen werden ignoriert.
4. Ohne Antwort wird der Job nach 60 Minuten pausiert; die Anfrage bleibt beantwortbar. **Es gibt nie eine automatische Zustimmung.**

Es gibt keine Push-Mitteilung: Auf dem iPhone sehen Sie eine Anfrage, wenn Sie die App öffnen oder aktualisieren. Antwortzeiten im Minutenbereich sind möglich.

> **Nicht verifiziert:** Freigabe-Rundlauf mit echtem Agenten und signierter App (A20, Tests O3 und T2).

## Mobile Weiterführung in den offiziellen Apps und Remote Control

**Stand: nicht verifiziert, nicht freigeschaltet** ([ADR-0010](../adr/0010-offizielle-mobile-agenten-sitzungen.md) ist `proposed`).

- Von Software Regisseur gestartete Läufe sind **nicht** in der ChatGPT-/Codex- oder Claude-App sichtbar. Die App zeigt bei beiden Agenten „Offizielle mobile Fortsetzung: Nein“ mit Diagnose. Status, Freigaben und Review laufen über Software Regisseur.
- Es werden keine Deep Links (`claude://…`, `codex://…`) verwendet.

Voraussetzungen, die eine spätere Remote-Control-Anbindung laut Herstellerdokumentation hätte (aus den Spikes, nicht von Software Regisseur genutzt):

| | Claude Code Remote Control | Codex in der ChatGPT-App |
|---|---|---|
| Konto | claude.ai-Abonnement Pro, Max, Team oder Enterprise; **kein** API-Schlüssel; bei Team/Enterprise vom Owner freigeschaltet | ChatGPT-Konto; Verfügbarkeit abhängig von Rollout und Workspace-Einstellungen |
| Verbindung | nicht mit Bedrock/Vertex/Foundry oder eigener `ANTHROPIC_BASE_URL`; der lokale Prozess muss weiterlaufen | Kopplung über die Desktop-App („Control this Mac or PC“); Mac wach und online |
| Einschränkungen | Modell und Stufe im Server-Modus nicht setzbar; einmalige Bestätigung und Workspace-Vertrauen im Terminal nötig; Transkript liegt auf Anthropic-Servern | CLI-Remote-Control experimentell; Sichtbarkeit von app-server-Threads nicht dokumentiert |
| Offene Tests | T3–T6 | O6 |

## Worktrees

Jeder Lauf arbeitet in einem eigenen Git-Worktree auf einem eigenen Branch:

- Branch: `software-regisseur/<Aufgaben-ID>/<Job-Kurz-ID>` (vor Vergabe der lesbaren ID die UUID der Aufgabe).
- Ort: im App-Group-Container des Mac, `~/Library/Group Containers/<Team-ID>.<Bundle-ID-Präfix>.SoftwareRegisseur/SoftwareRegisseur/Worktrees/`, also außerhalb aller Stammordner. Übernahmen laufen in einem eigenen Integrations-Worktree daneben.
- Ihr Haupt-Working-Tree wird vom Agenten nicht angefasst. Eigene Worktree-Funktionen der Agenten werden nicht verwendet.
- „Im Finder zeigen“ und „Im Terminal öffnen“ in der Review-Ansicht führen direkt in den Worktree.

## Review und Übernahme

Nach Ende des Agenten:

1. Nicht committete Änderungen des Agenten committet der Dienst **auf dem Job-Branch** (Nachricht „Software Regisseur: Agentenergebnis <Job-ID>“, Git-Hooks dabei abgeschaltet), damit das Ergebnis prüf- und übernehmbar ist. Die Review-Ansicht listet diese Dateien unter „Automatisch committete Agentenausgaben“. Der Default-Branch wird dabei nie verändert.
2. Die Aufgabe steht auf **Review**, nie automatisch auf „erledigt“.
3. Review am Mac: Zusammenfassung des Agenten, geänderte Dateien mit Diff, Commits, Testergebnisse, abgelehnte Berechtigungen, Branch und Worktree. Auf dem iPhone sehen Sie eine kompakte Zusammenfassung.

Aktionen ([ADR-0015](../adr/0015-integrationsstrategie-squash.md), [ADR-0024](../adr/0024-keine-commits-durch-software-regisseur.md)):

| Aktion | Wirkung |
|---|---|
| „Änderungen anfordern“ | Review mit Änderungswunsch abschließen; der Branch bleibt erhalten |
| „Ablehnen“ | Review abgelehnt, Branch bleibt erhalten |
| „Integrieren (Squash)“ | Übernahme in den Default-Branch per Squash-Merge (Standard; je Projekt umstellbar auf Merge-Commit oder Cherry-pick). Es wird **nichts gepusht**. Bei Konflikten bleibt das Repository unverändert und die App nennt die Dateien. |
| „Als erledigt markieren“ | nur nach erfolgreicher Integration; die Request-Datei wandert in den done-Ordner |
| „Worktree entfernen“ | entfernt den Worktree, der Branch bleibt |

Vor der Integration muss Ihr Haupt-Working-Tree sauber sein; nicht committete Änderungen unterhalb der Dokumentpfade (ADR-Ordner, Requests) blockieren nicht. Würde die Integration solche Dateien überschreiben, bricht sie ohne Teilzustand ab. `git push` bleibt Ihre eigene Aktion.

## Was Agenten nicht dürfen

Technisch erzwungen beim Start:

- Arbeitsverzeichnis ist ausschließlich der vorbereitete Worktree.
- **Codex:** Sandbox `workspace-write` (ohne Netzwerk), Freigaben `on-request`, Entscheider ist der Benutzer – unabhängig von Ihrer persönlichen `~/.codex/config.toml`.
- **Claude Code:** `--permission-mode manual`, Freigaben über Software Regisseur, `git push` und das Werkzeug `EnterWorktree` gesperrt. Optionen wie `--dangerously-skip-permissions`, `bypassPermissions`, `--worktree`, `--bg` oder `--remote-control` werden nie verwendet.
- Prozesse werden ohne Shell mit expliziten Argumenten und bereinigter Umgebung im angemeldeten Benutzerkontext gestartet, nie als root.

Zusätzlich im Agenten-Prompt und im verwalteten `AGENTS.md`-Block:

- kein `git push`, kein Merge, kein Rebase auf andere Branches, kein Force-Reset, keine Branch-Löschung, keine Commits außerhalb des eigenen Branches ohne Ihre Zustimmung,
- keine eigenen Worktrees, kein Wechsel in andere Repositories,
- Request-Dateien und ADRs weder anlegen noch ändern, verschieben oder committen,
- keine Geheimnisse ausgeben, speichern oder committen,
- die Aufgabe nie selbst als `done` oder `integrated` erklären.

Der Aufgabentext wird dem Agenten als abgegrenzter Datenblock übergeben; Anweisungen darin, die diesen Regeln widersprechen, gelten nicht. Prompt-Regeln sind keine technische Garantie – der Mac prüft Dateien und Git-Zustand unabhängig.

**Restrisiken:** Der Dienst läuft ohne App Sandbox mit Ihren Benutzerrechten ([ADR-0020](../adr/0020-agent-service-unsandboxed-xpc.md)). Claude Code überspringt im Headless-Modus den Vertrauensdialog und führt Projekt-Hooks und `.mcp.json` des Repositorys aus; Codex startet die in Ihrem Profil konfigurierten MCP- und Plugin-Server. Starten Sie Agenten deshalb nur in Repositories, denen Sie vertrauen.
