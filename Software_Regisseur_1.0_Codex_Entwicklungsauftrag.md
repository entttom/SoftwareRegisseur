# Software Regisseur 1.0
## Verbindliches Pflichtenheft, Architektur und Entwicklungsauftrag für OpenAI Codex

**Stand:** 30. Oktober 2026  
**Produktname:** Software Regisseur  
**Plattformen:** iOS (iPhone und iPad, ADR-0025), macOS (native Menüleisten-App mit Hauptfenster und Hintergrunddienst)  
**Dokumentstatus:** Verbindliche Produktspezifikation für **Version 1.0**  
**Adressat:** Codex als verantwortlicher Implementierungs-Agent, bei Bedarf mit spezialisierten Subagenten  
**Sprache:** Benutzeroberfläche primär Deutsch (Österreich), Architektur und Code dürfen Englisch verwenden

> **Wichtigster Produktbeschluss:** **Alle in diesem Dokument beschriebenen Funktionen gehören zu Version 1.0.** Es gibt keinen bewusst funktionsreduzierten MVP und keine pauschale Verschiebung wesentlicher Features auf „später“. Die Implementierung darf intern in nachvollziehbare Meilensteine gegliedert werden; das v1.0-Abnahmekriterium bleibt der vollständige, integrierte Funktionsumfang. Externe API- oder Lizenzgrenzen dürfen nicht durch erfundene Möglichkeiten umgangen werden. Sie sind früh nachzuweisen, sauber zu dokumentieren und mit den im Dokument beschriebenen transparenten Fallbacks zu behandeln.

---

# A. Direktauftrag an Codex

Du bist leitender Softwarearchitekt und Implementierungs-Agent für **Software Regisseur**. Erstelle aus dieser Spezifikation ein produktionsreifes, vollständig natives Apple-Softwareprojekt mit iOS-App, macOS-Menüleisten-App, Hintergrunddienst, gemeinsamem Domain-/Sync-/Provider-Layer, Tests, Setup-Anleitung, Build-/Release-Skripten und überprüfbaren Integrationen.

## Verbindliche Arbeitsweise

1. **Bestandsaufnahme zuerst.** Falls ein Repository bereits existiert: vorhandene Architektur, Projektdateien, Signierung, Tests und offene Issues prüfen. Nichts ungefragt überschreiben. Falls keines existiert: eine saubere neue Monorepo-Struktur mit Xcode-Projekt/Workspace aufsetzen.
2. **Aktuelle Herstellerdokumentation prüfen**, besonders Apple (SwiftUI, CloudKit, Background Services, Sandbox, Notarisierung), OpenAI (Codex app-server/SDK/CLI, Speech-to-Text), Anthropic (Claude Code/Remote Control/SDK/kommerzieller Einsatz) und Google (Gemini API). Versionen und Fähigkeiten können sich ändern. Keine undokumentierten CLI-Flags oder mobilen Deep Links erfinden.
3. **Echte Implementierung statt Mockup.** Nach dem UI-Gerüst realen Datenfluss, lokale Persistenz, Synchronisierung, Dateiverarbeitung, Agentenprozesse und Testfälle anschließen. Keine leeren Buttons, Schein-APIs oder dauerhaften TODO-Platzhalter für v1.0-Funktionen.
4. **Sicherheit vor Komfort:** keine Geheimnisse in Logs, Git, Markdown oder CloudKit; kein heimliches Pushen/Committen; keine Shell-Injection; keine unbeschränkten Agentenrechte ohne explizite Zustimmung.
5. **Architekturentscheidungen als ADRs dokumentieren.** Die mitgelieferten Ausgangs-ADRs unter `docs/adr/` vor der Implementierung vollständig lesen. `accepted`-Entscheidungen respektieren, `proposed`-Entscheidungen technisch prüfen und bei grundlegenden Änderungen neue ADRs mit Verknüpfung anlegen. Kein stilles Umschreiben angenommener ADRs.
6. **Tests laufend ausführen.** Unit-, Integrations-, UI- und End-to-End-Tests; Fehler tatsächlich beheben. Build- und Releaseprozesse reproduzierbar machen.
7. **Arbeit in Modulen/Subagenten organisieren**, soweit verfügbar: Apple UI/UX, CloudKit und Persistenz, Git/Dateisystem, Agenten-Anbindung, Audio/KI, Sicherheit/Release, QA. Änderungen koordinieren; keine parallele Bearbeitung derselben Dateien ohne klaren Ownership-Plan.
8. **Keine Annahme einer vorhandenen Anmeldung oder Lizenz.** Codex/Claude nur verwenden, wenn auf dem Benutzer-Mac tatsächlich installiert, kompatibel und unter den jeweiligen Bedingungen nutzbar.
9. **Offene externe Integrationsrisiken früh in lauffähigen Spikes nachweisen.** Besonders: „Mac startet Agent“ ↔ „Sitzung in offizieller mobiler Codex-/Claude-App weiterführen“. Das Ziel bleibt v1.0, eine nicht gewährleistete Interoperabilität darf aber nicht als bereits funktionierend ausgegeben werden.
10. **Keine Geheimnisse, Tokens, fremde Projekte oder Geräte ohne Einwilligung verändern.** Änderungen an Repository-Strukturen und automatisch erzeugten Agentenanweisungen müssen prüfbar und reversibel sein.
11. **Rückfragen nur bei echten Blockern:** Apple Developer Team, Zertifikate, CloudKit Container, echte Provider-Accounts/API-Schlüssel, nicht verfügbare Hardware oder vom Benutzer zu treffende Produktentscheidungen. Für andere Details sichere, konsistente Defaults wählen und dokumentieren.
12. **Keine v1.0-Abnahme ohne Nachweis** anhand der konkreten Kriterien unter Abschnitt R. Unvollständige Funktionen im Abschlussbericht offen ausweisen.
13. **Modell und Denkstufe sind verbindlich konfigurierbare, eigenständige Auftragsparameter.** Beides vor dem Agentenstart anhand der tatsächlich verfügbaren Agentenfähigkeiten prüfen, an den unterstützten Adapter übergeben und effektiv verwendete Werte protokollieren. ADR-0006 beachten.

## Definition des Produkts in einem Satz

**Software Regisseur** ist eine native, iCloud-synchronisierte Schaltzentrale, mit der Entwickler auf dem iPhone Ideen diktieren, KI-gestützt zu Aufgaben/ADRs ausarbeiten und Codex-/Claude-Agenten am eigenen Mac sicher, zeitgesteuert und nachvollziehbar mit lokalen Git-Repositories arbeiten lassen können.

---

# B. Produktgrundsätze und Geltungsbereich

## Leitprinzipien

- **Local first / Git first:** Git-Repositories und menschenlesbare Markdown-Dateien sind die langlebigen Artefakte. Die App verwaltet einen lokalen, synchronisierten Projekt-/Aufgabenindex samt Warteschlange und Metadaten.
- **Ein Git-Repository bleibt unabhängig verwendbar:** Alle Aufgaben und ADRs müssen ohne Software Regisseur lesbar und bearbeitbar sein.
- **iPhone unabhängig vom Mac:** Diktieren, API-Transkription, Erfassen, Bearbeiten, KI-Ausarbeiten, Freigeben und Planen funktionieren auf iOS auch bei ausgeschaltetem Mac; Repo-Schreibvorgänge und lokale Agentenstarts warten dann in einer robusten Queue.
- **Mac als Execution Host:** Die Mac-App verwaltet Git-Dateisystem, Worktrees, lokale Coding-Agenten und deren Ausführung. Keine direkte iPhone-Freigabe des kompletten Git-Ordners über iCloud.
- **Keine sichtbaren Push-Benachrichtigungen:** Es gibt keinen APNs-basierten Nutzer-Benachrichtigungsworkflow. Status wird in der App angezeigt; Synchronisierung erfolgt beim Öffnen/Aktivieren, manuell und beim Mac über explizite periodische Abfragen. Systeminterne CloudKit-Mechanismen dürfen keine Voraussetzung für garantierte Sofortzustellung sein.
- **V1 vollständig:** Auch Zeitplanung, Agentenintegration, **freie Modellwahl und Denk-/Effort-Stufen für Agenten**, Review, Statushistorie, BYOK, Diktat, GitHub-Issues-Option, Dashboard und sicherer Direktvertrieb gehören in die Erstversion.
- **Keine eigene vollwertige Coding-Chat-App nachbauen**, wenn die offiziellen Claude-/Codex-Apps eine kompatible Sitzung zuverlässig weiterführen können. Bei dokumentierten Schnittstellenlücken eine transparente, funktionsfähige Alternativbedienung anbieten (siehe Agenten).
- **Transparente Zustände statt falscher Gewissheit:** „Auftrag geplant“, „gestartet“, „Agent arbeitet“, „wartet auf Bestätigung“, „Implementierung beendet“, „Review“, „integriert“, „abgeschlossen“ sind verschiedene Phasen.

## Zielplattformen und Vertrieb

- iPhone und iPad (ADR-0025) mit aktueller, in Xcode unterstützter iOS-/iPadOS-Version; konkrete Mindestversion bei Projektanlage unter Berücksichtigung der benötigten APIs dokumentieren und konservativ festlegen.
- macOS nativ (Apple Silicon als primäres Ziel; Intel nur nach gesondertem Kompatibilitäts-/Testnachweis). Menüleistenintegration ist zwingend.
- Mac-App **außerhalb des Mac App Stores**: Developer ID Application, Hardened Runtime, Apple-Notarisierung und Ticket-Stapling; Installation mit einem nachvollziehbaren signierten Distributionspaket oder DMG.
- Die **App Sandbox ist wünschenswert, aber kein Muss**. Externe CLI-Ausführung macht eine vollständig sandboxed Agentenkomponente schwierig. Sandbox-Experiment früh durchführen; bei technischen Einschränkungen UI und Agent Service sauber trennen, nötigen Agent Service unsandboxed betreiben und Entscheidung als ADR festhalten. Keine V1-Blockade aus rein formalen Sandbox-Zielen.
- iOS: reguläre App-Store-Distribution oder entwicklerseitig installierbare Builds; iOS-Berechtigungen, Privacy Manifest und Review-Richtlinien berücksichtigen.
- **Zielgruppe v1 (ADR-0014):** Eigengebrauch durch den Entwickler. iOS über TestFlight bzw. Entwickler-Builds, macOS als Developer-ID-signierte, notarisierte App. Codex und Claude Code ausschließlich mit dem eigenen Login über offiziell dokumentierte Wege. Ein Vertrieb an Dritte erfordert einen neuen ADR mit Lizenzprüfung (insbesondere J5). **Nicht** die Mac-App künstlich auf Mac-App-Store-Anforderungen beschränken.

---

# C. Gewünschte Gesamtarchitektur

```text
                            ┌──────────────────────────────┐
                            │         iPhone-App            │
                            │ SwiftUI / lokale Datenbank    │
                            │ Ideen, Aufgaben, Audio, KI    │
                            │ BYOK-Keychain, Warteschlange  │
                            └──────────────┬───────────────┘
                                           │
                              CKSyncEngine / CloudKit
                           (Private Database, Pull + Sync)
                                           │
                            ┌──────────────┴───────────────┐
                            │        macOS-App             │
                            │ MenuBarExtra + Hauptfenster  │
                            │ Dashboard, Review, Settings  │
                            └──────────────┬───────────────┘
                                           │ IPC/XPC
                            ┌──────────────┴───────────────┐
                            │     Local Agent Service      │
                            │ Login Item / LaunchAgent     │
                            │ Git-Scanner, Queue, Locks    │
                            │ Scheduler, Agent-Provider    │
                            └───────────┬──────────┬───────┘
                                        │          │
                          ┌─────────────┘          └────────────────┐
                          │                                         │
                ┌─────────▼───────────┐                 ┌───────────▼─────────┐
                │ Lokale Git-Repos    │                 │ Lokale Coding-Agents│
                │ Markdown / ADRs     │                 │ Codex / Claude Code │
                │ Feature Requests   │                 │ Worktrees, Sessions │
                │ Git-Commits        │                 │ Offizielle Apps*    │
                └─────────────────────┘                 └─────────────────────┘

            * Mobile Übernahme nur bei tatsächlich nachgewiesener Kompatibilität.
```

## Technische Bausteine

1. **Swift + SwiftUI** für iOS und macOS; Swift Concurrency (`async/await`, Actors) für nebenläufige Funktionen; AppKit nur dort, wo Menu-Bar-/Fensterverhalten sinnvoll ergänzt werden muss.
2. **Shared Swift Package(s)** für Domain-Modelle, Synchronisierungslogik, Markdown-Parsing, Provider-Verträge, Job-State-Machine, Sicherheitsregeln und Validierung.
3. **Lokale persistente Datenhaltung:** SwiftData oder SQLite/GRDB nach dokumentierter Abwägung; grundsätzlich explizites versioniertes Schema, Migrationen und Transaktionen. Für CloudKit eine klar definierte Sync-Schicht (`CKSyncEngine` oder gleichwertig) mit kontrollierbarem Fetch/Send und Konfliktbehandlung. Nicht auf implizite „irgendwann aktualisiert es sich“-Semantik verlassen.
4. **CloudKit Private Database** des Benutzers für Projektindex, Requests, Statusereignisse, Aufgabenwarteschlange, Gerätefähigkeit und unsensitive Konfiguration. Kein eigener Server und keine zusätzliche Nutzerregistrierung für den Kernbetrieb.
5. **Mac-Hintergrunddienst** via `SMAppService`/LoginItem/LaunchAgent, im Benutzerkontext ohne Root, mit kontrolliertem Start bei Anmeldung und sauberer IPC zur GUI. Läuft weiter, wenn das Hauptfenster geschlossen ist. Bei „App beenden“ bewusst zwischen GUI schließen und Dienst stoppen unterscheiden.
6. **Dateisystem-Watcher** (geeignete FSEvents-basierte Lösung) plus periodische Reconciliation; niemals allein auf Events verlassen.
7. **Git:** möglichst über robust abstrahierte Prozesse oder geeignete Bibliothek; korrekte Behandlung von `.git`-Verzeichnissen und `.git`-Dateien bei Worktrees/Submodules; keine selbst erfundenen Git-Operationen.
8. **AgentProvider-Protokoll mit dynamischer Model-/Effort-Capability-Erkennung** für Codex, Claude Code und Erweiterbarkeit (Cursor/Gemini CLI künftig möglich; wenn für Version 1 im UI angekündigt, muss mindestens sichere Detection und dokumentierte Unterstützung tatsächlich implementiert sein).
9. **AIProvider-/TranscriptionProvider-Protokolle** separat von AgentProvider. KI-Textbearbeitung ≠ Coding-Agent-Lauf.
10. **Keychain** für API-Schlüssel und lokale Credentials; auf Wunsch opt-in iCloud-Keychain-Synchronisierung, wenn sicher, verfügbar und ausdrücklich aktiviert. Keine Klartextschlüssel in Git, CloudKit oder Debug-Logs.
11. **Kein dauerhafter externer Backend-Zwang**; Remote Control offizieller Agenten darf deren eigene Cloud-Dienste nutzen, sofern vom Nutzer freigegeben.

---

# D. Mac-App: Menüleiste, Hauptfenster und Hintergrundbetrieb

## D1. Menüleisten-App („lebt oben in der Menu Bar“)

Die Mac-App muss grundsätzlich über `MenuBarExtra` erreichbar sein. Das Symbol ist dauerhaft präsent, solange die App läuft. Kein Dock-Zwang. Zusätzlich öffnet ein Menüpunkt ein vollständiges Hauptfenster.

Menüleistenansicht mindestens:

- Status des lokalen Dienstes und der iCloud-Synchronisierung; „Mac bereit / pausiert / offline“.
- Anzahl aktiver Codex- und Claude-Agenten, jeweils anklickbar.
- Anzahl wartender/geplanter Aufträge inklusive nächstem geplanten Start.
- Anzahl blockierter/fehlgeschlagener Aufträge und zur Review anstehender Aufgaben.
- Schnellaktionen: Neue Notiz, Projektübersicht, Aufgabenqueue, Agentenübersicht, Jetzt synchronisieren, Scanner aktualisieren, Einstellungen, Dienst pausieren/fortsetzen, App beenden.
- Klar erkennbare Zustands-Icons; keine irreführenden grünen Anzeigen ohne echte Prüfung.

## D2. Hauptfenster

Navigation: **Dashboard – Projekte – Inbox – Aufgaben/Requests – ADRs – Agenten – Warteschlange – Historie – Einstellungen**. Kontextabhängig Detailansichten, Suchen, Filtern, Sortieren, Bearbeiten, Reviews und Diff-Darstellung.

## D3. Dauerbetrieb

- Start bei macOS-Anmeldung konfigurierbar; sinnvoller Default aktiviert nach Zustimmung.
- Nach Schließen des Fensters Agent Service und Menüleiste aktiv lassen.
- Bei Logout, Neustart, Absturz, Dienstupdate und Schlaf/Aufwachen in definierte konsistente Zustände übergehen.
- Nach Neustart laufende Job-Records gegen tatsächlich noch laufende Prozesse/Worktrees prüfen, Locks nicht blind entfernen.
- Kein dauerhafter Schlafverhinderer für einen bloß geplanten Job. Während aktiver Arbeit Schlafverhalten dokumentiert und nutzerkonfigurierbar behandeln; Systemenergieeinstellungen respektieren.

---

# E. Projekt- und Git-Verwaltung

## E1. Stammordner wählen und rekursiv indizieren

- Mac-Einstellungen: einen oder mehrere frei wählbare Git-Stammordner; Default-Vorschlag `~/Developer` oder vorhandener benutzergewählter Git-Ordner.
- **Alle geeigneten Unterordner des ausgewählten Stammordners indizieren**, nicht nur solche, die bereits Git-Repositories sind. Für jeden Ordner ermitteln, ob er ein eigenes Git-Repository, Unterordner eines Repos oder ein noch nicht initialisierter Projektordner ist.
- Rekursiver Verzeichnis-/Git-Scan; symlink-sicher, zyklusfrei, inkrementell, ohne riesige `node_modules`, `.build`, `DerivedData`, `.git/objects` etc. zu traversieren. Konfigurierbare Ausnahmen und maximale Tiefe; keine unübersichtlichen generierten Ordner als neue Projekte vorschlagen.
- Erkennen von normalen Repositories, verschachtelten Repositories, Worktrees, Bare-Repos und Submodules; Worktrees nicht als eigenständige Hauptprojekte duplizieren.
- Repository-ID stabil aus geeigneten lokalen/Git-Metadaten bestimmen, nicht nur aus Namen; Umbenennungen und Pfadänderungen behandeln.
- Projekte inklusive Name, lokalem Pfad, Default-Branch, Remote (falls vorhanden), Erreichbarkeitsstatus und relevanten Dokumentordnern indizieren.
- Projektübersicht nach Name, Änderung, offenen Aufgaben und Agentenstatus filterbar.
- Bei entfernten/verschobenen Ordnern keine Daten kommentarlos löschen; Re-Link-Workflow anbieten.
- Vor dem Erstellen/Verändern bestehender Dokumentstrukturen Inventar und Vorschau anzeigen.

## E2. Projekte am iPhone

- Die vom Mac erkannten Projekte **und geeigneten bestehenden Unterordner** sind per CloudKit auswählbar, auch wenn der Mac offline ist. Auf dem iPhone wird klar zwischen „bestehendes Git-Repository“, „noch kein Repository“ und „Unterordner eines Repositories“ unterschieden.
- Ein neues Projekt kann am iPhone angelegt werden. Wählbar sind **vorhandene, vom Mac indizierte Ordner** (auch ohne Git) oder ein **neuer Unterordner eines freigegebenen Stammordners**. Bei Unterordnern bestehender Repositories ist eine bewusste Rückfrage nötig, ob das gesamte Repo oder ein Teilbereich gemeint ist.
- Die iPhone-App greift nicht direkt auf das Mac-Dateisystem zu. Sie erstellt einen validierten `CreateProject`-/`LinkProject`-Auftrag; der Mac führt ihn aus, wenn erreichbar.
- Optionen: existierendes Git-Repository verknüpfen, neues Repository erzeugen (`git init` nur nach Zustimmung), Projekt zunächst ohne Repo als Entwurf anlegen.
- Pfadoperationen vor Ausführung kanonisieren und gegen Traversal/Symlinks/Verlassen erlaubter Stammordner absichern.
- Projektstatus `pendingMacSetup`, `ready`, `unavailable`, `needsAttention`, `archived` sichtbar machen.

## E3. Bestehende Projektstrukturen

- `AGENTS.md`, `CLAUDE.md`, vorhandene `docs/adr`, Issues, Requests und README-Dateien erkennen.
- Bereits bestehende Inhalte nicht überschreiben, verschieben oder umformatieren, ohne Vorschau und Zustimmung.
- Importe sollten bestehende IDs erhalten; nicht kompatible Dokumente als solche markieren und manuelle Zuordnung ermöglichen.
- Änderungen von außen (Editor, Codex, Claude, Git-Operationen) werden erkannt und zurück in die App synchronisiert.

---

# F. Markdown-Dokumente, Kategorien, Ordner und Status

## F1. Unterstützte Eintragstypen

- Schnelle Notiz / Inbox-Idee.
- Einfaches Todo / technische Aufgabe.
- Feature Request.
- Bug Report.
- Improvement / Refactoring.
- Architecture Decision Record (ADR).

Jeder Eintrag besitzt stabile Identität, Status, Projektzuordnung (optional für Inbox), Text, Zeitstempel, Priorität, Verweise, Änderungsverlauf und optional Anhänge/Transkript/Agentenaufträge.

## F2. Konfigurierbare Defaultstruktur

```text
<repo>/
├── AGENTS.md
├── CLAUDE.md                    # nur wenn erforderlich / bestehend
└── docs/
    ├── adr/
    │   ├── 0001-database.md
    │   └── 0002-sync-architecture.md
    └── requests/
        ├── open/
        │   └── FR-0001-feature.md
        ├── in-progress/
        │   └── BUG-0002-issue.md
        ├── review/
        │   └── FR-0003-ready-for-review.md
        └── done/
            └── FR-0004-completed.md
```

**Alle Pfade und Ordnernamen** (inkl. `docs`, ADR-Ordner, Requests, einzelne Statusordner) global und je Projekt einstellbar. Beispiele `ideas/todo`, `features/finished`, deutsche Namen etc. müssen funktionieren. Pfadänderungen lösen sichere Migration mit Vorschau, Kollisionsprüfung, Backup/Git-Diff und Aktualisierung der Agentenanweisungen aus.

## F3. Dateiformat und Identität

Für Requests: menschenlesbares Markdown mit YAML-Frontmatter. Mindestens:

```yaml
---
id: FR-0001
uuid: "<stable-uuid>"
type: feature
status: open
title: "Senderliste auf dem iPad vergrößern"
createdAt: "2026-10-29T20:00:00+01:00"
updatedAt: "2026-10-29T20:00:00+01:00"
priority: medium
labels: [ios, ux]
dependsOn: []
agentJobIds: []
reviewState: pending
---
```

Danach: Beschreibung, Problem, Ziel, Akzeptanzkriterien, ggf. technische Hinweise, Testhinweise und Referenzen. IDs eindeutig **pro Repository**, UUID global eindeutig; spätere Umbenennung nicht als neue Aufgabe ansehen. Frontmatter robust validieren, unbekannte Felder und Benutzerabschnitte bewahren. Keine destruktive Formatierung ganzer Dateien beim reinen Statuswechsel.

## F4. ADRs

**Dieses Projekt verwendet ADRs von Beginn an.** Die mitgelieferten Startentscheidungen stehen unter `docs/adr/` in der tatsächlichen Projektstruktur. `docs/adr/README.md` enthält den ADR-Index, `docs/adr/TEMPLATE.md` die Vorlage. Auslieferung und Änderungen an ADRs folgen dem ebenfalls mitgelieferten `AGENTS.md`. Der hier konfigurierte `docs/adr`-Ordner gilt für Software Regisseur selbst; andere von der Anwendung verwaltete Git-Repos können abweichende Ordner verwenden.

- Konvention: `NNNN-kurzer-titel.md`, Markdown.
- Empfohlene Felder: Nummer, Titel, Status (`proposed`, `accepted`, `deprecated`, `superseded`), Datum, Kontext, Entscheidung, Alternativen, Folgen, Referenzen.
- ADRs nicht automatisch als Feature Requests interpretieren.
- Eine Änderung einer akzeptierten Architekturentscheidung erfolgt normalerweise durch neuen ADR mit Verweis auf den ersetzten ADR, nicht durch lautloses Überschreiben der Entscheidung.
- KI kann ADR-Entwürfe vorschlagen, **Annahme nur durch Benutzerfreigabe**.

## F5. Aufgabenstatus und Verzeichnisse

Konzeptionell mindestens:

`inbox → open → queued → scheduled → in_progress → waiting_approval → implementation_finished → review → integrated → done`

Zusätzlich `blocked`, `failed`, `cancelled`, `paused` sowie getrennte Agenten-Laufzustände.

**Verbindliches Statusmodell (ADR-0012):** Projekt-, Aufgaben- und Job-Status sind drei getrennte Zustandsmaschinen. Projektstatus siehe E2 (`pendingMacSetup`, `ready`, `unavailable`, `needsAttention`, `archived`). Die obige Liste ist der Aufgabenstatus (`WorkItem`). Laufbezogene Zustände wie `pendingMac`, `needs_configuration` und `waiting_quota` gehören ausschließlich zum `AgentJob`; der Aufgabenstatus wird während eines aktiven Jobs nach der Abbildungstabelle in ADR-0012 abgeleitet.

**Nicht jeder operative Zustand benötigt einen eigenen Ordner.** Verzeichniszuordnung bleibt konfigurierbar (z. B. `queued/scheduled` in `open`, `review` in `review`, `integrated/done` in `done` erst nach Benutzerfreigabe). Vordergründige Task-Statusinformationen bleiben im Frontmatter und Sync-Index erhalten.

- Beim Start: angemessene Status- und Ordneraktualisierung (`in-progress`).
- Nach Ende des Agenten: `implementation_finished`/`review`; **nicht** automatisch `done`.
- Nach erfolgreicher Übernahme der Änderungen und Freigabe: `done`, in konfiguriertes Done-Verzeichnis verschieben.
- Direkte manuelle Statusänderungen müssen möglich bleiben und mit aktiven Jobs kollisionssicher behandelt werden.

---

# G. AGENTS.md / CLAUDE.md: automatisch, dynamisch, nicht destruktiv

Software Regisseur verwaltet **projektweite Agentenanweisungen** anhand der tatsächlichen Benutzerkonfiguration. `AGENTS.md` ist die bevorzugte gemeinsame Anweisungsquelle. Andere Agentenformatdateien nach Bedarf unterstützen.

## Pflichtregeln

1. Vorhandene Anweisungsdateien vor Änderungen analysieren; benutzerdefinierte Abschnitte erhalten.
2. Einen eindeutig begrenzten, versionierten *managed block* verwenden, beispielsweise:

```markdown
<!-- SOFTWARE-REGISSEUR:BEGIN v1 -->
## Software Regisseur Workflow
- ADRs: docs/adr/
- Open requests: docs/requests/open/
- In progress: docs/requests/in-progress/
- Review: docs/requests/review/
- Done: docs/requests/done/
- Read relevant accepted ADRs before architectural changes.
- Preserve request IDs and frontmatter fields.
- On start: update task status and move into the active location if configured.
- On implementation finish: report changes and tests; set review, not done.
- Never push or merge without explicit user approval.
- Do not modify unrelated requests or secrets.
<!-- SOFTWARE-REGISSEUR:END -->
```

   *Hinweis (ADR-0024): Das obige Beispiel ist überholt. Request- und ADR-Dateien pflegt ausschließlich Software Regisseur; Agenten legen sie weder an noch ändern oder verschieben sie, und Software Regisseur committet sie nie selbst.*

3. Bei Konfigurationsänderungen nur den *managed block* neu erzeugen; diff anzeigen, atomar schreiben, ggf. Git-Status warnen.
4. Wenn `AGENTS.md` bereits benutzerdefinierte Regeln enthält, diese nicht ersetzen.
5. Claude-Kompatibilität **versionsabhängig prüfen**; vorhandene `CLAUDE.md` nicht ungefragt überschreiben. Falls sinnvoll, einen sicheren Verweis/Import ergänzen, z. B. `@AGENTS.md`, aber nur wenn vom installierten Agenten unterstützt und keine doppelte widersprüchliche Regelquelle entsteht.
6. Für Codex/Cursor/weitere Agents nur nachgewiesene unterstützte Anweisungsformate einsetzen; nicht voraussetzen, dass alle dieselben Dateien automatisch laden.
7. Anweisungen allein gelten nicht als garantierte Maschinenzustandsänderung. Mac-Dienst prüft die tatsächlichen Dateien und Git-Operationen unabhängig.
8. Individuelle Pfade/Projektregeln werden in synchronisierten Einstellungen gespeichert und auf dem Mac konsistent in Markdown gespiegelt.

---

# H. iPhone-App: Erfassung, Diktat, AI und Verwaltung

## H1. Allgemeine Bedienung

- Native SwiftUI-App, schnell startend, iPhone-optimiert, Dark/Light Mode, Dynamic Type, VoiceOver, klare leere Zustände.
- Dashboard für alle Projekte, aktive Agenten, ausstehende Reviews, offene/geplante Aufgaben und zuletzt erledigte Arbeiten.
- Projektansicht: Inbox, Aufgaben nach Typ/Status, ADRs, Historie und Agentenstatus.
- Filter/Suche nach Projekt, Status, Typ, Label, Priorität, Datum, Agent.
- Schnellerfassung über prominente Aktion, Text-/Sprachaufnahme und Projektauswahl.
- Projektzuordnung optional bis nachträglich; auch unterwegs ohne Internet/CloudKit möglich.
- Anlegen, Bearbeiten, Duplizieren, Archivieren; Undo und Konfliktanzeige.

## H2. Sprachdiktat – zwei vollständig unterstützte Wege

**A) Apple-Spracherkennung:** native Speech APIs/geeignete Systemdiktierfunktion; Berechtigungen korrekt einholen (Regeln für eigene Erklärbildschirme siehe Q4). Internet-/Offline-Verfügbarkeit wahrheitsgemäß anzeigen, nicht pauschal Offline-Verarbeitung behaupten.

**B) API-Transkription:** Audioaufnahme mit AVFoundation und Upload an einen vom Nutzer gewählten Anbieter; für v1 mindestens **OpenAI Speech-to-Text** mit selbst hinterlegtem API-Key. Aktuelle, nicht abgekündigte OpenAI-Modelle anhand offizieller Dokumentation nutzen (Stand Oktober 2026 z. B. `gpt-transcribe`; ältere `gpt-4o-transcribe`-Varianten nicht unkritisch als neuen Default wählen). Dokumentierte Größen-/Formatlimits, Fehler und Kosten berücksichtigen.

Möglichkeiten:

- Aufnahme starten, pausieren/beenden, anhören, löschen.
- Aufnahme transkribieren, Transkript vor KI-Ausarbeitung korrigieren.
- Lange Notizen sinnvoll behandeln (gültige Komprimierung/Segmentierung bei API-Limits).
- Projektspezifische Begriffe/Akronyme als Transkriptionshinweise, ohne als gesprochenen Inhalt zu erfinden.
- Spracherkennung je Gerät wählbar; Wechsel ohne Datenverlust.
- Originalaufnahme optional behalten, standardmäßig nach erfolgreicher Verarbeitung löschen (nach bestätigter Aufbewahrungsregel).
- Vor externem Upload klar anzeigen, dass Audio an den gewählten Dienst übertragen wird.

## H3. KI-Ausarbeitung direkt auf iOS – unabhängig vom Mac

- Eigener API-Key **auf dem iPhone** hinterlegbar. iPhone kann selbstständig Provider-API ansprechen; Mac/CloudKit sind nicht erforderlich, solange Internet beim Provider verfügbar ist.
- Für v1 Providerabstraktion mit **OpenAI, Anthropic, Google Gemini** zur *Textausarbeitung*, soweit jeweils aktuelle APIs und Benutzer-Keys vorhanden; Modelle dynamisch oder kontrolliert konfigurierbar, capabilities validieren.
- Provider für Diktat und Provider für Ausarbeitung können verschieden sein (z. B. OpenAI Speech-to-Text und Claude Textausarbeitung).
- Rohnotiz in strukturierten Entwurf umarbeiten: Typ-Klassifizierung (Todo/Feature/Bug/ADR), Titel, Ziel, Kontext, Akzeptanzkriterien, technische Hinweise, Testfälle, ggf. Priorität und Abhängigkeiten.
- Aus einer Aufnahme mehrere getrennte Aufgaben vorschlagen und vor Anlage einzeln bestätigen.
- Unklare Anforderungen durch gezielte Rückfragen auflösen, nicht stillschweigend Details halluzinieren.
- **„Mit KI besprechen“:** Gesprächsmodus zu einer Notiz bzw. einem Request auf iPhone und Mac. Der Benutzer kann Fragen stellen, Varianten diskutieren und Entwurfsänderungen anfordern; die KI schlägt daraus eine neue Entwurfsversion vor, die erst nach Freigabe übernommen wird. Kontext auf dem iPhone: Notiz/Request und die per CloudKit synchronisierten Projektdaten (bestehende Requests, ADR-Index); Quellcode nur über die Mac-Kontextanreicherung nach H4. Der Umfang des mitgesendeten Kontexts ist vor dem Senden sichtbar. Das Gespräch ist keine Coding-Agent-Sitzung und startet nie einen Agenten.
- Modi: „Kurz ausarbeiten“, „Ausführlich“, „Akzeptanzkriterien ergänzen“, „Technische Details“, „In Aufgaben aufteilen“.
- Originalnotiz, Transkript und KI-Entwurf getrennt versionieren. Benutzer kann Änderungen sehen, korrigieren, erneut ausarbeiten und erst danach freigeben.
- Option, nach Diktat automatisch einen **Entwurf** zu erzeugen; automatischer KI-Entwurf ist niemals automatische Zustimmung zum Start eines Coding-Agenten.
- Nutzung/geschätzte API-Kosten und Providerfehler transparent anzeigen; Daten nur zweckgebunden übertragen.

## H4. KI-Ausarbeitung mit Repo-Kontext

- Neben schneller rein mobiler Verarbeitung eine vertiefte Ausarbeitung am Mac ermöglichen.
- Vor der Anfrage relevante Teile von Repository-Struktur, akzeptierten ADRs, bestehenden Requests und ausgewählten Quellcodedateien ermitteln; Context-Budget/Tokenlimits beachten.
- Dateiauswahl und Datenübermittlung an externen Provider nachvollziehbar; `.env`, Schlüssel, Credentials, Zertifikate und Secrets strikt ausschließen.
- Ergebnis wird als überprüfbarer Entwurf ins iCloud-/Request-Modell übernommen.
- Wird der Mac gerade nicht erreicht, darf der Benutzer die mobile Variante nutzen oder vertiefte Ausarbeitung in Queue stellen.

---

# I. Eigene API-Schlüssel und Modelle (Bring Your Own Key)

- Eigenständige Anbieterwahl/Schlüsselkonfiguration **auf iPhone und Mac**. Kein verpflichtendes von Software Regisseur verkauftes KI-Abonnement.
- Unabhängige Einstellungen für **Transkription**, **KI-Textausarbeitung** und **lokal installierte Coding-Agenten**.
- Schlüssel nur im Keychain; Transport zur jeweiligen Provider-API per TLS; keine Speicherung im normalen CloudKit-Record, Markdown, Git-Repo oder in Logs.
- Schlüsselspeicherung standardmäßig gerätebezogen; optional in v1 explizites, sicheres iCloud-Keychain-Sharing nur bei technisch sauberer Verfügbarkeit und Einwilligung. Niemals CloudKit-Klartext als Ersatz.
- Anbieter mit „Schlüssel prüfen“, Modellwahl, Timeout, Rate-Limit-Handling, Kostenanzeige soweit API-Daten ausreichend, Widerrufen/Löschen.
- Fehlende Schlüssel führen zu erklärbaren deaktivierten Optionen, nicht zu App-Abstürzen.
- Keine Vermischung: OpenAI-API-Key für Text/Diktat ist **nicht** automatisch Codex-CLI-Anmeldung; Anthropic-API-Key ist **nicht** automatisch für Claude-Code-Remote-Control-Abonnement nutzbar.
- API-Inhalte gegen Prompt Injection absichern: freie Notiz/Repo-Inhalt als Daten behandeln, nicht als Ausführungsanweisung für Systemberechtigungen.

---

# J. Agenten: Erkennung, Auswahl, Start und Interaktion

## J1. Automatische Erkennung auf dem Mac

Die Mac-App erkennt installierte Coding-Agenten und übermittelt Fähigkeiten/Status sowie **je Agent verfügbare Modelle und unterstützte Effort-Stufen** an das iPhone. Keine manuelle CLI-Pflicht für Standardfälle.

Für v1 mindestens:

- **OpenAI Codex:** CLI und ggf. Desktop-App getrennt erkennen; Version, ausführbare Datei, Authentifizierung, Fähigkeit zum automatischen Start, Streaming/Session-ID und mobile Weiterführung testen.
- **Claude Code:** CLI, Version, Anmeldung, Remote-Control-Verfügbarkeit, Startmethode, Session-ID und Policy-/Abo-Anforderungen erkennen.
- Architektur über `AgentProvider` erweiterbar auf Cursor, Gemini CLI und weitere Tools. In der UI nur vollständig unterstützte, tatsächlich nutzbare Adapter als „einsatzbereit“ kennzeichnen.

Robuste Erkennung berücksichtigt LaunchAgent-`PATH` (Homebrew Apple Silicon `/opt/homebrew/bin`, Intel `/usr/local/bin`, benutzerdefinierte Pfade), Tools-/App-Bundles, Versionsabfrage und sichere Ausführungsprüfung. Keine ungefragten Befehle mit Seiteneffekten zur bloßen Installationserkennung.

Fähigkeitsmodell:

```text
AgentCapability {
  providerId, displayName, executablePath?, appBundleId?, version,
  installed, authenticated, runnable, remoteControllable,
  supportsAutomaticStart, supportsResume, supportsApprovals,
  supportsModelSelection, supportsEffortSelection, modelCatalog[],
  modelEffortMatrix[], capabilitySource, capabilityCheckedAt,
  sessionLinkFormat?, detectionTimestamp, hostId, diagnostic
}
```

Nur **einsatzbereite** Agenten auswählbar; offline gecachte Fähigkeiten als „zuletzt erkannt – Mac derzeit offline“ kennzeichnen. Nach Installation/Deinstallation/Upgrade automatisch aktualisieren.

## J2. Agentenauswahl am iPhone

- Button „Mit Agent umsetzen“; Auswahl der vom Mac erkannten verfügbaren Agenten (mindestens Codex/Claude Code).
- Pro Projekt optionaler Standardagent **mit bevorzugtem Modell und gewünschter Denk-/Effort-Stufe**, soweit der jeweilige Agent die Kombination tatsächlich unterstützt; globale Voreinstellungen und Auftrags-Overrides.
- Möglichkeit „Nur speichern“, „Jetzt starten“, „Für später einplanen“, „Bei Kontingent verfügbar erneut versuchen“. (Das Ausarbeiten bzw. Besprechen einer Aufgabe vor dem Start ist keine Agentenfunktion, sondern KI-Ausarbeitung nach H3.)
- Mac-Verfügbarkeit, Queue-Status, geschätzte Einschränkungen, erforderliche Genehmigungen klar anzeigen.
- Kein nicht installierter Agent als aktiv verfügbar.

## J2a. Verbindliche Modellwahl und Denk-/Komplexitätsstufe (Version 1.0)

**Modellwahl und Reasoning-/Effort-Stufe sind zwei getrennte, sichtbare Einstellungen**, die **bei jeder Agentenausführung direkt am iPhone sowie am Mac** auswählbar sind. Die Stufe ist eine Ausführungsressource (z. B. „Niedrig“, „Mittel“, „Hoch“, „Extra hoch“), **nicht** eine automatische Schätzung der fachlichen Schwierigkeit der Aufgabe. Eine optionale Aufgabenkomplexität für Planung/Priorisierung bleibt als eigenes Feld möglich.

**UI und Vererbung:**

- Globaler Standard **je Agent**: bevorzugtes Modell und Effort `auto` (Agent-/Modellstandard) oder explizite unterstützte Stufe. Keine starre Liste fest eingebauter Modell-IDs.
- Projekteinstellung: Modell und Effort **je Agent separat** überschreibbar; Agenten-Standardprofil des Projekts auf Wunsch hinterlegbar.
- Bei Start/Planung des einzelnen Requests: Agent → Modell → Denk-/Effort-Stufe mit einer verständlichen Beschreibung und optionalen Hinweisen zu Kosten/Laufzeit/Kontingent. Override für **diesen Job**, ohne globale/projektweite Einstellungen zu verändern.
- Auflösung der Werte: **Auftrag > Projekteinstellung > globaler Agentenstandard > Anbieterstandard (`auto`)**. Beim Anlegen eines Jobs das aufgelöste Konfigurations-Snapshot persistieren; ein später geänderter Projektstandard darf bereits geplante Jobs **nicht stillschweigend ändern**. Explizite Funktion zum Aktualisieren geplanter Jobs anbieten.
- Keine Ausführung mit stillschweigendem Modell-/Effort-Fallback. Wenn Auswahl unzulässig oder inzwischen nicht verfügbar ist, den Job **vor dem Start** anhalten (`needs_configuration`/`blocked`) und erneute Auswahl bzw. ausdrückliche Zustimmung zu einem unterstützten Ersatz anbieten.

**Dynamische Verfügbarkeit:**

- Der Mac-Adapter ermittelt verfügbare Modelle und je Modell unterstützte Denkstufen aus **dokumentierten/real geprüften Fähigkeiten der installierten Version und der jeweiligen Anmeldung**. Diese Information nach macOS-Start, Agent-Upgrade, Account-Wechsel und vor Jobstart auffrischen; per CloudKit an iOS weitergeben.
- Mögliche UI-Stufen: `auto`, `low`, `medium`, `high`, `xhigh`, gegebenenfalls `max` bzw. weitere **nachweislich unterstützte** Werte. Nur dem konkreten Modell/Adapter verfügbare Optionen freischalten; nicht unterstützte Stufen ausblenden oder begründet deaktivieren. Provider-native IDs **verlustfrei** speichern und nur für die Anzeige auf Deutsch übersetzen.
- Technische Umsetzung unterschiedlich: Codex über dokumentiertes `model`/`model_reasoning_effort` oder app-server-spezifische Konfiguration; Claude Code über dokumentierte `--model`- bzw. `--effort`-Unterstützung oder SDK-Konfiguration (abhängig von der installierten Version). **Keine CLI-Flags oder RPC-Felder raten.** Eine offiziell mobil fortsetzbare Sitzung darf nicht mit einer nicht unterstützten Modell-/Effort-Konfiguration verwechselt werden.
- Wenn ein Adapter zwar Modelle, aber keine Effort-Stufe zuverlässig anbietet, zeigt die UI **„Anbieterstandard – nicht einstellbar“**. Das ist keine simulierte Auswahl. Kein scheinbares `high` durch zusätzliche Prompt-Adjektive.
- Der Job speichert `requestedModelId`, `requestedEffort`, `resolvedModelId`, `resolvedEffort`, `effectiveModelId?`, `effectiveEffort?`, `capabilityRevision`, `agentVersion`, `profileSource`, Zeitstempel und nachvollziehbare Fehler. Angezeigte effektive Werte nur bei belegter Rückmeldung, sonst „nicht bestätigt“.
- Modell-/Denkstufenwahl der **Coding-Agenten** ist getrennt von der Modellwahl für **Text-KI-Ausarbeitung, Transkription** und vom API-Key.

**Akzeptanz:** Die Kombinationen müssen auf iPhone und Mac auswählbar, synchronisiert, vor dem Jobstart geprüft, korrekt an reale Adapter übergeben und in Job-Details/Historie sichtbar sein. Fehlende Unterstützung wird nicht durch pauschales `medium` überspielt. Siehe ADR-0006 sowie A35–A42.

## J3. Vollautomatischer Start am Mac

- iPhone erzeugt signierten/logisch autorisierten Job-Wunsch mit **idempotenter UUID**.
- Mac validiert Projekt, Task, Voraussetzungen, Berechtigungen, vorhandene Worktrees und aktive Locks.
- Nach Admission: Task sperren, Worktree/Branch vorbereiten, **gespeichertes Modell-/Effort-Snapshot erneut validieren**, Agent mit konkreter unterstützter Konfiguration und klar begrenztem Prompt starten, Output/Session/Status erfassen.
- Bei Fehlern keine stillschweigende Doppel-Ausführung. Wiederanlauf über robuste, eindeutige Job-ID und Recovery-State-Machine.
- Agent darf nicht implizit in produktive Branches schreiben, pushen oder mergen.

## J4. Codex-Adapter

- Offizielle Codex-Integrationsmöglichkeiten prüfen: **app-server**, SDK und CLI, unter anderem Streaming von Turns, Resume, Approval-Requests und persistente Thread-IDs.
- Für vollautomatischen Start vorzugsweise dokumentierte app-server/SDK-Schnittstelle; API-Vertrag und installierte Version verifizieren.
- Thread-ID, **gewähltes und tatsächlich verwendetes Modell/Reasoning-Effort (soweit nachweisbar)**, Startparameter, Arbeitsverzeichnis, Agentenversion, Git-Branch/Worktree, Zeitstempel und Ergebnis speichern.
- **Expliziter Machbarkeitstest:** Sind von Software Regisseur erzeugte lokale Threads in der offiziellen Codex-Desktop- bzw. mobilen ChatGPT-/Codex-Oberfläche sichtbar und bedienbar? Ein CLI/app-server-Thread ist **nicht automatisch** eine offiziell remote sichtbare App-Session.
- Deep Links nur verwenden, wenn von der installierten Zielapp nachgewiesen. Ein vorausgefüllter Prompt gilt nicht als abgesendet.
- Bei fehlender Übernahme: transparenten „im offiziellen Codex starten“-Ablauf auf dem iPhone mit vorbereitetem Prompt oder integrierte minimal notwendige Status-/Approval-Anzeige via unterstütztem Protokoll; keinerlei falsche Zusicherung einer unsichtbar schon laufenden offiziellen mobilen Session.

## J5. Claude-Code-Adapter

- **Claude Code Remote Control** als bevorzugter Weg für mobile Steuerung einer lokalen Mac-Sitzung, sofern verfügbar und vom Abonnement sowie Admin-Einstellungen erlaubt.
- Dokumentierten `claude remote-control`-Workflow und die jeweils gültigen Optionen prüfen; **Modell und Effort vor Sitzungsstart tatsächlich setzen oder unzulässige Auswahl blockieren**; Sessions, Remote-Link und Status erfassen.
- Alternativ CLI-Headless/Agent-SDK für programmatischen Start, **nur soweit Vertragsbedingungen/Anmeldemodell es erlauben**. Ein programmgesteuert gestarteter SDK-/CLI-Job muss nicht in der offiziellen Claude-App fortsetzbar sein.
- Offizielles mobiles URL-Schema `claude://code/{session-id}` nur für tatsächlich passende, gültige Claude-Code-Sitzungen nutzen; sonst auf Sessionliste verweisen.
- **Expliziter Machbarkeitstest:** Automatisch vorbereiteten Auftrag in der offiziellen mobilen Claude-App vollständig übernehmen, dort während laufendem Job chatten und Genehmigungen erteilen. Bei fehlender direkter API den Startmodus transparent und mit einer realen, nutzbaren Alternative anbieten.
- **Lizenz/Policy-Gate:** Kein unzulässiges Weiterreichen/Einbetten von claude.ai-Login oder Abo-Kontingenten als Drittanbieter-API. Offizielle dokumentierte Verwendungsweisen respektieren und kommerzielle Freigabe prüfen, falls nötig.

## J6. Offizielle mobile Apps bevorzugen

Die zentrale Produktvision lautet:

1. Auf dem iPhone in Software Regisseur Request auswählen.
2. Auf „Mit Codex“ oder „Mit Claude“ tippen.
3. Mac startet sicher den lokalen Agenten.
4. Nutzer interagiert **idealerweise in der offiziellen ChatGPT/Codex- oder Claude-App** mit der laufenden Sitzung.
5. Software Regisseur synchronisiert Fortschritt/Ergebnis/Review/Locks.

Damit ist **die Übernahme in die offizielle mobile App ein verpflichtendes V1-Integrationsziel**, aber nur dann als „automatisch“ bewerben, wenn ein End-to-End-Test mit realer Benutzerumgebung es belegt. Dokumentierte Fallbacks innerhalb von V1 implementieren, falls Drittanbieter keine entsprechende Programmierschnittstelle anbieten.

---

# K. Aufgabenwarteschlange, Zeitplanung und Kontingentgrenzen

## K1. Planung

Jeder Agent-Job kann sein:

- **Sofort** ausführbar.
- **Zu einem konkreten Zeitpunkt** (Datum, Uhrzeit, Zeitzone) eingeplant.
- **Nach einer Sperrfrist** / frühestens nach einer bestimmten Uhrzeit erlaubt.
- **Bei gemeldetem Kontingentlimit später erneut** ausführbar.
- **Manuell pausiert** oder nach Plan/Freigabe wartend.

Zusätzlich: Prioritäten (niedrig/mittel/hoch/dringend), Abhängigkeiten, maximale parallele Jobs global/pro Projekt/pro Agent, Queue-Reihenfolge, Abbruch, Repriorisierung und Wiederholung.

## K2. Kontingente

- Keine unbelegte Behauptung, der genaue Kontingent-Rücksetzzeitpunkt sei aus Codex/Claude auslesbar.
- Benutzer kann eigene erwartete Reset-Zeiten/Startzeit setzen.
- Wenn Provider ein explizites Retry-after/Limit-Signal liefert: verstehen und optional berücksichtigen. Bei unbekannter Reset-Zeit adaptive, begrenzte Backoff-Strategie mit Jitter und Max-Versuchen; nicht ununterbrochen anfragen.
- Konto-/Abo-Limits nicht umgehen. Kein automatisches Wechseln fremder Accounts.
- Bei Kontingentfehler: Job bleibt erhalten, Status `waiting_quota`, dokumentierter nächster Versuch, Sperre nach sauberer Agentenbeendigung passend freigeben oder Reservierung getrennt halten.

## K3. Betriebssystem-/Energiesituation

- Zeitplanung bleibt über Logout, Neustart und App-Abstürze persistent.
- `launchd`/SMAppService/geeignete Swift-Zeitsteuerung prüfen; keine alleinige Abhängigkeit von im App-UI laufenden `Timer`-Instanzen.
- Ausgeschalteter oder schlafender Mac kann lokale Agenten nicht garantiert zum Sollzeitpunkt starten. Nach Wiederkehr konfigurierbare Nachholregel: `runImmediatelyWhenAvailable`, `ask`, `skipExpired`.
- Status am iPhone eindeutig: „für 22:00 geplant, Mac zuletzt online 21:30“ statt „läuft“.
- Zeitzone speichern (IANA-Zonenname), Uhrzeitumstellung/Sommerzeit und doppelte Ausführung bei Reconnect testen.

---

# L. Sperren, Worktrees, Konflikte und Sicherheitsgrenzen

## L1. Sperrsemantik

- **Aufgabenbezogene exklusive Sperre** ab Start der tatsächlichen Bearbeitung; optional **projektweite Sperre** per Projekteinstellung für Nutzer, die nur einen Agenten pro Repo erlauben wollen.
- Lock-Datensatz mit `lockId`, `taskId`, `jobId`, `hostId`, `owner`, `acquiredAt`, `lastHeartbeat`, `leaseUntil`, `recoveryState`.
- Lock darf Doppelstarts innerhalb Software Regisseur verhindern. Er darf nicht behaupten, fremde Editor-/Terminal-Prozesse auf Systemebene blockieren zu können.
- Bei bestätigtem Abschluss, sauberem Abbruch oder Timeout **nach überprüfter Prozess-/Worktree-Reconciliation** freigeben; niemals bloß aufgrund eines abgelaufenen Zeitfensters einen noch arbeitenden Agenten doppelt starten.
- iPhone und Mac zeigen Lock und Ursache; Bearbeitung einer gesperrten Aufgabe ggf. nur als neue Notiz/Änderungsvorschlag zulassen.
- Mehrere unabhängige Projekte und Worktrees dürfen parallel laufen, wenn Limits und Abhängigkeiten das erlauben.

## L2. Git-Worktrees

- Jeder Agent-Lauf auf eigenem Branch/Worktree, vorzugsweise benannt `software-regisseur/<task-id>/<job-short-id>`.
- Worktrees in getrenntem kontrolliertem Pfad außerhalb des rekursiven Stammordner-Scans, oder beim Scan explizit ausgeschlossen.
- Bestehende Benutzeränderungen im Stamm-Working-Tree nicht anfassen; vor Start Working Tree prüfen.
- Falls Agent selbst Worktrees erzeugt, Koordinationsstrategie festlegen, um doppelte Worktree-Schichten zu vermeiden.
- Worktree nach Review nur mit Zustimmung integrieren; Git-Status, Diff, Tests, Branch-Konflikte und Merge-Konflikte sichtbar machen.
- Kein automatischer `git push`, Force-Push, Merge auf `main`, Löschen oder Purge ohne explizite Richtlinie/Freigabe.

## L3. Sicherheitsgrenzen

- Prozesse im angemeldeten Benutzerkontext, keine Root-Eskalation.
- `Process` mit explizitem Executable/Argumenten, **keine String-Interpolation in Shell-Kommandos**. Eingaben/Pfade normalisieren und validieren.
- Agenten nur in autorisierten Repo-/Worktree-Verzeichnissen arbeiten lassen, soweit technisch durch Provider und Prozess-Sandbox tatsächlich möglich.
- Agenten-Permissions aus Provider-API prüfen: Lese-/Editzugriff, Netzwerkzugriff, destruktive Operationen, Git, externe Tools.
- Standard: Agent darf Projekt bearbeiten und Tests starten, aber Push/Branch-Löschungen/Secrets-/Systemänderungen brauchen Freigabe.
- Gefährliche „skip permissions“-Optionen niemals als Default oder stille Umgehung einer mobilen Bestätigung verwenden.
- Approval-Wartezeiten und nicht beantwortete Freigaben müssen Jobs sauber pausieren oder fehlerschlagen lassen; keine automatische Freigabe aus Zeitdruck.

---

# M. Review, Historie und Git-Integration

## M1. Abschluss in mehreren Schritten

1. Agent-Prozess endet mit nachvollziehbarem Ergebnis.
2. Mac erfasst geänderte Dateien, Commits, Tests, Logs und ggf. offene Fehler.
3. Auftrag wird `implementation_finished` / `review`; aktive Lauf-Sperre wird nach sicherer Prozessbeendigung freigegeben.
4. Nutzer prüft Diff/Zusammenfassung/Teststatus am Mac; auf iPhone mindestens geeignete kompakte Zusammenfassung und Review-/Entscheidungsstatus.
5. Übernahme kontrolliert, Konflikte beheben, Tests erneut validieren. Standard ist **Squash-Merge in den Default-Branch**; pro Projekt umstellbar auf Merge-Commit oder Cherry-pick (`integrationStrategy`, ADR-0015).
6. Nur wenn die Änderung **im Default-Branch angekommen ist und der Benutzer freigegeben hat**, wird die Request-Datei in `done` verschoben und der endgültige Abschlusszeitpunkt gespeichert.

## M2. Nachvollziehbarkeit

Für jede Aufgabe sichtbar:

- Wann angelegt, diktiert, KI-ausgearbeitet und freigegeben.
- Statuswechsel und beteiligtes Gerät/Agent (soweit bekannt).
- Job-IDs, Agentenprovider, Versionsinformationen, Session-Referenzen.
- Branch, Worktree, relevante Commit-Hashes und ggf. Pull Request.
- Testläufe, Ergebniszusammenfassung, Genehmigungen, Fehlversuche, Kontingentpausen.
- Wer/wodurch die Aufgabe als erledigt markiert hat; nie allein aus dem Verschieben einer Datei blind auf ein erfolgreiches Merge schließen.

## M3. GitHub Issues (optional aktivierbare v1.0-Integration)

- **Funktion gehört zu Version 1**, kann pro Projekt deaktiviert sein.
- Verknüpfung von lokalen Requests mit GitHub Issues (ID/URL), Import/Export, bidirektionaler Metadaten-/Statusabgleich mit klarer Konfliktregel.
- Keine erzwungene GitHub-Nutzung für lokale Projekte; GitLab/sonstige Remotes sind kein Hinderungsgrund für Kernfunktionen.
- GitHub-Authentifizierung sicher, minimale Berechtigungen, Token nicht in Repo/CloudKit. **Festlegung (ADR-0016):** Der Mac verwendet das vorhandene Login der GitHub-CLI `gh`; Software Regisseur speichert kein eigenes GitHub-Token. Ohne installiertes/angemeldetes `gh` ist die Funktion mit Erklärung deaktiviert. Das iPhone greift nie direkt auf GitHub zu.
- **Konfliktregel (ADR-0016):** Die lokale Request-Datei ist führend. Abweichende Änderungen auf GitHub werden nicht still verworfen, sondern als Konflikthinweis mit Übernahmemöglichkeit angezeigt.
- Überschreibungen vermeiden: lokale Datei-UUID und GitHub-Issue-ID getrennte Identitäten.
- Bei fehlender GitHub-Verbindung lokale Nutzung ungestört, Sync später nachholen.

---

# N. Synchronisierung und Konsistenz

## N1. CloudKit-Daten

Synchronisieren: Projekte (ohne lokale Geheimnisse), generische Aufgaben-/Request-Metadaten und Inhalte, ADR-Index, Benutzerkonfiguration/Ordnerregeln, dokumentierte Status-Events, Jobs/Queue-Wünsche, AgentCapabilities, Host-Heartbeat, Reviewentscheidungen, Abhängigkeiten, zuletzt bekannte Ausführungszustände.

**Nicht** synchronisieren: API-Key-Klartext, Auth-Tokens, ganze Git-Repositories, Worktrees, unredigierte Agentenprozess-Umgebungen, sensible Logs, ausgewählte lokale Bookmarks in unpassender Form.

## N2. Verantwortlichkeiten

- **iPhone** darf mobile Requests, Entwürfe, Prioritäten, Freigaben, Job-Wünsche erzeugen.
- **Mac Execution Host** ist die maßgebliche Stelle für lokale Dateipfade, Git-Wahrheit, aktive Prozesse, Locks, Job-Zustände und Umsetzung ins Repo.
- **Markdown in Git** ist maßgeblich für fertig materialisierte Anforderungs-/ADR-Dateien, einschließlich manuell vorgenommener Edits. Der Mac reconciled diese mit App-Daten.
- Bei gleichzeitig mobil und extern geänderten Texten kein stilles Last-Writer-Wins mit Datenverlust; Versionen/Konfliktkopien, 3-Way-Diff oder Benutzerentscheidung.

## N3. Sync-Technik

- Eindeutige IDs, Änderungs-Revision/ETag/CKRecord change tags, Änderungszeit, Operation-ID, Replay-Schutz und Tombstones.
- Outbox-/Inbox-Queue lokal dauerhaft; Operationen idempotent und nach Absturz wiederholbar.
- Bei App-Start, App-Foreground, Pull-to-Refresh und Dienst-Poll explizit `fetchChanges`/`sendChanges`-ähnliche Pfade; CloudKit-Limits/Backoff respektieren.
- Keine sichtbaren Push-Benachrichtigungen. Kein Bedarf, dass der Benutzer iOS-Push-Rechte erteilt. Die App darf **nicht** sofortige iOS-Hintergrundzustellung versprechen: iOS kann im Hintergrund keine beliebig häufigen Polls garantieren.
- Falls ein Framework intern stille CloudKit-Notifications benutzt, darf dies den Produktwunsch „keine Push-Benachrichtigungen“ nicht verletzen und darf nicht alleinige Basis kritischer Jobzustellung sein. Im Dokumentations-/UI-Text klar zwischen Nutzer-Push und interner Synchronisation unterscheiden.
- Bei Offline-Mac bleiben Aufgaben als `pendingMac`/`scheduled` bestehen. Sie werden nach Verfügbarkeit übernommen, ohne versehentliche Doppelausführung.
- Konflikte bei simultaner Statusänderung und Git-Dateiverschiebung sauber erkennen und beheben.

## N4. Geräte- und Hostmodell

- Mehrere iOS-Geräte möglich.
- Falls mehrere Macs mit überlappenden Repos angemeldet sind: pro Projekt eindeutigen **Execution Host** festlegen. Host-Wechsel muss Sperren/Jobs übergeben oder warten lassen. Keine unkoordinierte Ausführung auf zwei Macs.
- Gerät-/Hoststatus mit letztem echten Kontakt und kompatiblen Capabilities anzeigen.

---

# O. Konkrete Domänenmodelle (Mindestumfang)

Die folgenden Modelle als vollständig versionierte und testbare Domäne implementieren, nicht nur als UI-Strings:

| Entität | Wesentliche Felder |
|---|---|
| `Project` | `id`, `name`, `repositoryIdentity`, `remote`, `hostId`, `status`, `settingsId`, `createdAt`, `updatedAt` |
| `RepositoryLocation` | `projectId`, `hostId`, `canonicalPath`, `bookmarkReference`, `scanState`, `lastScanAt` |
| `ProjectSettings` | `adrPath`, `requestsRoot`, `openPath`, `activePath`, `reviewPath`, `donePath`, `defaultAgentId`, `agentModelPreferencesByProvider`, `allowParallel`, `reviewPolicy`, `integrationStrategy`, `agentInstructionsPolicy` |
| `WorkItem` | `uuid`, `humanId`, `projectId?`, `type`, `title`, `originalNote`, `transcript?`, `structuredBody`, `status`, `priority`, `labels`, `dependencies`, `revision`, `timestamps` |
| `ADR` | `uuid`, `projectId`, `decisionNumber`, `status`, `context`, `decision`, `alternatives`, `consequences`, `supersedes` |
| `AudioNote` | `id`, `workItemId?`, `localAssetRef`, `provider`, `consent`, `transcriptionState`, `retentionPolicy` |
| `AIRequest` | `id`, `itemId`, `provider`, `model`, `mode`, `inputVersion`, `draftVersion`, `usage`, `costEstimate?`, `state` |
| `AIConversation` | `id`, `itemId`, `provider`, `model`, `messages`, `contextScope`, `proposedDraftVersion?`, `usage`, `createdAt`, `updatedAt` |
| `AgentHost` | `hostId`, `name`, `lastSeen`, `ready`, `agentCapabilities`, `serviceVersion` |
| `AgentCapability` | `providerId`, `version`, `installed`, `runnable`, `authenticated`, `supportsRemote`, `supportsResume`, `supportsModelSelection`, `supportsEffortSelection`, `modelCatalog`, `modelEffortMatrix`, `capabilityRevision`, `lastChecked` |
| `AgentModelCapability` | `providerId`, `modelId`, `displayName`, `supportedEffortIds`, `defaultEffortId?`, `availability`, `source`, `lastValidatedAt` |
| `AgentModelPreference` | `scope` (`global`/`project`), `providerId`, `modelId?`, `effortId?`, `inheritsDefault`, `updatedAt` |
| `AgentJob` | `jobId`, `idempotencyKey`, `projectId`, `workItemId`, `hostId`, `providerId`, `requestedModelId`, `requestedEffort`, `resolvedModelId`, `resolvedEffort`, `effectiveModelId?`, `effectiveEffort?`, `capabilityRevision`, `configSnapshot`, `scheduledAt?`, `state`, `retryCount`, `sessionId?`, `branch?`, `worktreePath?`, `startedAt?`, `finishedAt?` |
| `TaskLock` | `lockId`, `taskId`, `jobId`, `hostId`, `lease`, `heartbeat`, `recoveryState` |
| `TaskEvent` | `eventId`, `workItemId`, `kind`, `actor`, `timestamp`, `payload`, `sourceRevision` |
| `Review` | `reviewId`, `jobId`, `diffSummary`, `testResults`, `decision`, `approvedAt?`, `integrationCommit?` |
| `SyncOperation` | `operationId`, `entityId`, `type`, `version`, `state`, `attempts`, `lastError` |
| `ProviderProfile` | `id`, `providerId`, `purpose`, `model`, `keychainReference`, `deviceScope`, `settings` |
| `GitHubIssueLink` | `workItemId`, `repo`, `issueNumber`, `url`, `lastSyncedRevision` |

Regeln: stabile UUIDs, atomare Updates, schema-migrationsfähige Speicherung, Trennung von benutzereditierbarem Text und Execution-Metadaten, kein CloudKit-Record mit lokal unbrauchbarem `URL` als alleinige Projektidentität.

---

# P. UI/UX-Anforderungen

## Gemeinsame Qualität

- Native macOS-/iOS-Interaktionsmuster statt Webview-Dashboard.
- Einheitliche Terminologie, konsistente Statusbezeichnungen, Farben/Symbole ergänzen Text, nicht ersetzen.
- **Sprache:** v1 wird nur auf Deutsch (Österreich) ausgeliefert. Alle Oberflächentexte liegen in String Catalogs, damit Englisch später ohne Codeänderung ergänzt werden kann; keine hart kodierten UI-Strings.
- Hell/Dunkel, Dynamic Type, VoiceOver, Tastaturbedienung am Mac, Fehlermeldungen mit konkreten Handlungsmöglichkeiten.
- Große Projektbestände performant: Lazy Loading, Suche, Index/Pagination, keine Blockade der UI durch Repo-Scans.
- Kein UI-Element ohne implementierte Funktion; aktive Arbeit und Fehlzustände stets transparent.

## iPhone-Ansichten

1. **Übersicht:** alle Projekte, aktive Agenten, geplante Aufgaben, offene Reviews, zuletzt abgeschlossene Arbeiten.
2. **Projekte:** Suche, Ordnerzuordnung, Neu/Verknüpfen, fehlender Mac-Host.
3. **Inbox:** spontane Notizen ohne Projekt, schnell aufnehmen und später zuweisen.
4. **Aufgaben:** Typ, Status, Priorität, Detail, Originaltext, AI-Entwürfe, Abhängigkeiten, Historie.
5. **Diktat:** Apple vs API, Aufnahme, Transkript korrigieren, KI-Ausarbeitung.
6. **Agenten:** automatisch erkannte Codex/Claude-Optionen, **Modell-/Denkstufenwahl vor jedem Start, inkl. Projekt-/Globalstandards**, Start-/Zeitplanung, Remote-Session-Link, Wartestatus.
7. **Review:** Ergebniszusammenfassung, Tests, Branch/Commit-Link, Freigabe-Workflow; große Diffs primär am Mac.
8. **Einstellungen:** BYOK, Provider-/Modellwahl, Diktat, Sync, Ordnerdefaults, Standardagent, Kostenhinweise.

## macOS-Ansichten

1. Menüleiste (Abschnitt D).
2. Haupt-Dashboard und projektübergreifende Kanban-/Tabellen-Ansichten.
3. Git-Projektverwaltung mit Stammordnern, Scanner, Imports und Migrationsvorschauen.
4. Request-/ADR-Editor und Markdown-Vorschau/Diff.
5. Warteschlangenansicht mit zeitgeplanten, aktiven, pausierten und fehlgeschlagenen Jobs.
6. Agentenverwaltung mit Capability-/Installationsdiagnose, **Modellkatalog, Effort-Matrix und Standardprofilen** und Remote-App-Verknüpfung.
7. Review/Git-Worktree-/Diff-/Testansichten.
8. Einstellungen und Datenschutz/Sicherheit/Release-Status.

---

# Q. Sicherheit, Datenschutz, Fehler und Release

## Q1. Bedrohungsmodell und Berechtigungen

Mindestens Risiken für lokale untrusted Repos/AGENTS.md, Prompt Injection aus Markdown, Shell/Path Injection, unberechtigte CloudKit-Jobwünsche, verlorene API-Keys, Git-Datenverlust, doppelte Agentenstarts, Approval-Missbrauch, automatisches Pushen und fehlerhafte Repo-Pfade modellieren.

- Nur eigene iCloud Private Database; Projekt-/Host-Operationsberechtigung über Benutzerkonto, Host-Zuordnung, idempotente IDs und server-/clientseitige Plausibilitätsprüfung.
- Keine automatische Ausführung bloß weil fremder Markdown-Inhalt dazu auffordert.
- Secrets-Redaction bei Logs, AI-Prompts, Diagnostik und Crashreports.
- Datenschutz: optionales Speichern von Audio, eindeutige Einwilligung für Drittanbieterübermittlung, transparente Löschung und Export.
- Git-Operationen vorher prüfen; ggf. anwendbare Revert-/Backup-Funktion.
- Bei Netzwerkfehlern, Keychain-Sperre, Provider-Rate-Limit, App-Absturz und CloudKit-Konflikt Daten erhalten.
- Authentifizierungs-/Versionsprobleme der Agenten sauber anzeigen und alternative Handlung bieten.

## Q2. Sandbox-Entscheidung

1. Einfache Sandbox-Probe für user-selected Folder mit Security-Scoped Bookmarks durchführen.
2. Externe `codex`-/`claude`-Prozesse, Login Item, Git und Berechtigungsfluss auf echten Macs testen.
3. Falls kein stabiler, zulässiger komplett sandboxed Betrieb: Mac-UI optional sandboxed, Agent Service gezielt separat; falls unzweckmäßig, Developer-ID-notarisiert ohne Sandbox.
4. Ergebnis in ADR dokumentieren, inklusive Trade-offs; nicht vorspiegeln, Notarisierung verlange App Sandbox.

## Q3. Direktvertrieb macOS

- Signing mit **Developer ID Application**, Hardened Runtime, Notarisierung via dokumentiertem Apple-Workflow, Ticket-Stapling, `spctl`-/`codesign`-Verifikation.
- UI und eingebettete Login Items/Helper korrekt signieren; notarisierten Installer/DMG auf sauberem Test-Mac testen.
- Reproduzierbares Release-Skript und nachvollziehbare Versionsnummern; kein hart kodierter fremder Team-Identifier.
- Automatisches Update nur wenn signiert, sicher und nachprüfbar; ansonsten klare Update-Anleitung. Keine ungesicherte Remote-Codeausführung für Updates. **Festlegung (ADR-0017):** Updates über Sparkle mit EdDSA-signiertem Appcast über HTTPS, gehostet in GitHub Releases eines öffentlichen Repositorys; Update-Pakete zusätzlich Developer-ID-signiert und notarisiert. Der private EdDSA-Schlüssel liegt nur im Keychain des Release-Macs.

## Q4. iOS-Distribution

- Korrekte Microphone/Speech-Nutzungsbeschreibungen, iCloud-Entitlements, Keychain-Nutzung und Privacy-Metadaten.
- **Eigene Erklärbildschirme vor System-Berechtigungsabfragen** (App Review Guideline 5.1.1(iv); gilt für iOS und macOS und für jede Berechtigung, z. B. Mikrofon, Spracherkennung, Ordnerzugriff):
  - Der Fortsetzen-Button ist neutral beschriftet („Weiter“), nie „Erlauben“, „Zugriff gewähren“ o. Ä.
  - Auf diesem Schritt gibt es keine Möglichkeit zum Aufschieben oder Überspringen („Später“, „Nicht jetzt“, Schließen-Button). Solche Optionen erst nach der Systemabfrage.
  - „Weiter“ löst die Systemabfrage sofort aus – auf jedem Pfad, auch bei Abkürzungen durch wiederhergestellte oder vorkonfigurierte Einrichtung.
  - Nach Ablehnung: erklären, welche Funktion nicht verfügbar ist, und einen Link in die Einstellungen anbieten statt erneut zu fragen.
- Keine Abhängigkeit vom Direktvertriebsmodell der Mac-App.
- Lokale API-Key-Konfiguration und externe Audio-/KI-Datenübertragung benutzerverständlich erklären.

---

# R. Teststrategie und verbindliche Abnahmekriterien (v1.0)

Codex muss automatisierte Tests plus echte manuelle End-to-End-Nachweise liefern. Mindestens folgende Szenarien:

| ID | End-to-End-Szenario | Muss-Ergebnis |
|---|---|---|
| A01 | Mac-App startet nach Login ohne Hauptfenster | Menüsymbol vorhanden, Agent Service aktiv, Einstellungen erreichbar |
| A02 | Benutzer wählt Git-Stammordner mit mehreren Repos | Repos korrekt erkannt, keine Worktree-/Submodule-Duplikate, UI bleibt responsiv |
| A03 | Neues Projekt am iPhone in erkanntem Ordner | CloudKit-Job → Mac-Validierung → Verknüpfung/optional Git-Init → sichtbarer Status |
| A04 | Extern im Repo manuell geänderter Request | Dateiüberwachung/Reconciliation → App → iPhone übernimmt Änderung ohne Datenverlust |
| A05 | Konfigurationswechsel `docs/requests` → anderer Pfad | Vorschau, sichere Migration, aktualisierter managed AGENTS-Block, keine zerstörten Regeln |
| A06 | Import bestehender AGENTS.md/CLAUDE.md/ADRs | Bestehende Texte bleiben erhalten, keine unerlaubten Modifikationen |
| A07 | Todo per Apple-Diktat | Korrektes Transkript/Fehlerhandling, Aufgabe speicherbar |
| A08 | Todo per OpenAI Audio API | API-Key am iPhone, Audio-Upload mit Einwilligung, Transkript und Korrektur |
| A09 | Kurze Notiz per OpenAI/Anthropic/Gemini ausarbeiten | Strukturierter, editierbarer Entwurf; Original bleibt unverändert |
| A10 | iPhone ohne Mac verfügbar | Notiz/Entwurf/Jobwunsch lokal persistent; nach Mac-Start genau einmal übertragen |
| A11 | Git-Projektkontext für KI verwenden | Relevanter Kontext, Secrets-Filter, transparenter Umfang und echte generierte Aufgabe |
| A12 | Codex/Claude installiert bzw. deinstalliert | Mac-Detection aktualisiert iPhone-Agentenauswahl korrekt |
| A13 | Sofortiger Codex-Lauf | Worktree, Lock, Agent-Prozess, Ergebnis/Session und Reviewstatus korrekt |
| A14 | Sofortiger Claude-Code-Lauf | Dokumentierter zulässiger Startmodus, Worktree/Lock/Review und mobile Link-/Fallbackfunktion |
| A15 | Gleiche Aufgabe zweimal schnell starten | Nur ein Lauf; zweiter Wunsch wird verhindert/sauber behandelt |
| A16 | Zwei verschiedene Aufgaben parallel | Getrennte Worktrees/Branches, kein Cross-Write, Limits beachten |
| A17 | Start für morgen 07:00 planen | Persistente Queue; einmaliger korrekter Start, Zeitzone korrekt |
| A18 | Zum Startzeitpunkt Mac ausgeschaltet | Kein falsches „läuft“, definierte Nachholregel bei Wiederverfügbarkeit |
| A19 | Kontingent erreicht | `waiting_quota`, sinnvolle Retry-Regeln, kein Spam/Doppellauf |
| A20 | Agent braucht Approval | Pausierter Status, keine stillschweigende Genehmigung; ggf. offiziell mobil bedienen |
| A21 | Agent wird abrupt beendet/App crasht | Recovery, Locks und Jobzustand konsistent, kein Datenverlust |
| A22 | Fertiger Agentenlauf | Aufgabe `review`, nicht `done`; Diff und Tests sichtbar |
| A23 | Benutzer übernimmt Änderung und gibt frei | Integration/Commit nachvollziehbar, Aufgabe ins `done`-Verzeichnis, iPhone zeigt Abschluss |
| A24 | Mac und iPhone bearbeiten dieselbe Aufgabe offline | Konflikt sichtbar, keine stille Überschreibung |
| A25 | GitHub Issues eingeschaltet | Issue verknüpfbar/importierbar/synchronisierbar, fehlendes GitHub hält lokale App nicht auf |
| A26 | Nutzer erhält keine sichtbare Push-Nachricht | Status manuell/bei App-Foreground synchronisierbar, UI zeigt Sync-Zeitpunkt |
| A27 | Schlüsselprüfung und Löschen | Keychain sicher, kein Klartext in Logs/Git/CloudKit, Funktionen degradieren verständlich |
| A28 | Signing-/Notarisierungsrelease | Developer-ID-Build samt Helper signiert, notarisiert, auf frischem Mac startbar |
| A29 | Deutsche iPhone- und macOS-Oberflächen | Accessibility, Dark Mode, Dynamic Type, Fehler-/Leerzustände geprüft |
| A30 | Git-Verlustschutz | Keine ungefragten Pushes/Force-Resets/Löschungen, Worktree-Integration prüfbar |
| A31 | Mobile Weiterführung Codex | Realer Spike mit Beweis: automatisch gestartete Sitzung in offizieller App möglich **oder** dokumentierter, nutzbarer V1-Fallback ohne falsche Behauptung |
| A32 | Mobile Weiterführung Claude | Realer Spike mit Beweis: offizieller Remote-Control-Workflow inkl. Grenzen, ggf. V1-Fallback |
| A33 | Mehrere Macs bzw. Hosts | Ein definierter Ausführungshost pro Projekt; kein Doppelstart durch Host-Rennen |
| A34 | Datenauskunft und Löschen | Export aller Projekte/Requests/ADRs/Events; lokale Daten/Audios/Schlüssel kontrolliert löschen |
| A35 | Codex-Modellwahl | Unterstützte Modelle der installierten Codex-Version werden am Mac erkannt und am iPhone auswählbar |
| A36 | Claude-Code-Modellwahl | Tatsächlich unterstützte Claude-Code-Modelle werden separat erkannt, ohne Codex-Modelle zu vermischen |
| A37 | Stufen pro Modell | `auto` und nur verfügbare `low`/`medium`/`high`/`xhigh`/`max`-Stufen je Kombination wählbar; keine Pseudo-Option |
| A38 | Globale, Projekt- und Job-Voreinstellungen | Priorität Job > Projekt > global > Provider; Änderungen vererben sich nur an neue Jobs |
| A39 | Geplanter Job mit fixierter Auswahl | Modell/Effort-Snapshot bleibt über iCloud, Mac-Neustart, Zeitplanung und Retry identisch |
| A40 | Modell/Agent-Upgrade bzw. Wegfall der Unterstützung | Aktualisierte Capability-Matrix; inkompatibler Job blockiert vor Start und bietet begründete Neuauswahl |
| A41 | Wirksame Konfiguration | Reale Codex-/Claude-Ausführung erhält nachweislich korrekte unterstützte Modell-/Effort-Parameter; effektive Werte im Verlauf belegbar |
| A42 | UI- und Sync-Grenzfälle | iPhone offline/Mac offline, veralteter Modellkatalog, Agent ohne Effort-Unterstützung und fehlende Accountberechtigung klar dargestellt |

### Automatisierte Tests

- Unit: Dateipfade, UUID/ID-Erzeugung, YAML/Markdown-Parser, Statusmaschine, Regeln, Retry, Zeitzonen, Abhängigkeiten, Provider-Capabilities, **Modell/Effort-Vererbung und Kombinationen**.
- Integration: Git-Worktrees/Branches/Commits auf temporären Testrepos, Locks/Crash-Recovery, CloudKit-Adapter mit Fake und realem Testcontainer, Keychain-Grenzen.
- UI: iPhone-Flows und Mac-Menüleiste; Accessibility/VoiceOver-Durchläufe.
- Agenten: MockProvider für CI; zusätzlich reale Codex-/Claude-Tests auf konfigurierten Entwickler-Macs.
- Security: Repo-Traversal, Symlinks, Shell-Argumente, Prompt-Injection, Secret-Leaks, Doppel-Ausführung, inkompatible Provider-Versionen.
- Performance: viele Repositories/Tasks, große Dateien, langsames Netz, Synchronisations-Races.

**Abnahmebericht:** jede A01–A42-Zeile als `passed`, `failed` oder `blocked-by-external-dependency` mit Beleg; kein „alles fertig“ bei fehlenden realen Tests.

---

# S. Implementierungsplan für Codex (Meilensteine – alle Teil von Version 1)

> Die folgenden Meilensteine sind **Implementierungsreihenfolge**, keine Release-Phasen oder Funktionsstreichungen.

## M0 – Capability-Spikes und ADRs

- **Alle vorhandenen ADRs unter `docs/adr/` lesen**; bestehende Entscheidungen nicht als noch zu treffende offene Frage behandeln. `proposed`-ADRs mit nachvollziehbaren Spikes validieren. Bei Abweichung neuen ADR schreiben und Vorgänger explizit ablösen.
- Für Codex und Claude Code echte dynamische Modell-/Effort-Capabilities und deren Übergabe an den jeweiligen Starter nachweisen (keine hartkodierten Model-ID-Listen).
- Hersteller-APIs und die aktuelle Lizenz-/Privacy-Lage prüfen.
- Codex app-server/CLI-Session und offizielle mobile ChatGPT-/Codex-App auf echte Interoperabilität testen.
- Claude Remote Control versus programmgesteuerter Start und offizielle mobile Claude-App end-to-end testen.
- macOS Sandbox-/unsandboxed Helper-Prototyp, Login-Agent und Notarisierungsanforderungen erproben.
- CloudKit-Design ohne Abhängigkeit von sichtbaren Push-Nachrichten nachweisen.
- Entscheidungen als ADRs festhalten; bei blockierten externen APIs V1-Fallbacks konkret definieren.

## M1 – Projektgrundlage & Persistenz

- Xcode Workspace/Targets, Shared Swift Packages, Testtargets, CI.
- Domänenmodelle, Datenbankschema, Migrationsmechanismus, CloudKit-Sync und Queue.
- macOS-Menüleiste, Hauptfenster, Hintergrunddienst-IPC und Login Service.

## M2 – Projekte, Markdown und Anweisungen

- Git-Discovery, Projektanlage/-Link vom iPhone, Folder-Watcher, Markdown-Parser/Writer, Status-/Folder-Mapping, Import vorhandener Strukturen.
- AGENTS.md Managed Blocks, Claude-Anweisungsintegration, Migrationsvorschau.

## M3 – iOS Diktat und KI

- Schnellerfassung, Inbox, Apple-Sprache, API-Audio-Transkription mit eigener Keychain-Konfiguration.
- OpenAI/Anthropic/Gemini-Textbearbeitung, Klassifizierung, AI-Draft-Review, Multi-Task-Splitting, Kontextmodus vom Mac.

## M4 – Agenten und Jobs

- Codex/Claude-Discovery, **verfügbare Modelle/Denkstufen je Agent/Modell, globale+Projekt+Job-Overrides und persistente Konfigurations-Snapshots**, Provider-Abstraktion, mobile Auswahl, Worktrees, Lock-/Queue-State-Machine, Scheduling, Quota-Retry, Session/Approval/Remote-Links.
- Integration der nachgewiesenen offiziellen Mobile-Workflows bzw. echten Fallbacks.

## M5 – Review, Dashboard, GitHub und Historie

- Git-Diffs, Testresultate, Review-/Integrationsworkflow, Commits/Branch-Historie, Kanban/Dashboard, GitHub-Issues-Option.

## M6 – Release-Qualität

- Alle A01–A42 erfüllen bzw. extern blockierte Randbedingungen **mit verifiziertem, für Benutzer brauchbarem Fallback** ausweisen.
- UI-Polish, umfassende Tests, Accessibility, Sicherheitsreview, Dokumentation, signierter/notarisierter macOS-Release, iOS-Distributionskonfiguration.

Bei jeder Meilenstein-Grenze: Build grün, Tests grün, Änderungen versioniert, keine beschädigten bestehenden Repos, Fortschritt dokumentiert.

---

# T. Vorgeschlagene Monorepo-Struktur

```text
SoftwareRegisseur/
├── README.md
├── Software_Regisseur_1.0_Codex_Entwicklungsauftrag.md
├── AGENTS.md
├── SoftwareRegisseur.xcworkspace
├── Apps/
│   ├── SoftwareRegisseur-iOS/
│   └── SoftwareRegisseur-macOS/
├── Services/
│   └── SoftwareRegisseurAgentService/
├── Packages/
│   ├── SoftwareRegisseurDomain/
│   ├── SoftwareRegisseurPersistence/
│   ├── SoftwareRegisseurSync/
│   ├── SoftwareRegisseurGit/
│   ├── SoftwareRegisseurMarkdown/
│   ├── SoftwareRegisseurAI/
│   ├── SoftwareRegisseurAgents/
│   └── SoftwareRegisseurDesignSystem/
├── Tests/
│   ├── Unit/
│   ├── Integration/
│   ├── E2E/
│   └── Fixtures/
├── docs/
│   ├── architecture/
│   ├── adr/
│   │   ├── README.md
│   │   ├── TEMPLATE.md
│   │   └── 0001-*.md ... 0011-*.md
│   ├── security/
│   ├── integration-spikes/
│   └── release/
├── Scripts/
│   ├── build.sh
│   ├── test.sh
│   ├── sign-and-notarize.sh
│   └── verify-release.sh
└── .github/
    └── workflows/
```

Die Ordnerstruktur kann aus guten technischen Gründen angepasst werden, muss dann aber über ADR/README dokumentiert werden. Keine externen Runtime-Dienste ohne klaren Mehrwert hinzufügen. Xcode-Projekt muss tatsächlich öffnen und beide Apps/Helper bauen.

---

# U. Ablaufbeispiele, die v1.0 vollständig beherrschen muss

## U1. Spontane Idee unterwegs

1. Nutzer öffnet iPhone-App, tippt Mikrofon und diktiert: „Die Senderliste am iPad ist zu klein; kompakte und große Ansicht mit Speicherung.“
2. Nutzer wählt Apple-Diktat oder OpenAI-Transkription per eigenem API-Key.
3. Transkript erscheint editierbar; Originalnotiz bleibt erhalten.
4. „Mit KI ausarbeiten“ erzeugt einen Feature Request mit Titel, Anforderungen und Tests.
5. Nutzer korrigiert und gibt Entwurf frei.
6. Request wird unter dem gewählten Projekt (oder zunächst Inbox) gespeichert und über CloudKit synchronisiert.
7. Mac schreibt `FR-...md` in den global/individuell konfigurierten `open`-Pfad.

## U2. Codex später starten wegen Kontingent

1. Nutzer wählt den Request am iPhone und „Mit Codex umsetzen“.
2. Codex ist durch Mac-Agentendetektion als bereit erkannt; Nutzer wählt „morgen um 07:00“.
3. Mac persistiert die Queue samt Task-ID/Agent/Host/Zeitzone.
4. Zum geplanten Zeitpunkt wird Sperre erworben und Worktree erstellt, Codex nach dokumentierter Schnittstelle gestartet.
5. Nutzer kann Status sehen und – wenn real verifiziert – die passende Sitzung in offizieller mobiler Codex-App fortführen; sonst klarer alternativer Workflow.
6. Agent beendet seine Implementierung, Task erscheint unter `review`, Tests/Diff sichtbar.
7. Benutzer gibt Übernahme frei; Integration wird geprüft, anschließend `done` und mit Abschlussdatum am iPhone angezeigt.

## U3. Claude Code mit offizieller mobiler Interaktion

1. Nutzer wählt denselben Vorgang mit Claude Code, sofern installiert, angemeldet und Remote Control zulässig.
2. Mac startet dokumentierte lokale Remote-Control-Sitzung oder den technisch nachgewiesenen Workflow.
3. Nutzer öffnet offizielle Claude-App per gültigem Sessionlink und interagiert mit der **tatsächlich laufenden** Sitzung.
4. Mac erfasst Job-Abschluss und synchronisiert Review. Falls Remote Control den programmgesteuerten Erstprompt nicht unterstützt, muss die UI diese Grenze klar und nutzbar abbilden.

## U4. Externe Git-Änderung

1. Entwickler oder Coding-Agent verändert eine bestehende Request-Datei direkt im Git-Repo.
2. Mac-Watcher/Reconciliation erkennt Status-/Textänderung, validiert Frontmatter und vorhandenen Lock.
3. Datenbank und iCloud spiegeln tatsächliche Dateiänderungen; bei konkurrierenden mobilen Edits erscheint Konfliktlösung.

---

# V. Dokumentations- und Lieferumfang

Codex liefert in demselben Repository:

1. Vollständig kompilierbare iOS-App, macOS-App und nötige Hintergrundkomponente(n).
2. Gemeinsame getestete Libraries, Datenbankmigrationen, CloudKit-Schema/Entitlements und klare Setup-Anleitung.
3. Funktionen für Projekt-Scan, Markdown, `AGENTS.md`/Claude-Anweisungen, Diktat, AI, Agenten, Scheduling, Reviews, GitHub-Integration.
4. Sichere Konfigurations-/Keychain-/Provider-Logik, ohne hart kodierte reale Tokens.
5. Tests, Fixtures, lokale Fake-Provider und E2E-Anleitungen für reale Agenten.
6. Release-Skripte für Developer-ID-Signierung, Notarisierung und Verifizierung.
7. `README.md` mit Installation, Erstkonfiguration, Stammordner, API-Keys, Agenteninstallation, Remote-Control-Anforderungen, Mac-Betrieb, Einschränkungen und FAQ.
8. **Mitgelieferte, versionierte ADRs** im Ordner `docs/adr/`, Index und Template; technische Prüfungen mit neuen ADRs/Ergänzungen fortführen, keine widersprüchlichen Entscheidungen in separaten Dokumenten vergraben.
9. Bericht zu verifizierten/noch nicht verifizierbaren Third-Party-Integrationen inkl. funktionierender Alternativen.
10. Abschluss-Matrix aller Anforderungen A01–A42 mit Testergebnissen.

## Abschlussanweisung an Codex

**Lies zuerst `AGENTS.md`, diesen Entwicklungsauftrag und alle `accepted`-ADRs unter `docs/adr/`. Beginne danach mit der Bestandsaufnahme und den Capability-Spikes, erstelle danach die vollständige Projektstruktur und entwickle sämtliche Funktionen bis zur v1.0-Abnahmereife. Arbeite weiter, statt nach jedem Teilmodul nur Vorschläge zu liefern. Respektiere vorhandene Daten, sichere alle Datei-/Git-Eingriffe ab und melde echte Blocker konkret.**

Das Produkt heißt überall **Software Regisseur**. Der Leitgedanke ist: **Idee unterwegs erfassen → mit KI ausarbeiten → im Git-Repository dokumentieren → installierten Agenten auswählen → sicher sofort oder später umsetzen → in der offiziellen Agenten-App weiterarbeiten, wo unterstützt → Ergebnis prüfen → nachvollziehbar abschließen.**

---

# W. Primäre technische Referenzen zur Prüfung während der Entwicklung

Die folgenden URLs sind Ausgangspunkte, **keine Garantie für unveränderliche APIs**. Vor Implementierung aktuellen Stand und konkrete Versionen prüfen:

- Apple SwiftUI `MenuBarExtra`: https://developer.apple.com/documentation/swiftui/menubarextra
- Apple `SMAppService`: https://developer.apple.com/documentation/servicemanagement/smappservice
- Apple App Sandbox / Security-Scoped Bookmarks: https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox
- Apple CKSyncEngine `fetchChanges`: https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/fetchchanges(_:)
- Apple Notarisierung: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- Codex als Plattform / app-server: https://developers.openai.com/blog/codex-as-a-platform
- OpenAI Audio Transcription: https://developers.openai.com/api/docs/guides/speech-to-text
- Claude Code Dokumentation: https://code.claude.com/docs/en/remote-control
- Claude mobile Deep Links: https://support.claude.com/en/articles/14898120-open-the-claude-mobile-app-with-a-link
- Claude Code Agent SDK / Lizenzen: https://code.claude.com/docs/en/agent-sdk/overview
- Claude Code Effort und Modellauswahl (offizielle Claude Academy): https://academy.claude.com/tutorials/choosing-the-right-effort-level-in-claude-code
- OpenAI Modellabhängigkeit der Reasoning-/Effort-Stufen: https://developers.openai.com/api/docs/guides/reasoning

**Ende der verbindlichen Spezifikation für Software Regisseur Version 1.0.**
