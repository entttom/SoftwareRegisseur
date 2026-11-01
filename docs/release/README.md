# macOS-Release und Sparkle-Updates

Gilt für die Mac-App inklusive eingebettetem Agent Service. Grundlagen: Pflichtenheft Q2/Q3,
[ADR-0009](../adr/0009-direktvertrieb-signierung-sandbox-prufung.md) (Developer ID, Notarisierung),
[ADR-0013](../adr/0013-mindestversionen-und-lokale-signierkonfiguration.md) (lokale Signierwerte),
[ADR-0017](../adr/0017-sparkle-updates.md) (Sparkle, GitHub Releases),
[ADR-0020](../adr/0020-agent-service-unsandboxed-xpc.md) (unsandboxed Agent Service),
[Recherche §3.4 und §6](../integration-spikes/apple-platform.md).

## Überblick

| Schritt | Skript | Ergebnis |
|---|---|---|
| 1. Bauen, signieren, DMG | `Scripts/release.sh <version> <build>` | Developer-ID-signierte App und DMG, Vorprüfung |
| 2. Notarisieren, Ticket anheften | `Scripts/sign-and-notarize.sh <dmg> --keychain-profile <profil>` | notarisiertes, gestapeltes DMG |
| 3. Appcast erzeugen | `Scripts/make-appcast.sh --archives <ordner> --tag v<version>` | EdDSA-signierter `appcast.xml` |
| 4. Veröffentlichen | `gh release create …` (von Hand) | GitHub-Release im öffentlichen Release-Repository |
| jederzeit: Prüfen | `Scripts/verify-release.sh <app-oder-dmg>` | OK/ERWARTET/HINWEIS/FEHLER je Prüfung |

Alle Skripte haben `--help`. Kein Skript lädt selbst etwas hoch oder legt Repositories an;
nur `sign-and-notarize.sh` (ohne `--dry-run`) sendet das DMG an Apples Notarisierungsdienst.

Sparkle ist als Swift Package **exakt auf 2.10.1** gepinnt (`project.yml` → `packages` → `Sparkle`,
Tag am 30.10.2026 per `git ls-remote` geprüft). Die Werkzeuge `generate_appcast`/`generate_keys`
stammen aus den aufgelösten Paket-Artefakten derselben Version; die Skripte prüfen das.

## Einmalige Einrichtung (vom Benutzer durchzuführen)

### 1. Lokale Konfiguration

`Config/Local.xcconfig` (nie eingecheckt, ADR-0013) braucht echte Werte für
`SR_DEVELOPMENT_TEAM`, `SR_BUNDLE_ID_PREFIX`, `SR_CLOUDKIT_CONTAINER` sowie – nach den Schritten 3
und 4 – `SR_SPARKLE_FEED_URL` und `SR_SPARKLE_PUBLIC_ED_KEY`. `release.sh` verweigert
Vorlagenwerte. Solange die Sparkle-Werte Platzhalter sind, zeigt die App
„Updates sind deaktiviert …“ und prüft nie gegen eine erfundene Adresse.

### 2. Developer-ID-Zertifikat und Provisioning

- Im Schlüsselbund muss genau eine gültige Identität
  „Developer ID Application: … (<Team-ID>)“ liegen (Xcode → Settings → Accounts → Manage Certificates).
- Der Agent Service nutzt CloudKit, Push und Keychain-Gruppen; das verlangt ein
  **Developer-ID-Provisioning-Profil**. `release.sh` ruft `xcodebuild` mit
  `-allowProvisioningUpdates` auf; Xcode legt die Profile dann über den in Xcode angemeldeten
  Account an. Ohne Account: Profile im Developer-Portal erzeugen, installieren und
  `--no-provisioning-updates` sowie ggf. `--export-options <plist>` (manuelle Profile) verwenden.

### 3. Notarisierungs-Profil im Schlüsselbund

Einmalig im Terminal (fragt interaktiv, speichert im Schlüsselbund; nichts davon gehört ins Repo):

```sh
xcrun notarytool store-credentials "SoftwareRegisseur-Notary" \
    --apple-id "<Apple-ID>" --team-id "<Team-ID>"
# fragt nach einem app-spezifischen Passwort (account.apple.com → Anmeldung & Sicherheit)
```

Alternativ mit App-Store-Connect-API-Schlüssel: `--key <AuthKey.p8> --key-id <ID> --issuer <UUID>`
(die `.p8`-Datei danach sicher verwahren, nicht im Repository). Test:
`xcrun notarytool history --keychain-profile "SoftwareRegisseur-Notary"`.
`sign-and-notarize.sh` nimmt bewusst keine Passwörter, Apple-IDs oder Schlüssel als Argument an.

### 4. Sparkle-Schlüssel (EdDSA)

```sh
Scripts/sparkle-keys.sh            # erzeugt einmalig den Schlüssel im Schlüsselbund, zeigt nur den öffentlichen
Scripts/sparkle-keys.sh --print-only   # zeigt den öffentlichen Schlüssel erneut
```

Den ausgegebenen Wert in `Config/Local.xcconfig` eintragen:
`SR_SPARKLE_PUBLIC_ED_KEY = <öffentlicher Schlüssel>`.

**Schlüssel sichern:** Geht der private Schlüssel verloren, nehmen installierte Versionen keine
Updates mehr an (Ausweg nur über Schlüsselrotation per Developer-ID-signiertem Update). Einmalig
von Hand exportieren, sofort in einen Passwortmanager/verschlüsselten Tresor übernehmen und die
Datei löschen:

```sh
DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x /pfad/auf/verschluesseltem/volume/sparkle-private-key
```

Der Pfad zu `generate_keys` existiert, nachdem eines der Skripte die Pakete aufgelöst hat.

### 5. Öffentliches Release-Repository (ADR-0017)

Appcast und DMGs liegen in GitHub Releases eines **öffentlichen** Repositorys. Bleibt der
Quellcode privat, ein eigenes Repository ohne Quellcode anlegen, z. B.:

```sh
gh repo create <owner>/SoftwareRegisseur-Releases --public --description "Software Regisseur – Releases"
```

Dann in `Config/Local.xcconfig` (in xcconfig wird `//` als `/$()/` geschrieben):

```
SR_SPARKLE_FEED_URL = https:/$()/github.com/<owner>/SoftwareRegisseur-Releases/releases/latest/download/appcast.xml
```

`releases/latest/download/appcast.xml` zeigt immer auf das neueste veröffentlichte (nicht
Draft/Pre-Release) Release – deshalb muss **jedes** Release den aktuellen `appcast.xml` enthalten.

## Release erstellen

1. Version und Build festlegen. Die Build-Nummer (`CFBundleVersion`) muss bei jedem Release
   steigen und darf nie wiederverwendet werden; Sparkle vergleicht sie.
2. Bauen und signieren:
   ```sh
   Scripts/release.sh 1.0.0 1
   ```
   Ausgabe in `DerivedData/Releases/1.0.0-1/` (oder `--output <ordner>`): Archiv, `export/`,
   `SoftwareRegisseur-1.0.0.dmg`, `.sha256`, `release-info.txt` (Commit, Xcode, Sparkle), Logs.
   Am Ende läuft `verify-release.sh --pre-notarization`. Warnungen zu nicht committeten Änderungen
   ernst nehmen: Ein Release sollte aus einem sauberen Commit entstehen.
3. Notarisieren und Ticket anheften:
   ```sh
   Scripts/sign-and-notarize.sh DerivedData/Releases/1.0.0-1/SoftwareRegisseur-1.0.0.dmg \
       --keychain-profile SoftwareRegisseur-Notary
   ```
   Mit `--dry-run` werden nur die Befehle gezeigt. Das Notarisierungsprotokoll wird immer neben
   dem DMG gespeichert (`*.notarytool-log.json`). Danach muss `verify-release.sh` ohne
   `--pre-notarization` fehlerfrei sein („source=Notarized Developer ID“).
4. Appcast-Ordner vorbereiten und Appcast erzeugen:
   ```sh
   mkdir -p ~/SoftwareRegisseur-Appcast && cp DerivedData/Releases/1.0.0-1/SoftwareRegisseur-1.0.0.dmg ~/SoftwareRegisseur-Appcast/
   gh release download --repo <owner>/SoftwareRegisseur-Releases --pattern appcast.xml --dir ~/SoftwareRegisseur-Appcast --clobber  # ab dem 2. Release
   # optional Release Notes: ~/SoftwareRegisseur-Appcast/SoftwareRegisseur-1.0.0.md
   Scripts/make-appcast.sh --archives ~/SoftwareRegisseur-Appcast --tag v1.0.0
   ```
   `generate_appcast` signiert jedes Paket und – weil die App `SURequireSignedFeed` setzt – den
   Appcast selbst. macOS fragt beim ersten Mal nach Zugriff auf den Schlüsselbund-Eintrag.
5. Veröffentlichen (von Hand; das Skript gibt den passenden Befehl aus):
   ```sh
   gh release create v1.0.0 --repo <owner>/SoftwareRegisseur-Releases \
       --title "Software Regisseur 1.0.0" --notes-file <notizen.md> \
       ~/SoftwareRegisseur-Appcast/SoftwareRegisseur-1.0.0.dmg ~/SoftwareRegisseur-Appcast/appcast.xml
   ```
   Erzeugte Delta-Dateien (`*.delta`) im Ordner ebenfalls anhängen.

## Prüfen

`Scripts/verify-release.sh <app-oder-dmg>` prüft und meldet je Zeile:

- `codesign --verify --deep --strict` (App) bzw. `--strict` (DMG), Developer-ID-Signatur des DMG
- `spctl -a -t exec -vv` (App) und `spctl -a -t open --context context:primary-signature -vv` (DMG)
- `xcrun stapler validate`
- jede Mach-O-Datei: Developer ID, gleiche Team-ID, sicherer Zeitstempel, Hardened Runtime für
  Programme, kein `get-task-allow`
- Entitlements von App und Agent Service (werden vollständig ausgegeben): App Group/Keychain-Gruppen
  mit Team-Präfix, CloudKit-Container, `aps-environment = production`, keine App Sandbox (ADR-0020)
- Developer-ID-Provisioning-Profil (ProvisionsAllDevices, Team, Ablaufdatum)
- Agent Service und launchd-Plist (Label, BundleProgram, Mach-Service mit Team-Präfix)
- Sparkle-Version und `SUFeedURL`/`SUPublicEDKey`/`SURequireSignedFeed`/`SUVerifyUpdateBeforeExtraction`
- keine Vorlagen-Platzhalter, keine unaufgelösten `$(SR_…)`, keine Token-/Schlüssel-Muster
  (OpenAI, Anthropic, GitHub, AWS, Google, Slack, PEM) und keine Schlüsseldateien im Bundle;
  Treffer werden nur mit Dateipfad, nie mit Inhalt gemeldet

Vor der Notarisierung (`--pre-notarization`) sind „source=Unnotarized Developer ID“ und das
fehlende Ticket als `ERWARTET` markiert, danach sind sie `FEHLER`.

**Abnahme A28 / ADR-0017 bleibt offen**, bis real belegt ist: Notarisierung akzeptiert, DMG auf
einem frischen Mac (oder frischer VM) per Doppelklick installierbar und startbar, Update von
Version n auf n+1 über „Nach Updates suchen …“, und ein manipuliertes Paket wird abgelehnt
(z. B. Kopie des DMG um ein Byte verändern, als Appcast-Eintrag mit der Original-`edSignature`
lokal per HTTPS ausliefern – Sparkle muss die Installation verweigern).

## In der App

- `Apps/SoftwareRegisseur-macOS/Sources/SoftwareUpdater.swift`: `SPUStandardUpdaterController`
  mit Gentle Reminders (Menüleisten-App, `LSUIElement`): Geplante Funde stehen als
  „Update auf Version … ansehen …“ im Menüleisten-Fenster, statt ein Fenster ohne Fokus zu öffnen.
- Menüeintrag „Nach Updates suchen …“ im Menüleisten-Fenster und im App-Menü.
- Info.plist: `SUFeedURL`, `SUPublicEDKey` (aus Build-Variablen), `SURequireSignedFeed = YES`,
  `SUVerifyUpdateBeforeExtraction = YES`, `SUEnableAutomaticChecks = YES` (täglich),
  `SUAutomaticallyUpdate = NO` (Installation nur nach Bestätigung, wegen laufender Agentenjobs).
- Updates sind deaktiviert (mit deutscher Begründung in der UI) bei Debug-Builds, unsignierten
  Builds, Platzhalter-/Nicht-HTTPS-Feed oder ungültigem öffentlichem Schlüssel.
- Die UI-App läuft ohne App Sandbox (ADR-0020); Sparkle braucht daher keinen Installer-XPC
  (`SUEnableInstallerLauncherService`). Wird die UI später sandboxed, ist Spike S6 nötig.

## Offene Punkte für den Agent Service (Spike S3)

Sparkle ersetzt das gesamte Bundle, also auch `Contents/Library/LoginItems/SoftwareRegisseurAgentService.app`
und die launchd-Plist. **Nicht belegt** ist, dass launchd den laufenden Dienst danach neu startet
(Recherche §3.4). Bis dahin läuft nach einem Update ggf. der alte Dienst weiter. Für den
Agent-Service-Verantwortlichen (hier bewusst nicht umgesetzt):

1. **Versionen angleichen:** Das Agent-Target sollte `CFBundleShortVersionString: $(MARKETING_VERSION)`
   und `CFBundleVersion: $(CURRENT_PROJECT_VERSION)` in `project.yml` setzen – erledigt, das Agent-Target nutzt beide Variablen;
   `verify-release.sh` meldet die Abweichung als HINWEIS.
2. **Handshake:** XPC-Handshake mit Build-Nummer; erkennt der Dienst, dass das Bundle auf der
   Platte neuer ist als er selbst, pausiert er Jobs (ADR-0007) und beendet sich.
3. **Achtung `KeepAlive`:** Die launchd-Plist nutzt `KeepAlive = { SuccessfulExit = false }` –
   launchd startet nur nach einem **nicht erfolgreichen** Exit neu. Der Dienst muss sich also mit
   Exit-Code ≠ 0 beenden, oder die UI ruft nach dem Neustart `SMAppService` `unregister()`/`register()`
   bzw. prüft `status`.
4. **Hook in der App:** `SoftwareUpdater.updater(_:willInstallUpdate:)` protokolliert derzeit nur.
   Dort (oder in `updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)`) kann die UI den
   Dienst vor dem Austausch anweisen, Jobs zu pausieren, und den Neustart bis zur Bestätigung
   verzögern.

## Rückfall (Rollback)

- Sparkle installiert nie eine ältere Version. Der reguläre Weg ist ein **Folge-Release mit
  höherer Build-Nummer** (gleiche oder korrigierte Marketing-Version), das den Fehler behebt.
- Ein fehlerhaftes Release, das noch nicht verteilt wurde: in GitHub als Draft/Pre-Release
  markieren oder löschen. `releases/latest/download/appcast.xml` zeigt dann wieder auf das
  vorherige Release, dessen Appcast das fehlerhafte Paket nicht enthält. Bereits aktualisierte
  Installationen bleiben auf der fehlerhaften Version, bis ein Folge-Release erscheint.
- Manuelles Zurückgehen: älteres DMG aus GitHub Releases installieren. Vorsicht: Neuere
  Datenbankmigrationen (GRDB, ADR-0019) sind nicht rückwärtskompatibel – vorher Backup des
  App-Group-Containers.
- Kompromittierter EdDSA-Schlüssel: neuen Schlüssel erzeugen und per Update ausrollen, das mit
  Developer ID signiert ist (Sparkle erlaubt die Rotation eines der beiden Schlüssel).
  Kompromittiertes Developer-ID-Zertifikat: bei Apple widerrufen lassen, neues Zertifikat,
  Update mit dem alten EdDSA-Schlüssel signieren.
- Build-Nummern und Tags werden nie wiederverwendet.

## Was der Benutzer einmalig tun muss

1. `xcrun notarytool store-credentials "SoftwareRegisseur-Notary" …` (Abschnitt 3).
2. `Scripts/sparkle-keys.sh` ausführen, öffentlichen Schlüssel in `Config/Local.xcconfig`
   eintragen und den privaten Schlüssel sichern (Abschnitt 4).
3. Öffentliches Release-Repository anlegen und `SR_SPARKLE_FEED_URL` setzen (Abschnitt 5).
4. Ersten echten Release durchführen und A28 auf einem frischen Mac belegen (Abschnitt „Prüfen“).
