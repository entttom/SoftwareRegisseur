---
adr: 0011
title: "CloudKit-Synchronisierung ohne sichtbare Push-Benachrichtigungen"
status: accepted
date: 2026-10-30
---

# ADR-0011: CloudKit-Synchronisierung ohne sichtbare Push-Benachrichtigungen

**Status:** Accepted  
**Datum:** 2026-10-30  
**Entscheidungsträger:** Produktvorgabe des Nutzers; technische Einzelheiten sind vor Implementierung zu prüfen.

## Kontext

Der Nutzer möchte keine sichtbaren Push-Benachrichtigungen, aber dennoch iPhone↔Mac-Synchronisierung und zuverlässige Aufträge.

## Entscheidung

Keine sichtbaren Benutzer-Push-Notifications. iPhone synchronisiert beim Öffnen/Aktivieren/manuell und hält lokal eine Offline-Queue vor. Mac-Hintergrunddienst fragt CloudKit kontrolliert periodisch ab und nach Wiederverfügbarkeit erneut. Hintergrundsignale dürfen optional optimieren, sind aber keine zeitkritische Zusicherung; App zeigt Sync-Zeitpunkte und Hoststatus.

## Erwogene Alternativen

Sichtbare APNs-Benachrichtigungen zur Statusübermittlung; externer Pflicht-Backend-Server; rein spontane Push-Trigger ohne Poll-Recovery.

## Konsequenzen

Weniger Benachrichtigungsaufwand, aber variable Latenz und Poll-Quota; Energieverbrauch und Fehlerbehandlung sorgfältig optimieren.

## Verifikation / Akzeptanz

A10, A17–A19, A24, A26, A33.

## Verweise

- [Verbindliches Pflichtenheft](../../Software_Regisseur_1.0_Codex_Entwicklungsauftrag.md)
- [ADR-Index](README.md)
