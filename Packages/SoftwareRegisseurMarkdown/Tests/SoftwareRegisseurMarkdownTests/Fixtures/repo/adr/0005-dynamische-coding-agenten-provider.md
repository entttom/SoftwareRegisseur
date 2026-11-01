---
adr: 0005
title: "Coding-Agenten automatisch erkennen und mobil auswählbar machen"
status: accepted
date: 2026-10-30
---

# ADR-0005: Coding-Agenten automatisch erkennen und mobil auswählbar machen

**Status:** Accepted  
**Datum:** 2026-10-30  
**Entscheidungsträger:** Produktvorgabe des Nutzers; technische Einzelheiten sind vor Implementierung zu prüfen.

## Kontext

Benutzer möchte auf dem Mac installierte und nutzbare Codex- und Claude-Code-Agenten am iPhone automatisch auswählen, ohne jedes Tool doppelt einzurichten.

## Entscheidung

Provider-Adapter mit dynamischer Installationserkennung, Version, Authentifizierungs-/Ausführbarkeitsprüfung, Fähigkeiten und Remote-Control-Verfügbarkeit. Agenten werden nur als startbar gezeigt, wenn sie auf einem erreichbaren Host wirklich verwendbar sind. Gerätefähigkeiten über CloudKit synchronisieren; UI markiert zwischengespeicherte/offline Werte. Optionaler Standardagent je Projekt.

## Erwogene Alternativen

Feste Agentenliste ohne Installationserkennung; Remote-Agenten auf externem Server; alle Programme ungeprüft anbieten.

## Konsequenzen

Plugin-/Adapterarchitektur schafft Erweiterbarkeit; Capability-Prüfung muss dokumentierte, nichtinvasive Tests verwenden.

## Verifikation / Akzeptanz

A12–A14, A33, A35–A42; keine unbegründeten „einsatzbereit“-Angaben.

## Verweise

- [Verbindliches Pflichtenheft](../../Software_Regisseur_1.0_Codex_Entwicklungsauftrag.md)
- [ADR-Index](README.md)
