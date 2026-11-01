---
adr: 0003
title: "Git/Markdown als langlebige Projektartefakte; CloudKit für Synchronisierung"
status: accepted
date: 2026-10-30
---

# ADR-0003: Git/Markdown als langlebige Projektartefakte; CloudKit für Synchronisierung

**Status:** Accepted  
**Datum:** 2026-10-30  
**Entscheidungsträger:** Produktvorgabe des Nutzers; technische Einzelheiten sind vor Implementierung zu prüfen.

## Kontext

Aufgaben, ADRs und Entscheidungen sollen in bestehenden Entwickler-Repositories erhalten bleiben und am iPhone ohne Direktzugriff auf lokale Mac-Dateien sichtbar sein.

## Entscheidung

Das Repository speichert menschenlesbare Markdown-Dateien als langfristig maßgebliche Projektartefakte. Lokale Datenbank hält Index, Notizen, Aufträge, Zustände und Sync-Metadaten. CloudKit Private Database synchronisiert zwischen iOS und macOS; nur der Mac-Hintergrunddienst schreibt in lokale Git-Repositories. Keine ganzen Git-Repositories in iCloud kopieren. Datei- und Cloud-Änderungen werden reconciled, Konflikte sichtbar gemacht.

## Erwogene Alternativen

Vollständiges Git-Repo über iCloud Drive; ausschließlich Cloud-Datenbank ohne Markdown; direkter Git-Zugriff am iPhone.

## Konsequenzen

Portabilität und lokaler Betrieb; Herausforderung bei Offline-Konflikten, Versionsschemata und Reconciliation.

## Verifikation / Akzeptanz

A03, A04, A10, A24, A33, A34; idempotente Updates und Konflikttests.

## Verweise

- [Verbindliches Pflichtenheft](../../Software_Regisseur_1.0_Codex_Entwicklungsauftrag.md)
- [ADR-Index](README.md)
