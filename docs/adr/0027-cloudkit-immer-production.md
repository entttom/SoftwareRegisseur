---
adr: 0027
title: "Alle Builds verwenden die CloudKit-Umgebung Production"
status: accepted
date: 2026-11-02
---

# ADR-0027: Alle Builds verwenden die CloudKit-Umgebung Production

**Status:** Accepted  
**Datum:** 2026-11-02  
**Entscheidungsträger:** Eigentümer, nach Diagnose „Mac und iPhone synchronisieren nicht“.

## Kontext

CloudKit hat je Container zwei getrennte Umgebungen. Xcode-Debug-Builds nutzten bisher **Development**, TestFlight- und Developer-ID-Builds **Production**. Daten der einen Umgebung sind in der anderen nicht sichtbar.

Am 2026-11-02 zeigte `cktool` (Private Database, Zone `SoftwareRegisseur`):

- Production: nur 2 `WorkItem` und 2 `TaskEvent` vom iPhone (TestFlight).
- Development: die Mac-Daten aus früheren Debug-Builds (1 `AgentHost`, 69 Projekte, 200+ Ordner, 43 ADRs).
- Das Schema war in beiden Umgebungen identisch und vollständig. Der installierte Developer-ID-Dienst hatte das Entitlement `icloud-container-environment = Production`.

Ursache: Debug- und Release-Dienst teilen am Mac dieselbe Datenbank (App Group, ADR-0019). Der Release-Dienst übernahm den Synchronisierungsstand aus Development (`CKSyncEngine`-Stand, Systemfelder, als gesendet bestätigte Operationen). Aus seiner Sicht war alles übertragen. Deshalb kam in Production nie etwas vom Mac an. Der Coordinator speicherte die Umgebung nicht und konnte den Wechsel nicht erkennen. Auf dem iPhone passiert dasselbe, wenn auf einen Debug-Build ein TestFlight-Build folgt.

## Entscheidung

1. **Production für alle Builds.** `SR_CLOUDKIT_ENVIRONMENT = Production` in `Config/Base.xcconfig`. Der Wert geht in das Entitlement `com.apple.developer.icloud-container-environment` (iOS-App und Agent Service) und in den Info.plist-Schlüssel `SRCloudKitEnvironment`. `aps-environment` bleibt je Konfiguration (Debug `development`). Das betrifft nur stille Pushes, und der Sync läuft ohnehin nur explizit (ADR-0011, `automaticallySync = false`).
2. **Umgebung im Synchronisierungsstand.** `SyncCoordinator` speichert die Umgebung in seinen Metadaten. Weicht sie beim Start von `SyncConfiguration.cloudEnvironment` ab oder fehlt sie, wurde aber schon synchronisiert, dann verwirft er Engine-Stand, Systemfelder sowie Zonen- und Account-Bestätigungen und lädt alle lokalen Daten vollständig neu hoch (`FullUploadState`). Lokale Daten bleiben unverändert. Eine vom Benutzer veranlasste Löschung der iCloud-Daten (A34) bleibt in Kraft. Ohne vorherige Synchronisierung wird nur die Umgebung vermerkt.
3. **Schema als Datei.** `Config/CloudKit/schema.ckdb` ist die Quelle des Schemas. Änderungen laufen über `cktool import-schema` nach Development und „Deploy Schema Changes“ nach Production (`Config/CloudKit/README.md`).
4. **Sync-Logging.** Der Sync schreibt nach `Logger(subsystem: "SoftwareRegisseur", category: "Sync")`: Laufergebnis, CloudKit-Fehlercodes (auch einzelne Einträge eines `partialFailure`), Umgebungs- und Accountwechsel. Es werden nur Codes, Fehlertexte und Datensatznamen geloggt, nie Inhalte.

## Erwogene Alternativen

- **Nur den Umgebungs-Merker, Debug bleibt Development:** Das hätte den Fehler behoben, aber jeder Wechsel zwischen Debug und Release hätte erneut einen vollständigen Upload ausgelöst, und die Daten wären zwischen den Umgebungen verteilt. Verworfen.
- **Nur Production, ohne Merker:** Vorhandene Datenbanken mit Development-Stand blieben kaputt. Verworfen.
- **Getrennte Datenbanken je Umgebung:** Das widerspricht der einen Datenbank je Gerät (ADR-0019), und Daten aus Debug-Läufen wären am Gerät unsichtbar. Verworfen.

## Konsequenzen

- Mac und iPhone sprechen immer mit derselben Datenbank, unabhängig von der Build-Art.
- **Einmaliger vollständiger Upload** pro Gerät beim ersten Start mit diesem Stand, auch auf Geräten, die schon korrekt mit Production synchronisierten. Bei gleichem Inhalt laufen die Fassungen zusammen; unterschiedliche Inhalte werden zu sichtbaren Konflikten (ADR-0019, N2).
- Daten aus Debug-Läufen landen in den echten iCloud-Daten des Eigentümers (Eigengebrauch, ADR-0014).
- Kein automatisches Schema mehr: Ein neuer Typ oder ein neues Feld muss vor der Auslieferung deployt sein, sonst lehnt CloudKit die Datensätze ab.
- Die Development-Daten bleiben liegen und werden nicht mehr benutzt. Sie lassen sich mit `cktool reset-schema` verwerfen.

## Verifikation / Akzeptanz

- `Packages/SoftwareRegisseurSync/Tests/SoftwareRegisseurSyncTests/CloudEnvironmentTests.swift`: Ein unbekannter oder anderer Stand führt zu einem vollständigen Upload in die neue Umgebung, dieselbe Umgebung danach zu keinem. Ohne Synchronisierung wird nichts neu hochgeladen. Ein fremder User-Record-Name pausiert nicht. Eine Löschung (A34) bleibt in Kraft.
- `AgentServiceCoreTests.cloudKitEnvironmentComesFromInfoPlist`.
- `Scripts/verify-release.sh` prüft `icloud-container-environment = Production` im Agent Service.
- Real: Nach dem Update zeigt `cktool query-records … --environment production` die Mac-Daten (`AgentHost`, `Project`), und das iPhone zeigt die Projekte des Macs.

## Verweise

ADR-0011, ADR-0013, ADR-0014, ADR-0019; `docs/acceptance/e2e-testplan.md` V4; A10, A26, A34.
