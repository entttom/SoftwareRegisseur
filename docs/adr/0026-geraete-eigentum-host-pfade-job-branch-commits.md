---
adr: 0026
title: "Geräte-Eigentum synchronisierter Daten, vom Mac berechnete Pfade und Commits auf dem Job-Branch"
status: accepted
date: 2026-10-30
---

# ADR-0026: Geräte-Eigentum synchronisierter Daten, vom Mac berechnete Pfade und Commits auf dem Job-Branch

**Status:** Accepted  
**Datum:** 2026-10-30  
**Entscheidungsträger:** Implementierung auf Basis Sicherheitsprüfung ([audit-2026-10-30](../security/audit-2026-10-30.md), Befunde SR-SEC-01, -02, -06, -09).

## Kontext

Jedes Gerät im iCloud-Account kann jeden Record der privaten Zone schreiben (Bedrohungsmodell, Annahme A2, Angreifer A-Dev). Bisher hat der Mac-Ausführungshost Mac-eigene Records (Repository-Pfade, Ordnerindex, Jobs, Locks, Freigabeanfragen) nur bei einem Konflikt bevorzugt (`executionHostWins`). Ohne ungesendete lokale Änderung übernahm er jede eingehende Änderung. Er nutzte dann synchronisierte Pfade direkt:

- `RepositoryLocation.canonicalPath` als Repository des Agenten (SR-SEC-01),
- `AgentJob.worktreePath`/`branch` als Arbeitsverzeichnis und für `git add -A`/`git commit` (SR-SEC-02; Angriff: Haupt-Working-Tree mit `main`),
- `AgentJob.branch` bei der Übernahme, ohne Bindung an den geprüften Stand (SR-SEC-06).

ADR-0024 verbietet Commits von Request-/ADR-Dateien durch Software Regisseur und nimmt „Commits des Agenten auf seinem eigenen Job-Branch“ aus. Der Sicherungs-Commit, den der Dienst am Sitzungsende für nicht committete Agentenausgabe macht (`commitAgentChangesOnFinish`), war dort nicht ausdrücklich geregelt (SR-SEC-09).

## Entscheidung

**1. Eigentum je Entitätstyp.** Auf dem Ausführungshost gilt beim Empfang jeder Änderung, auch ohne Konflikt:

| Entität | Andere Geräte dürfen | Nur der Mac (eigene `hostId`) |
|---|---|---|
| Aufgaben, Entwürfe/Draft-Versionen, ADR-Inhalte, Einstellungen (global, Projekt, Modellpräferenzen), Datei-Konfliktauflösungen, GitHub-Verknüpfungen, Provider-Profile | anlegen und ändern (normale Konfliktregeln, ADR-0019) | – |
| `ApprovalDecision` | anlegen (unveränderlich) | – |
| `AgentJob` | **anlegen** nur als Auftrag: Zustand `requested`, Konfigurations-Snapshot, ohne Ausführungsdaten; **ändern** nur Zeitplan, Priorität, Konfiguration eines nicht gestarteten Jobs, Abbruch (`cancelled`) | Zustand nach der Annahme, `hostId`, Branch, Worktree-Pfad, Sitzung, effektives Modell/Effort, Start/Ende, Wiederholungszähler; löschen |
| `Review` (Job dieses Macs) | nur die Review-Entscheidung (`decision`, `approvedAt`) | Diff, Commits, Tests, Head-Commit, Notizen, Konflikt, Integrationsdaten; anlegen, löschen |
| `ProjectSetupCommand` | anlegen als `pending` ohne Ergebnis; Name/Umfang/Einwilligung ändern, solange `pending` | Zustand, Fehler, Ergebnispfad, Ziel, Host; nach Bearbeitung unveränderlich |
| `RepositoryLocation`, `IndexedFolder`, `AgentHost`, `AgentCapability`, `TaskLock`, `PendingApproval` | nichts (nur inhaltsgleiche Echos) | alles |

Records anderer Macs (fremde `hostId`) bleiben Anzeigedaten und werden wie bisher übernommen.

**2. Durchsetzung.** `GRDBSyncStore` prüft mit `RemoteOwnershipPolicy` vor der Konfliktlogik. `SyncCoordinator` aktiviert die Prüfung automatisch in der Rolle `executionHost`. Eine verletzende Änderung wird **nie angewendet**. Sie bleibt als aufgelöster `SyncConflict` sichtbar (Auflösung `rejectedOwnership`, `automaticPolicy`). Existiert der Datensatz lokal, sendet der Mac seinen eigenen Wert erneut über die fremde Server-Version. Mobile Geräte verhalten sich unverändert.

**3. Pfade nur aus dem lokalen Index.** Für Dateisystemzugriffe nutzt der Mac ausschließlich seine eigene `RepositoryLocation` (durch Regel 1 geschützt). Der Pfad muss kanonisch unverändert sein (`PathGuard.canonicalize`, keine eingeschobenen Symlinks), in einem bestätigten Stammordner liegen und außerhalb der Dienstablage (Worktree- und Integrationsordner). Die Stammordner kommen live vom Dienst (`JobOrchestratorDependencies.allowedRepositoryRoots`). Fehlt diese Quelle, gelten die Stammordner beim Dienststart. Synchronisierte Pfade anderer Geräte sind nur Anzeigehinweise oder Wünsche, die der Mac mit `PathGuard` prüft (Projektanlage).

**4. Worktree und Branch berechnet der Mac.** `WorktreeManager` legt sie unter der Worktree-Basis des Dienstes an (`software-regisseur/<task>/<job>`). Sie stehen nur im host-lokalen Laufzeit-Record. `AgentJob.worktreePath`/`branch` werden nur geschrieben, nie gelesen. Vor jeder Wiederverwendung und vor jedem `git add`/`git commit` prüft `WorktreeManager.verifyManagedWorktree`:

- verknüpfter Worktree (eigenes Git-Verzeichnis ≠ gemeinsames), nie der Haupt-Working-Tree,
- unterhalb der Basis, im Repository registriert,
- erwarteter Branch ist ausgecheckt.

Die Übernahme nutzt Branch und Head-Commit aus dem host-lokalen Review-Record. Sie bricht mit `jobBranchMoved` ab, wenn der Branch sich seit dem Review bewegt hat (SR-SEC-06).

**5. Commits auf dem Job-Branch (Ergänzung zu ADR-0024, ersetzt ihn nicht).** Software Regisseur erstellt selbst genau zwei Arten von Commits:

- (a) den Übernahme-Commit (ADR-0015),
- (b) einen **Sicherungs-Commit** am Sitzungsende für nicht committete Ausgabe des Agenten, **nur auf dem eigenen Job-Branch** (Nachricht „Software Regisseur: Agentenergebnis <Job>“).

Für (b) gilt:

- nur in einem nach Regel 4 geprüften Worktree,
- ohne Hooks (`core.hooksPath=/dev/null`, `--no-verify`) und ohne Signatur,
- **ohne** Dateien, die wie Geheimnisse aussehen (Name: `.env*`, Schlüssel-/Keystore-Dateien, Credential-Dateien; Inhalt: bekannte Token-Formate),
- **ohne** Request-/ADR-Dateien unterhalb der Dokumentpfade (ADR-0024).

Ausgeschlossene Dateien bleiben im Worktree und stehen als Hinweis im Review. Die Übernahme ist dann blockiert, bis der Benutzer sie entfernt oder selbst committet. Committete Pfade stehen im Review (`autoCommittedPaths`). Commits, die der Agent selbst macht, bleiben seine eigenen (ADR-0024).

## Erwogene Alternativen

- **Nur Konfliktregel verschärfen:** Das hilft nicht, wenn der Mac keine ungesendete Änderung hat.
- **Signierte Records je Gerät:** Das bräuchte Schlüsselverteilung und eine Geräteliste. Es ist für Eigengebrauch (ADR-0014) unverhältnismäßig und bleibt Option für Vertrieb an Dritte.
- **Worktree-Pfad weiter synchronisieren, aber prüfen:** Eine Prüfung allein bleibt fehleranfällig. Der host-lokale Record macht den synchronisierten Wert bedeutungslos.
- **Kein Sicherungs-Commit:** Dann wäre die Agentenausgabe im Review und in der Übernahme unsichtbar. Der Commit bleibt, aber mit klaren Grenzen.

## Konsequenzen

- Ein fremdes oder kompromittiertes Gerät kann den Mac nicht mehr in ein anderes Repository, in den Haupt-Working-Tree oder auf einen anderen Branch lenken. Es kann Locks, Freigabeanfragen und Review-Ergebnisse nicht fälschen.
- Es kann weiterhin gültige Aufträge anlegen und Freigaben erteilen (Restrisiko 2 im Bedrohungsmodell).
- Ältere App-Versionen, die Mac-eigene Felder schreiben, werden abgewiesen. Der Mac setzt seinen Wert durch.
- Neu bestätigte Stammordner wirken für Agentenstarts erst mit der Live-Quelle `allowedRepositoryRoots`. Der Dienst muss sie übergeben.
- Ein ausgeschlossenes Geheimnis oder eine geänderte Request-Datei blockiert die Übernahme sichtbar, statt still im Default-Branch zu landen.

## Verifikation / Akzeptanz

- Persistence `RemoteOwnershipTests`
- Sync `OwnershipSyncTests` und angepasster Test `TwoDeviceSyncTests` (serverRecordChanged)
- Git `GitHardeningTests` (`verifyManagedWorktree…`, `integrationRefusesWhenJobBranchMovedAfterReview`)
- Jobs `SecurityAuditJobTests` (SR-SEC-01, -02, -06, -09)
- A21, A22, A30, A33

## Verweise

- [Sicherheitsprüfung 2026-10-30](../security/audit-2026-10-30.md), [Bedrohungsmodell](../security/bedrohungsmodell.md) B05, B07, B08, B11, B17
- [ADR-0007](0007-job-queue-locks-worktrees-review.md), [ADR-0012](0012-getrennte-status-zustandsmaschinen.md), [ADR-0015](0015-integrationsstrategie-squash.md), [ADR-0019](0019-persistenz-grdb-einzelner-schreiber.md), [ADR-0023](0023-freigaben-ueber-icloud-weiterleiten.md), [ADR-0024](0024-keine-commits-durch-software-regisseur.md)
- [ADR-Index](README.md)
