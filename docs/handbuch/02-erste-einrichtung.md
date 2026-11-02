# 2. Erste Einrichtung

Empfohlene Reihenfolge:

1. Mac: Hintergrunddienst aktivieren ([Kapitel 1](01-installation.md#hintergrunddienst-aktivieren-login-agent)).
2. Mac: Stammordner wählen und scannen lassen.
3. Mac: Projekte prüfen, Vorschläge für `AGENTS.md`/`CLAUDE.md` ansehen und übernehmen oder ablehnen.
4. Mac: Coding-Agenten installieren und anmelden ([Kapitel 4](04-agenten.md)).
5. iPhone/iPad: App öffnen, synchronisieren, API-Schlüssel hinterlegen ([Kapitel 3](03-ki-und-schluessel.md)).

## Stammordner

Ein Stammordner ist ein Ordner auf dem Mac, dessen Unterordner Software Regisseur indiziert, zum Beispiel `~/Developer`.

**Hinzufügen:** Hauptfenster › „Projekte“ › Abschnitt „Stammordner“ › „Hinzufügen …“ und Ordner wählen. Existiert `~/Developer`, bietet die App „Vorschlag übernehmen“ an; übernommen wird er nur auf Ihren Klick. Mehrere Stammordner sind möglich. Ohne Stammordner scannt der Dienst nichts.

**Entfernen:** „Entfernen“ beim jeweiligen Stammordner. Bereits erkannte Projekte werden dabei nicht gelöscht.

Abgelehnt wird ein Stammordner, der die Ablage des Dienstes enthält oder darin liegt (dort liegen die Agenten-Worktrees).

### Was der Scanner tut

- Er indiziert **alle geeigneten Unterordner** bis zur eingestellten **Ordnertiefe**, nicht nur Git-Repositories, und unterscheidet: eigenes Git-Repository, Unterordner eines Repositorys, noch nicht initialisierter Projektordner.
- **Ordnertiefe** (Einstellungen › Dienst › „Ordnertiefe unter Stammordnern“, 1–8, Standard 1): Bei 1 werden nur die Ordner direkt im Stammordner erfasst; ein Repository direkt im Stammordner wird trotzdem als Repository erkannt. Mit mehr Ebenen stehen am iPhone auch Unterordner zur Auswahl. Wird die Tiefe verringert, entfernt der Dienst die wegfallenden Ordner auch aus iCloud. Ordner mit verknüpftem Projekt bleiben erhalten (ADR-0028).
- Er erkennt verschachtelte Repositories, Worktrees, Bare-Repositories und Submodules; Worktrees erscheinen nicht als eigene Projekte.
- Große generierte Ordner wie `node_modules`, `.build`, `DerivedData` und `.git/objects` werden nicht durchsucht; symbolische Links werden zyklussicher behandelt.
- Die Projekt-Identität stammt aus Git-Metadaten, nicht aus dem Ordnernamen. Umbenennen oder Verschieben löscht keine Daten.

**Zeitpunkte:** vollständiger Scan alle 15 Minuten, Dateiüberwachung (FSEvents) laufend, zusätzlicher Abgleich der Markdown-Dateien alle 5 Minuten und auf Wunsch sofort („Scanner aktualisieren“ in der Menüleiste, „Markdown jetzt abgleichen“ im Projekt). Die Intervalle stehen in Einstellungen › „Diensteinstellungen (nur dieser Mac)“.

> **Nicht verifiziert:** Liegen Repositories in `~/Documents`, `~/Desktop`, iCloud Drive oder auf Wechsel-/Netzlaufwerken, kann macOS Datenschutzabfragen zeigen, obwohl der Dienst ohne Sandbox läuft (Spike S5). Das Verhalten ist noch nicht auf echter Hardware geprüft. `~/Developer` ist davon nicht betroffen.

### Projektstatus

| Status | Bedeutung |
|---|---|
| Einrichtung am Mac ausstehend (`pendingMacSetup`) | Vom iPhone angelegt, der Mac hat den Auftrag noch nicht ausgeführt |
| Bereit (`ready`) | Ordner erreichbar, Projekt nutzbar |
| Nicht erreichbar (`unavailable`) | Ordner fehlt oder wurde verschoben – Daten bleiben erhalten |
| Hinweise (`needsAttention`) | z. B. ungültige Dateien, Konflikte, offene Vorschläge |
| Archiviert (`archived`) | Ausgeblendet, wiederherstellbar |

**Neu verknüpfen:** Ist ein Projekt nicht erreichbar, im Projekt „Neu verknüpfen“ › „Kandidaten suchen“ oder „Ordner wählen …“ › „Verknüpfen“. „Anderes Repository zulassen“ nur aktivieren, wenn der neue Ordner bewusst ein anderes Repository ist.

## Projekte anlegen und verknüpfen

### Am Mac

„Projekte“ › „Projekt anlegen oder verknüpfen …“:

- **Vorhandener Ordner** oder **Neuer Unterordner** eines Stammordners.
- Liegt der Ordner in einem bestehenden Repository: Umfang „Ganzes Repository“ oder „Nur diesen Unterordner“.
- **„Git-Repository anlegen (git init)“** wird nur ausgeführt, wenn Sie zusätzlich „Ich stimme zu, dass im Ordner „git init“ ausgeführt wird.“ bestätigen.

### Am iPhone oder iPad

„Projekte“ › „Neues Projekt“. Die iOS-App greift nie direkt auf das Dateisystem des Mac zu; sie erstellt einen Einrichtungsauftrag, den der Mac ausführt, sobald er erreichbar ist.

- Wählbar sind die vom Mac gemeldeten Ordner (auch ohne Git, auch wenn der Mac gerade offline ist) oder ein **neuer Unterordner** eines freigegebenen Stammordners (ohne „/“, „:“ oder führenden Punkt).
- Unterordner eines bestehenden Repositorys: Sie müssen „Ganzes Repository“ oder „Nur dieser Unterordner“ wählen.
- „Git-Repository anlegen („git init“)“ nur mit Ihrer Zustimmung; ohne Zustimmung bleibt der Ordner unverändert.
- Alternativ ein **Projektentwurf ohne Ordner**: Er wird sofort angelegt, Aufgaben lassen sich zuordnen, den Ordner verknüpfen Sie später.

Der Status wechselt von „Einrichtung wartet auf den Mac“ zu „Am Mac eingerichtet“ oder „Einrichtung fehlgeschlagen“. Der Mac prüft jeden Pfad (keine `..`, keine symbolischen Links aus dem Stammordner heraus).

## Ordnerstruktur im Repository

Standard (global und je Projekt änderbar):

```text
<repo>/
├── AGENTS.md
├── CLAUDE.md            # nur wenn vorhanden oder auf Wunsch angelegt
└── docs/
    ├── adr/
    └── requests/
        ├── open/
        ├── in-progress/
        ├── review/
        └── done/
```

Zuordnung von Aufgabenstatus zu Ordnern (Standard):

| Aufgabenstatus | Ordner |
|---|---|
| `inbox`, `open`, `queued`, `scheduled` | `docs/requests/open/` |
| `in_progress`, `waiting_approval` | `docs/requests/in-progress/` |
| `implementation_finished`, `review` | `docs/requests/review/` |
| `integrated`, `done` | `docs/requests/done/` |
| `blocked`, `failed`, `cancelled`, `paused` | Datei bleibt, wo sie ist |

Request-Dateien sind Markdown mit YAML-Frontmatter (`id`, `uuid`, `type`, `status`, `title`, Zeitstempel, `priority`, `labels`, `dependsOn`, …). Unbekannte Felder und eigene Abschnitte bleiben erhalten; ein Statuswechsel formatiert die Datei nicht neu.

**Aufgaben-IDs** ([ADR-0018](../adr/0018-menschenlesbare-ids-vom-mac.md)): Jede Aufgabe hat sofort eine UUID. Die lesbare ID vergibt nur der Mac, wenn er die Datei anlegt: `FR` (Feature), `BUG`, `TODO`, `IMP` (Improvement/Refactoring), `NOTE`, z. B. `FR-0007`. Bis dahin zeigt die App „noch keine Nummer“. ADRs nummeriert der Mac vierstellig ohne Präfix.

**Ändern:**

- Standard für neue Projekte: iPhone › Einstellungen › „Ordnerstandards“ (synchronisiert). Pfade müssen relativ sein und dürfen kein „..“ enthalten.
- Je Projekt am Mac: Projekt › „Ordnerstruktur“ › „Vorschau berechnen“. Die Vorschau zeigt jede Verschiebung, Kollisionen und die Änderung an `AGENTS.md`. Erst „Migration anwenden“ verschiebt Dateien; bei Kollisionen ist das gesperrt. „Vorschau verwerfen“ ändert nichts.

**Keine Commits durch Software Regisseur** ([ADR-0024](../adr/0024-keine-commits-durch-software-regisseur.md)): Der Dienst schreibt und verschiebt Request-, ADR- und Anweisungsdateien im Haupt-Working-Tree, committet sie aber nie. Das tun Sie selbst. Nicht committete Änderungen unterhalb der Dokumentpfade blockieren eine spätere Übernahme von Agentenergebnissen nicht.

## AGENTS.md: verwalteter Block

Software Regisseur pflegt in `AGENTS.md` einen klar begrenzten, versionierten Block. Alles außerhalb der Markierungen ist Ihr Inhalt und wird nie verändert. Bei Standardpfaden sieht der Block so aus:

```markdown
<!-- SOFTWARE-REGISSEUR:BEGIN v2 -->
## Software Regisseur Workflow
- ADRs: docs/adr/
- Open requests: docs/requests/open/
- In progress: docs/requests/in-progress/
- Review: docs/requests/review/
- Done: docs/requests/done/
- Read relevant accepted ADRs before architectural changes.
- Request files and ADRs in the folders above are maintained by Software Regisseur.
- Agents must not create, edit or move request files or ADRs; report status, changes and tests in the final message instead.
- Never commit, push or merge without explicit user approval.
- Do not modify secrets.
<!-- SOFTWARE-REGISSEUR:END -->
```

### Freigabe-Ablauf

1. Vorschläge entstehen beim ersten Scan, für neue Projekte und auf Anforderung; eine Ordnermigration enthält die passende Änderung des Blocks in ihrer Vorschau. **Geschrieben wird nie ohne Ihre Zustimmung.**
2. Mac: Projekt › „AGENTS.md / CLAUDE.md“ zeigt je Datei einen Diff und Warnungen (z. B. nicht committete Änderungen an der Datei).
3. „Übernehmen“ schreibt atomar. Hat sich die Datei seit dem Vorschlag geändert, wird der Vorschlag abgelehnt; mit „Vorschlag neu berechnen“ entsteht ein aktueller.
4. „Ablehnen“ verwirft den Vorschlag; die Datei bleibt unverändert.

Ein älterer Block (`v1`) wird nur über diesen Ablauf auf `v2` gebracht. Sind die Markierungen beschädigt (doppelt, verschachtelt, unvollständig, unbekannte Version), schlägt die App nichts vor und nennt die betroffenen Zeilen. Markierungen in Code-Blöcken (Dokumentationsbeispiele) werden ignoriert.

Codex liest `AGENTS.md` selbst, aber keine `CLAUDE.md`.

## CLAUDE.md: Import

- Eine vorhandene `CLAUDE.md` wird **nie** umgeschrieben. Software Regisseur schlägt höchstens vor, die Zeile `@AGENTS.md` anzuhängen, damit Claude Code die verwalteten Regeln lädt.
- Eine neue `CLAUDE.md` (nur mit diesem Import) entsteht nur, wenn Sie „CLAUDE.md anlegen, falls sie fehlt“ ankreuzen und den Vorschlag übernehmen.
- Der Import wird nur vorgeschlagen, wenn auf dem Mac Claude Code erkannt wurde. Sonst bleibt `CLAUDE.md` unverändert und die App warnt.
- Weitere Warnungen: „CLAUDE.md verweist nicht auf AGENTS.md“ und „CLAUDE.md enthält einen eigenen Software-Regisseur-Block (doppelte Regelquelle)“.

Hintergrund: Claude Code liest `AGENTS.md` erst ab Version 2.1.277 selbst und nur, wenn keine `CLAUDE.md` existiert; der Import funktioniert mit älteren und neueren Versionen ([Spike Claude Code](../integration-spikes/claude-code.md), Befund 10).

## Bestehende Strukturen und ADRs

Vorhandene `AGENTS.md`, `CLAUDE.md`, `docs/adr` und Request-Dateien werden erkannt und nicht ohne Vorschau und Zustimmung verändert, verschoben oder umformatiert. Vorhandene IDs bleiben erhalten; nicht kompatible Dateien werden markiert. Änderungen, die Sie oder ein Agent direkt im Repository machen, erkennt der Dienst und übernimmt sie in App und iCloud. Gleichzeitige Änderungen in der App erscheinen als Konflikt ([Kapitel 5](05-synchronisierung.md#konflikte)).

**Neue ADRs** legt der Mac an (Hauptfenster › „ADRs“): Nummer vom Mac, Text aus der `TEMPLATE.md` des Repositorys, Status `proposed`. Die KI kann ADR-Entwürfe vorschlagen; angenommen wird ein ADR nur durch Sie.

## GitHub Issues (optional)

Pro Projekt aktivierbar (Projekt › „GitHub Issues“ › „GitHub aktivieren“). Voraussetzung ist die GitHub-CLI `gh`, mit der Sie selbst angemeldet sind; Software Regisseur speichert kein eigenes GitHub-Token ([ADR-0016](../adr/0016-github-ueber-gh-cli-lokal-fuehrend.md)). Issues lassen sich verknüpfen, importieren und exportieren. Bei Abweichungen ist die lokale Request-Datei führend; GitHub-Änderungen werden als Konflikt mit Übernahmemöglichkeit angezeigt. Das iPhone greift nie direkt auf GitHub zu.
