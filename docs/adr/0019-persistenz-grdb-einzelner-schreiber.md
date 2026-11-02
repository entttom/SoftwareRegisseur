---
adr: 0019
title: "Lokale Persistenz mit GRDB (SQLite); Agent Service ist einziger Schreiber am Mac"
status: accepted
date: 2026-10-30
---

# ADR-0019: Lokale Persistenz mit GRDB (SQLite); Agent Service ist einziger Schreiber am Mac

**Status:** Accepted  
**Datum:** 2026-10-30  
**Entscheidungsträger:** Implementierung, auf Basis von [M0-Recherche](../integration-spikes/apple-platform.md).

## Kontext

Pflichtenheft C.3 verlangt SwiftData oder SQLite/GRDB nach dokumentierter Abwägung, mit versioniertem Schema, Migrationen, Transaktionen und einer kontrollierbaren CloudKit-Sync-Schicht (`CKSyncEngine`). Am Mac greifen zwei Prozesse (UI-App und Agent Service) auf dieselben Daten zu.

## Entscheidung

- **GRDB 7** (SQLite, WAL-Modus) auf iOS und macOS, mit expliziten, nummerierten Migrationen und `IMMEDIATE`-Transaktionen.
- Synchronisierung über eine eigene Schicht mit `CKSyncEngine` (`automaticallySync = false`, manuelles `fetchChanges`/`sendChanges`), persistierter Engine-Zustand und Outbox/Inbox in derselben Datenbank.
- **macOS:** Der Agent Service ist einziger Schreiber und einziger Besitzer der `CKSyncEngine`. Die UI-App liest und schreibt über XPC (ADR-0020); optional direkter Nur-Lese-Zugriff. Datenbank im Team-ID-präfixierten App-Group-Container.
- **iOS:** Datenbank im eigenen App-Container (kein App-Group-Container), um Abbrüche durch gehaltene SQLite-Sperren beim Suspendieren zu vermeiden.
- SwiftData wird nicht verwendet. Die Begründung „SwiftData verfügbar“ in ADR-0013 ist damit gegenstandslos; die Mindestversionen bleiben unverändert.

## Erwogene Alternativen

SwiftData mit `NSPersistentCloudKitContainer`: keine manuelle Kontrolle über Fetch/Send, implizite Sync-Semantik (widerspricht C.3 und ADR-0011), keine dokumentierte Mehrprozess-Strategie. SwiftData ohne CloudKit plus eigene Sync-Schicht: möglich, aber Migrationen und Transaktionskontrolle schwächer als bei GRDB.

## Konsequenzen

Externe Abhängigkeit (GRDB, Version exakt gepinnt). Mehr Handarbeit bei Modellen und Abfragen, dafür prüfbare Migrationen und klare Nebenläufigkeit. XPC wird Pflichtpfad für Schreibzugriffe der Mac-UI.

## Verifikation / Akzeptanz

Migrationstests von leerer und älterer Datenbank; Mehrprozesstest (Service schreibt, UI liest); Absturz während Transaktion; Spike S1 (CKSyncEngine im Agent-Bundle, nur Polling). A10, A21, A24, A33.

## Verweise

- Pflichtenheft, Abschnitte C, N
- [ADR-0003](0003-git-markdown-und-cloudkit.md), [ADR-0011](0011-cloudkit-ohne-sichtbare-push-benachrichtigungen.md), [ADR-0013](0013-mindestversionen-und-lokale-signierkonfiguration.md)
- [ADR-Index](README.md)
