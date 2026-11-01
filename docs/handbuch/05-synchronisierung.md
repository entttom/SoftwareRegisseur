# 5. Synchronisierung

iPhone, iPad und Mac gleichen sich über Ihre **private iCloud-Datenbank** (CloudKit) ab. Es gibt keinen eigenen Server und keine zusätzliche Registrierung ([ADR-0003](../adr/0003-git-markdown-und-cloudkit.md), [ADR-0011](../adr/0011-cloudkit-ohne-sichtbare-push-benachrichtigungen.md)).

Voraussetzung ist ein mit Ihrem Team signierter Build und auf allen Geräten derselbe iCloud-Account. Unsignierte Builds zeigen „iCloud-Synchronisierung nicht verfügbar“.

## Was synchronisiert wird – und was nie

| Synchronisiert | Nie synchronisiert |
|---|---|
| Projekte (ohne lokale Pfade als Identität) | API-Schlüssel und andere Zugangsdaten (nur Schlüsselbund; optional iCloud-Schlüsselbund, siehe [Kapitel 3](03-ki-und-schluessel.md)) |
| Aufgaben mit Originalnotiz, Transkript, Entwürfen, Verlauf | Audioaufnahmen |
| ADR-Index, Ordnerregeln, globale Standards, Standardagent | Git-Repositories, Worktrees, Dateien Ihrer Projekte |
| Agentenaufträge, Zeitpläne, Jobstatus, Modell-/Stufen-Snapshots | Logins der Coding-Agenten |
| Agentenfähigkeiten und Modellkataloge des Mac, Mac-Heartbeat | Prozessumgebungen und unbereinigte Agentenlogs |
| Freigabeanfragen (mit geschwärzter Befehlsvorschau) und Entscheidungen | Hostlokaler Dienstzustand (Stammordner, Diensteinstellungen) |
| Review-Entscheidungen, Konflikte | |

Vor jedem Senden prüft eine Sperre die Daten: Datensätze mit Feldnamen oder Werten, die wie Schlüssel oder Tokens aussehen, werden nicht übertragen.

## Keine Push-Benachrichtigungen

Software Regisseur zeigt **keine** Mitteilungen und fragt nie nach der Mitteilungs-Berechtigung. Auf iPhone und iPad kann das System-Framework `CKSyncEngine` intern unsichtbare CloudKit-Signale nutzen, um früher abzugleichen; das ist eine Optimierung ohne Zeitzusage und keine Voraussetzung für die Zustellung von Aufträgen.

## Wann abgeglichen wird

| Gerät | Zeitpunkt |
|---|---|
| iPhone/iPad | beim Öffnen, beim Wechsel in den Vordergrund, durch Herunterziehen und mit „Jetzt synchronisieren“; eigene Änderungen werden nach dem Erfassen gesendet. Im Hintergrund nur gelegentlich und ohne Zusage. |
| Mac (Dienst) | alle 60 Sekunden (einstellbar unter „Diensteinstellungen (nur dieser Mac)“), nach Fehlern mit wachsendem Abstand bis höchstens 30 Minuten, nach dem Aufwachen, bei Netzrückkehr und mit „Jetzt synchronisieren“ in der Menüleiste |

Die Apps zeigen den Stand: „Zuletzt abgeglichen“, „Noch nicht übertragen“ (ausstehende Änderungen) und beim Mac den Zeitpunkt des letzten echten Kontakts. Ein für 22:00 geplanter Auftrag erscheint am iPhone als geplant mit „Mac zuletzt online …“, nicht als „läuft“.

**Offline:** Alles, was Sie auf dem iPhone erfassen, bleibt lokal gespeichert und wird später gesendet. Agentenaufträge warten bis zur Übernahme durch den Mac und laufen genau einmal.

> **Nicht verifiziert:** Polling der `CKSyncEngine` im LaunchAgent ohne Push-Zustellung (Spike S1) und die Abnahmen A10, A24, A26 auf echter Hardware.

## Konflikte

- **Ihre Texte** (Aufgaben, Entwürfe, Einstellungen): Kein stilles „der Letzte gewinnt“. Änderungen beider Seiten werden gegen den gemeinsamen Vorgänger zusammengeführt (feldweise, Text zeilenweise). Überschneiden sie sich, entsteht ein Sync-Konflikt, den Sie entscheiden: lokale Fassung behalten, entfernte übernehmen oder zusammengeführte Fassung speichern. Offene Konflikte: iPhone › Einstellungen › „Konflikte“; Mac › Einstellungen › iCloud › „Sync-Konflikte“.
- **Ausführungsdaten des Mac** (Jobs, Sperren, Pfade, Agentenfähigkeiten): Maßgeblich ist der Mac; die Kollision wird zur Nachvollziehbarkeit protokolliert.
- **Verlaufseinträge** werden nie bearbeitet, nur ergänzt.
- **Markdown-Dateien:** Ändern Sie eine Request-Datei im Repository, während dieselbe Aufgabe in der App geändert wurde, erscheint ein Dateikonflikt im Projekt. Manuelle Statusänderungen an einer Aufgabe mit aktivem Job werden abgelehnt.
- **GitHub:** Die lokale Request-Datei ist führend; Abweichungen auf GitHub erscheinen als Konflikt mit Übernahmemöglichkeit.

## iCloud-Account gewechselt

Erkennt eine App einen anderen iCloud-Account, bleibt die Synchronisierung angehalten und Ihre lokalen Daten bleiben erhalten. Sie entscheiden: „Mit neuem Account fortfahren“ oder „Lokale Daten erneut hochladen“.

## iCloud-Daten löschen und neu beginnen

**Löschen (iPhone/iPad):** Einstellungen › „Daten löschen“ › „iCloud“. Das ist ein eigener Schritt mit eigener Bestätigung. Folgen:

- Alle synchronisierten Projekte, Aufgaben, ADRs, Aufträge und Einstellungen werden aus Ihrer privaten iCloud-Datenbank entfernt.
- Ihre anderen Geräte synchronisieren danach nicht mehr, bis Sie die Synchronisierung neu einrichten.
- Lokale Daten auf diesem Gerät, API-Schlüssel (auch im iCloud-Schlüsselbund) und Git-Repositories bleiben unverändert.

Danach bleibt die Synchronisierung auf diesem Gerät **pausiert**; nichts wird automatisch erneut hochgeladen. Schlägt das Löschen fehl, stehen „Löschen erneut versuchen“ und „Löschen abbrechen und wieder synchronisieren“ zur Wahl.

**Wieder aufnehmen:**

- iPhone/iPad: „Wieder mit iCloud synchronisieren“.
- Mac: Einstellungen › iCloud › „iCloud-Daten neu anlegen“. Der Dienst legt die iCloud-Zone neu an und lädt alle lokalen Daten erneut hoch.

Am Mac kennt der Dienst seit IPC-Protokoll 3 auch einen eigenen Befehl zum Löschen der iCloud-Daten; ob die Einstellungsseite Ihres Builds ihn anbietet, siehe [Kapitel 6](06-datenschutz.md#daten-löschen).
