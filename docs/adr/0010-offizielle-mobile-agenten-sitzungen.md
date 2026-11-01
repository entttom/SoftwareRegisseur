---
adr: 0010
title: "Offizielle mobile Codex-/Claude-Steuerung bevorzugen"
status: proposed
date: 2026-10-30
---

# ADR-0010: Offizielle mobile Codex-/Claude-Steuerung bevorzugen

**Status:** Proposed  
**Datum:** 2026-10-30  
**Entscheidungsträger:** Produktvorgabe des Nutzers; technische Einzelheiten sind vor Implementierung zu prüfen.

## Kontext

Der Benutzer möchte Aufgaben am iPhone aus Software Regisseur starten und dann bevorzugt die tatsächliche Agentensitzung in der offiziellen ChatGPT/Codex- bzw. Claude-App weiterführen.

## Entscheidung

Integration über dokumentierte und verifizierte Start-/Remote-Schnittstellen; vor allem echte Sitzungskompatibilität bei einem vollautomatisch von der Mac-App gestarteten Agenten in realer mobiler App belegen. Ist dies für einen Agenten nicht technisch verfügbar, innerhalb v1 eine klar bezeichnete, funktionsfähige alternative Bedienung verwenden, ohne einen Remote-Link vorzutäuschen. Automatischer Jobstart und mobile Anschlussfähigkeit sind separat zu testen. Erst nach bestandenem realen Test konkrete URL-Schemata in Produktionscode verwenden.

## Erwogene Alternativen

Eigene vollständige Code-Chat-App nachbauen; Deep Link mit vorbefülltem Prompt als bereits abgesendeten Auftrag behandeln.

## Konsequenzen

Bessere UX bei funktionierender Integration; Abhängigkeit von externen App-/CLI-Fähigkeiten und Anbieterpolitik. Architektur behält Provider-spezifische Fallbacks.

## Verifikation / Akzeptanz

A13, A14, A20, A31, A32; nachvollziehbarer E2E-Spike pro Anbieter. Entscheidung erst nach Spike auf accepted setzen.

## Verweise

- [Verbindliches Pflichtenheft](../../Software_Regisseur_1.0_Codex_Entwicklungsauftrag.md)
- [ADR-Index](README.md)
