# 1. Installation

Software Regisseur besteht aus drei Teilen:

- **Mac-App** in der Menüleiste (kein Dock-Symbol) mit Hauptfenster,
- **Hintergrunddienst** („Software Regisseur Hintergrunddienst“), eingebettet in die Mac-App, läuft im Benutzerkontext ohne Administratorrechte und erledigt Scanner, Markdown, Git, Agenten und iCloud-Synchronisierung – auch wenn das Fenster geschlossen ist,
- **iOS-App** für iPhone und iPad.

## Voraussetzungen

| | Anforderung |
|---|---|
| Mac | Apple Silicon, macOS 26 oder neuer. Intel-Macs sind nicht getestet. |
| iPhone/iPad | iOS bzw. iPadOS 26 oder neuer |
| iCloud | Auf allen Geräten mit demselben Apple-Account bei iCloud angemeldet |
| Apple Developer Program | Nötig für signierte Builds (CloudKit, Login-Agent, Schlüsselbund-Gruppe) und für TestFlight |
| Zum Selbstbauen | Xcode 27, XcodeGen (`brew install xcodegen`) |
| Für Agentenläufe | Codex CLI und/oder Claude Code CLI, siehe [Kapitel 4](04-agenten.md) |

Version 1.0 ist für den Eigengebrauch bestimmt ([ADR-0014](../adr/0014-eigengebrauch-in-version-1.md)): Die Mac-App wird als Developer-ID-signierte, notarisierte App verteilt, die iOS-App über Xcode oder TestFlight. Einen App-Store-Vertrieb gibt es nicht.

## Mac-App installieren

### Weg A: Release-DMG (Developer ID, notarisiert)

1. DMG öffnen und „Software Regisseur“ in den Ordner „Programme“ ziehen.
2. App starten. Es erscheint ein Symbol in der Menüleiste; ein Hauptfenster öffnet sich nicht automatisch („Hauptfenster öffnen“ im Menüleisten-Fenster).
3. Den Hintergrunddienst aktivieren (siehe unten).

> **Nicht verifiziert:** Ein notarisierter Release wurde noch nicht erstellt. Die Skripte (`Scripts/release.sh`, `Scripts/sign-and-notarize.sh`, `Scripts/verify-release.sh`) sind vorhanden; für die Notarisierung fehlt noch das Notarisierungsprofil im Schlüsselbund des Benutzers. Die Installation auf einem frischen Mac (Abnahme A28) ist offen. Anleitung für den Release: [docs/release/README.md](../release/README.md).

### Weg B: Eigener Build aus Xcode

1. `cp Config/Local.xcconfig.template Config/Local.xcconfig` und die Werte eintragen: Team-ID, Bundle-ID-Präfix, CloudKit-Container (beginnt mit `iCloud.`), optional Sparkle-Feed und öffentlicher Sparkle-Schlüssel. Die Datei wird nie eingecheckt.
2. `xcodegen generate`
3. `SoftwareRegisseur.xcodeproj` in Xcode öffnen, Schema `SoftwareRegisseur-macOS` wählen und ausführen. Xcode signiert App und eingebetteten Dienst mit Ihrem Team.

Mit den Vorlagenwerten (Platzhalter-Team) oder mit `Scripts/build.sh` entsteht ein **unsignierter** Prüf-Build. Er startet, aber:

- die iCloud-Synchronisierung ist nicht verfügbar,
- der Hintergrunddienst lässt sich nicht als Login-Agent registrieren („Dienst nicht gefunden …“),
- die App kann sich nicht mit dem Dienst verbinden (die XPC-Verbindung verlangt, dass beide Teile vom selben Team signiert sind),
- API-Schlüssel können nicht in der gemeinsamen Schlüsselbund-Gruppe gespeichert werden.

> **Hinweis CloudKit-Schema:** Entwicklungs-Builds legen die Datensatztypen in der Development-Umgebung des CloudKit-Containers an. Release-Builds (Developer ID) verwenden die Production-Umgebung; dorthin muss das Schema im CloudKit-Dashboard übertragen werden. Dieser Schritt ist im Projekt noch nicht real durchlaufen.

### Hintergrunddienst aktivieren (Login-Agent)

Der Dienst wird **nicht** automatisch registriert. Sie aktivieren ihn selbst:

1. Menüleiste › „Einstellungen“ › Bereich „Hintergrunddienst“.
2. Schalter „Hintergrunddienst bei Anmeldung starten“ einschalten. Die App registriert den Dienst über `SMAppService` als LaunchAgent; er startet sofort und danach bei jeder Anmeldung.
3. Je nach macOS-Einstellung ist eine Freigabe nötig. Die App zeigt dann „Registriert, aber noch nicht freigegeben …“ und die Schaltfläche **„Anmeldeobjekte öffnen“**. Sie öffnet Systemeinstellungen › Allgemein › Anmeldeobjekte; dort Software Regisseur erlauben. Die App fragt nicht erneut, sondern verweist immer auf diese Einstellung.
4. Danach zeigt die App „Aktiviert: Der Dienst startet bei jeder Anmeldung.“

Der Status wird immer direkt von macOS gelesen. Mögliche Anzeigen: „Aktiviert“, „Registriert, aber noch nicht freigegeben“, „Nicht aktiviert“, „Dienst nicht gefunden“ (unsignierter Build oder fehlende launchd-Konfiguration im Bundle).

> **Nicht verifiziert:** Start nach Anmeldung ohne Hauptfenster (A01), Verhalten nach einem Update über Sparkle und nach Verschieben der App (Spike S3) sind noch nicht auf echter Hardware nachgewiesen.

### App beenden, Dienst stoppen, Dienst pausieren

Im Menüleisten-Fenster:

| Aktion | Wirkung |
|---|---|
| „App beenden“ | Beendet Menüleiste und Fenster. Der Hintergrunddienst läuft weiter. |
| „Dienst stoppen“ | Beendet den Hintergrunddienst; die App bleibt in der Menüleiste. launchd startet ihn bei der nächsten Anfrage oder Anmeldung wieder. |
| „Dienst pausieren“ / „Dienst fortsetzen“ | Pausieren stoppt nur **neue** Agentenstarts. Laufende Jobs, Freigaben, Synchronisierung und Scanner laufen weiter. Der Zustand übersteht Neustarts. |

Den Dienst dauerhaft abschalten: Schalter „Hintergrunddienst bei Anmeldung starten“ ausschalten.

### Updates der Mac-App

Updates laufen über Sparkle mit EdDSA-signiertem Appcast ([ADR-0017](../adr/0017-sparkle-updates.md)). Die App prüft täglich und installiert erst nach Ihrer Bestätigung („Nach Updates suchen …“ im Menüleisten-Fenster und im App-Menü). In Debug-Builds, unsignierten Builds oder solange Feed-URL bzw. öffentlicher Schlüssel Platzhalter sind, sind Updates deaktiviert; die App nennt den Grund.

> **Nicht verifiziert:** Update von Version n auf n+1 und Ablehnung eines manipulierten Pakets (A28). Ob launchd den laufenden Dienst nach einem Update automatisch neu startet, ist offen (Spike S3).

## iOS-App installieren

### Weg A: Über Xcode auf das eigene Gerät

1. Wie oben `Config/Local.xcconfig` anlegen und `xcodegen generate` ausführen.
2. In Xcode das Schema `SoftwareRegisseur-iOS` wählen, Ihr iPhone oder iPad als Ziel auswählen und ausführen. Auf dem Gerät muss der Entwicklermodus aktiv sein.

### Weg B: TestFlight

Über Xcode (Schema `SoftwareRegisseur-iOS` › Product › Archive › Organizer) in App Store Connect hochladen und über TestFlight auf Ihren Geräten installieren. Ein eigenes Skript dafür gibt es nicht. Auf der Kommandozeile geht es so:

```bash
xcodebuild archive -scheme SoftwareRegisseur-iOS -configuration Release -destination 'generic/platform=iOS' -archivePath build/Archives/SoftwareRegisseur-iOS.xcarchive -allowProvisioningUpdates CURRENT_PROJECT_VERSION=<build>
```

```bash
xcodebuild -exportArchive -archivePath build/Archives/SoftwareRegisseur-iOS.xcarchive -exportOptionsPlist <ExportOptions.plist> -exportPath build/Exports/iOS -allowProvisioningUpdates
```

Die `ExportOptions.plist` (nicht eingecheckt, da sie die Team-ID enthält) setzt `method` = `app-store-connect`, `destination` = `upload`, `teamID` und `signingStyle` = `automatic`. Jeder Upload braucht eine höhere Build-Nummer; die Marketing-Version kommt aus `Config/Base.xcconfig`.

> **Teilweise verifiziert:** Am 2026-11-01 wurden 1.0.0 (20261101.1) und (20261101.2) erfolgreich zu App Store Connect hochgeladen. Verarbeitung und Installation über TestFlight sind noch nicht geprüft. Die Mac-App lässt sich nicht über TestFlight verteilen, weil sie bewusst ohne App Sandbox läuft (ADR-0009, ADR-0017).

### Berechtigungen auf iPhone und iPad

Die App fragt nur nach Berechtigungen, wenn Sie die zugehörige Funktion verwenden:

- **Mikrofon** und **Spracherkennung**: beim ersten Diktat. Vorher erklärt ein eigener Bildschirm, wofür die Berechtigung dient; die einzige Schaltfläche heißt „Weiter“ und löst sofort die Systemabfrage aus. Lehnen Sie ab, zeigt die App, welche Funktion fehlt, und bietet „Einstellungen öffnen“ an, statt erneut zu fragen.
- **Mitteilungen**: werden nie angefragt. Software Regisseur verwendet keine sichtbaren Push-Benachrichtigungen ([Kapitel 5](05-synchronisierung.md)).

Funktionsumfang und Regeln sind auf iPhone und iPad gleich; das iPad hat eine eigene Darstellung mit Seitenleiste und Split View ([ADR-0025](../adr/0025-ipad-unterstuetzung.md)).

## Deinstallation

1. Mac: Schalter „Hintergrunddienst bei Anmeldung starten“ ausschalten, „App beenden“, App aus „Programme“ löschen.
2. Lokale Daten bleiben im App-Group-Container des Mac (`~/Library/Group Containers/<Team-ID>.<Bundle-ID-Präfix>.SoftwareRegisseur/`), API-Schlüssel im Schlüsselbund, iCloud-Daten in Ihrer privaten iCloud-Datenbank. Kontrolliertes Löschen: [Kapitel 6](06-datenschutz.md).
3. Ihre Git-Repositories, Request- und ADR-Dateien bleiben unverändert und sind ohne Software Regisseur les- und bearbeitbar. Agenten-Branches bleiben erhalten, bis Sie sie löschen.
