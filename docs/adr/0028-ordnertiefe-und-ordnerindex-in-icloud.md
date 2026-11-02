---
adr: 0028
title: "Einstellbare Ordnertiefe; entfernte Ordner-Einträge werden in iCloud gelöscht"
status: accepted
date: 2026-11-02
---

# ADR-0028: Einstellbare Ordnertiefe; entfernte Ordner-Einträge werden in iCloud gelöscht

**Status:** Accepted  
**Datum:** 2026-11-02  
**Entscheidungsträger:** Eigentümer, nach dem ersten vollständigen Upload nach ADR-0027.

## Kontext

Der Scanner ging bis 8 Ebenen unter jeden Stammordner und legte für jeden Ordner einen `IndexedFolder`-Eintrag an, auch für jeden Unterordner eines Git-Repositories. Repository-Unterordner unterhalb von Tiefe 2 sind laut `CatalogConfiguration.maxSelectableSubfolderDepth` nicht auswählbar, wurden aber trotzdem synchronisiert.

Unter `~/Github` mit 69 Ordnern und 68 Repositories direkt im Stammordner waren das rund 23.000 Einträge. Nach ADR-0027 lud der Mac sie alle nach CloudKit hoch, und der Abgleich dauerte entsprechend lange. Das Pflichtenheft verlangt „alle **geeigneten** Unterordner“ und dass sie am iPhone auswählbar sind (E1, E2), nicht jeden Unterordner.

Lokale Löschungen werden als Tombstone-Datensatz synchronisiert (ADR-0019). Wäre die Tiefe ohne weitere Änderung verringert worden, wären etwa 20.000 Tombstones dauerhaft in iCloud geblieben.

## Entscheidung

1. **Einstellung `ServiceSettings.folderScanDepth`** (1–8, Standard **1**): Ebenen unter jedem Stammordner, die der Scanner erfasst (`ScanOptions.maxDepth`). Bei 1 werden nur die Ordner direkt im Stammordner erfasst. Ein Repository auf der letzten Ebene wird noch als Repository erkannt, aber nicht betreten. Die Einstellung steht am Mac unter Einstellungen › Dienst und ist hostlokal (nicht synchronisiert). Gespeicherte Einstellungen ohne das Feld erhalten den Standard 1.
2. **Wegfallende Einträge** löscht der nächste Scan lokal, wie bisher bei ausgeschlossenen Ordnern. Ordner mit verknüpftem Projekt bleiben erhalten, auch unterhalb der Tiefe. Das Projekt wird nicht als „nicht verfügbar“ markiert.
3. **Löschen auf dem Server statt Tombstone** für `IndexedFolder` (`SyncRecordSchema.deletesRecordOnServer`). Ist die neueste Operation einer Entität eine Löschung, schickt der Coordinator `deleteRecord` statt eines Tombstone-Datensatzes. Ein schon geplanter Upload wird dabei verworfen. `unknownItem` (nie hochgeladen) gilt als erledigt. Andere Geräte übernehmen die Löschung über den vorhandenen Pfad für harte Löschungen. Der Mac erhält seine eigene Löschung zurück und gleicht sie ohne Konflikt ab, weil die Entität lokal schon fehlt. Das geschieht noch vor der Eigentumsprüfung nach ADR-0026.

Ausnahme zu ADR-0019 nur für `IndexedFolder`. Begründung: Diese Einträge schreibt allein der Mac (ADR-0026), und jeder Scan baut sie neu auf. Kein anderes Gerät braucht eine Versionsnummer, um Konflikte zu erkennen. Alle anderen Entitäten behalten Tombstones.

## Erwogene Alternativen

- **Nur auswählbare Ordner synchronisieren, Tiefe fest:** Das hätte die Datenmenge verringert, aber der Eigentümer wollte die Tiefe einstellen können. Verworfen.
- **Tombstones beibehalten:** Bei jeder Verringerung der Tiefe bliebe ein Datensatz pro Ordner dauerhaft in iCloud. Verworfen.
- **iCloud-Daten löschen und neu hochladen (A34):** Das funktioniert bereits, pausiert aber beide Geräte bis zu einer Entscheidung, und ein im Postausgang wartender Tombstone würde danach wieder hochgeladen. Es bleibt die Notlösung für einen kompletten Neustart.

## Konsequenzen

- Standardmäßig landen nur noch die Ordner direkt im Stammordner in iCloud. Bei `~/Github` sind das rund 70 statt 23.000.
- Wer Unterordner am iPhone auswählen will, erhöht die Tiefe. Die Ordner kommen dann beim nächsten Scan hinzu.
- Beim ersten Scan mit diesem Stand entfernt der Mac die bisher hochgeladenen tiefen Einträge aus iCloud, etwa 92 Anfragen à 250 Datensätze.
- Ein Projekt unterhalb der eingestellten Tiefe bleibt verknüpft. Es wird bei Scans aber nicht mehr aufgefrischt, etwa beim Git-Zustand, solange die Tiefe nicht reicht.

## Verifikation / Akzeptanz

- `Packages/SoftwareRegisseurSync/Tests/SoftwareRegisseurSyncTests/FolderIndexDeletionTests.swift`: Ein gelöschter Ordner verschwindet vom Server und vom iPhone, ohne dass etwas offen bleibt. Das Echo am Mac läuft ohne Konflikt zusammen. Ein nie hochgeladener Ordner hinterlässt nichts. Ein zurückkehrender Ordner wird wieder hochgeladen. Andere Typen behalten Tombstones.
- `Packages/SoftwareRegisseurWorkspace/Tests/SoftwareRegisseurWorkspaceTests/CatalogAndSetupTests.swift` › `FolderScanDepthTests`: Beim Verringern der Tiefe verschwinden tiefe Ordner, ein verknüpftes Projekt bleibt, und ein Repository direkt im Stammordner wird bei Tiefe 1 erkannt.
- `ServiceMessageCodingTests` (Standard, Begrenzung, Kompatibilität alter Einstellungen) und `AgentServiceCoreTests.folderScanDepthLimitsTheCatalogScan`.
- Real: Nach dem Update zeigt `cktool query-records … --record-type IndexedFolder` nur noch die Ordner der eingestellten Tiefe.

## Verweise

ADR-0019, ADR-0026, ADR-0027; Pflichtenheft E1, E2; A03, A34.
