# 6. Datenschutz

## Wo Ihre Daten liegen

| Daten | Ort |
|---|---|
| Datenbank der iOS-App | eigener App-Container auf iPhone/iPad |
| Datenbank des Mac | App-Group-Container `~/Library/Group Containers/<Team-ID>.<Bundle-ID-Präfix>.SoftwareRegisseur/SoftwareRegisseur/Database/`; nur der Hintergrunddienst schreibt, die App liest |
| Agenten-Worktrees, Laufzeitdaten der Jobs | im selben App-Group-Container (`Worktrees/`, `Integration/`, `Runtime/`) |
| API-Schlüssel | Schlüsselbund des jeweiligen Geräts; optional iCloud-Schlüsselbund |
| Audioaufnahmen | nur auf dem aufnehmenden Gerät |
| Aufgaben und ADRs als Dateien | in Ihren Git-Repositories |
| Synchronisierte Daten | Ihre private iCloud-Datenbank ([Kapitel 5](05-synchronisierung.md)) |
| Logins von Codex und Claude Code | bei den Agenten selbst (`~/.codex`, Claude-Code-Konfiguration); Software Regisseur liest sie nicht |

**An Dritte** gehen Daten nur so:

- an den gewählten KI-Anbieter mit Ihrem eigenen Schlüssel, nach Ihrer Bestätigung bzw. Kontextprüfung ([Kapitel 3](03-ki-und-schluessel.md#was-wohin-übertragen-wird)),
- durch die Coding-Agenten selbst: Codex und Claude Code senden Aufgabentext und Repository-Inhalte an OpenAI bzw. Anthropic, unter deren Bedingungen und mit Ihrem Login,
- an GitHub über Ihre `gh`-Anmeldung, nur wenn Sie GitHub für ein Projekt aktiviert haben.

Logs, Diagnosen, KI-Kontexte und Freigabevorschauen werden vor dem Speichern bzw. Senden auf Geheimnisse geprüft und geschwärzt.

## Daten exportieren

**iPhone/iPad:** Einstellungen › „Datenschutz“ › „Daten exportieren“ › optional „Diktataufnahmen einschließen“ › „Export erstellen“. Ergebnis ist ein ZIP-Archiv zum Teilen oder Sichern in „Dateien“. „Exportdateien von diesem iPhone entfernen“ löscht die Exportdateien aus dem Zwischenspeicher der App.

**Mac:** Einstellungen › „Datenschutz“ › „Daten exportieren …“, Zielordner wählen. Ergebnis ist ein Ordner und, wenn möglich, ein ZIP-Archiv daneben („Im Finder zeigen“).

**Inhalt:** alle Projekte, Aufgaben mit Originalnotizen, Transkripten und Entwurfsversionen, ADRs, Ereignisse/Verlauf, Aufträge, Reviews, Freigaben, KI-Anfragen, Einstellungen und Synchronisierungskonflikte – maschinenlesbar (JSON) und lesbar (Markdown), mit `manifest.json` (Prüfsummen SHA-256 je Datei, Liste des bewusst nicht Exportierten) und einer lesbaren Übersicht.

**Prüfung auf Zugangsdaten:** Schlüssel werden nie gelesen und können nicht im Export landen. Einstellungen von Anbieterprofilen, die wie Zugangsdaten aussehen, werden entfernt. Findet die Prüfung danach noch Zugangsdaten in Anbieterdaten, bricht der Export ab und behält keine Dateien. Stehen in Ihren eigenen Texten Zeichenfolgen, die wie Zugangsdaten aussehen, werden sie unverändert exportiert, aber die App weist vor der Weitergabe darauf hin.

**Nicht im Export:**

- API-Schlüssel und andere Zugangsdaten,
- Git-Repositories, Worktrees und Dateien Ihrer Projektordner (sie bleiben in Git),
- lokaler Dateiindex und Hoststatus des Mac (wird aus Git neu aufgebaut),
- Synchronisations-Warteschlange und CloudKit-Verwaltungsdaten,
- Audioaufnahmen, wenn Sie „Diktataufnahmen einschließen“ nicht wählen.

## Daten löschen

Jede Löschung zeigt vorher eine **Vorschau** mit genau den Einträgen, die entfernt werden, und dem, was erhalten bleibt. Ausgeführt wird erst nach ausdrücklicher Bestätigung; eine Vorschau ist nur einmal verwendbar und läuft ab. Gelöscht wird genau die Liste der Vorschau, nichts, was später dazukam.

**iPhone/iPad:** Einstellungen › „Datenschutz“ › „Daten löschen“:

| Umfang | Was entfernt wird | Was bleibt |
|---|---|---|
| „Audioaufnahmen löschen“ | Diktataufnahmen auf diesem Gerät | Transkripte und Aufgaben |
| „API-Schlüssel löschen“ | Schlüssel im Schlüsselbund (wählbar) | Anbieterprofile; die Funktionen sind ohne Schlüssel deaktiviert |
| „Lokale Datenbank und Zwischenspeicher löschen“ | Datenbank (wird leer neu angelegt) und wiederherstellbare Zwischenspeicher | Audioaufnahmen und API-Schlüssel |
| „Alle lokalen Daten löschen“ | Aufnahmen, gerätebezogene Schlüssel, Datenbank, Zwischenspeicher, übrige App-Dateien | Schlüssel im iCloud-Schlüsselbund (ihr Löschen beträfe alle Geräte; einzeln über „API-Schlüssel löschen“) |
| „iCloud“ | Ihre iCloud-Daten von Software Regisseur – eigener Schritt, siehe [Kapitel 5](05-synchronisierung.md#icloud-daten-löschen-und-neu-beginnen) | alles Lokale |

Lokale Löschungen berühren nie iCloud-Daten. **Git-Repositories und Dateien in Ihren Projektordnern werden nie gelöscht**; ein Pfad außerhalb der App-Daten oder in einem Git-Repository wird abgelehnt.

**Mac:** Der Hintergrunddienst kennt seit IPC-Protokoll 3 dieselben Umfänge (lokale Datenbank, API-Schlüssel, alles Lokale) sowie das Löschen der iCloud-Daten, jeweils mit Vorschau und Bestätigung. Die Einstellungsseite „Datenschutz“ der Mac-App zeigt im aktuellen Stand noch „Löschen ist am Mac noch nicht möglich …“; bis sie den Befehl anbietet, bleiben alle Daten am Mac erhalten. Einzelne API-Schlüssel löschen Sie am Mac unter Einstellungen › „API-Schlüssel für die KI-Ausarbeitung am Mac“ › „Löschen“.

> **Nicht verifiziert:** Export und Löschen auf echten Geräten mit echten Daten (A34).

## Was nie synchronisiert und nie exportiert wird

- API-Schlüssel, Tokens, Passwörter, Zertifikate – weder im Klartext in iCloud-Datensätzen noch in Markdown, Git, Logs oder Exporten,
- Anmeldedaten von Codex, Claude Code und GitHub (Software Regisseur speichert keine),
- Inhalte von Dateien, die zum Geheimnis-Ausschluss passen (`.env*`, Schlüssel- und Zertifikatsdateien, `Local.xcconfig` usw.); sie werden auch nicht in KI-Kontexte aufgenommen,
- ganze Git-Repositories und Worktrees,
- Audioaufnahmen werden nie synchronisiert; exportiert nur auf Wunsch.
