---
adr: 0007
title: "Persistente Agentenwarteschlange, exklusive Locks, Worktrees und Review"
status: accepted
date: 2026-10-30
---

# ADR-0007: Persistente Agentenwarteschlange, exklusive Locks, Worktrees und Review

**Status:** Accepted  
**Datum:** 2026-10-30  
**Entscheidungsträger:** Produktvorgabe des Nutzers; technische Einzelheiten sind vor Implementierung zu prüfen.

## Kontext

Agenten können gleichzeitig arbeiten, zeitversetzt starten und bei Kontingentlimits warten. Unkoordinierte parallele Änderungen gefährden Repositories.

## Entscheidung

Aufträge erhalten idempotente IDs und persistente Zustandsmaschine. Beim tatsächlichen Start exklusive Task-Locks mit Lease/Heartbeat/Recovery, isolierte Git-Worktrees/Branches und definierte Parallelitätslimits. Ein einmaliger manueller oder zeitgesteuerter Start über CloudKit; Retry nach nachvollziehbaren Quota-Fehlern. Nach Agentenende Status `review`, nicht `done`; Übernahme/Commit/Integration und Abschluss erfolgen nach Prüfschritten und Benutzerfreigabe. Keine stillen Pushes.

## Erwogene Alternativen

Direkt in Main-Branch ausführen; pro Repo pauschal nur einen Task zulassen; beliebig parallel starten; nach Agentenende automatisch als erledigt markieren.

## Konsequenzen

Sicherheit und Prüfqualität steigen, technischer Aufwand für Taskzustände, Reconciliation, Konflikte und Crash-Recovery.

## Verifikation / Akzeptanz

A13–A23, A30, A33, A39; Tests mit abgebrochenen und parallelen Läufen.

## Verweise

- Verbindliches Pflichtenheft
- [ADR-Index](README.md)
