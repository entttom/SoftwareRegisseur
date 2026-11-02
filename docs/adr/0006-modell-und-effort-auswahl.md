---
adr: 0006
title: "Freie Modellwahl und Denk-/Effort-Stufen je Coding-Agent"
status: accepted
date: 2026-10-30
---

# ADR-0006: Freie Modellwahl und Denk-/Effort-Stufen je Coding-Agent

**Status:** Accepted  
**Datum:** 2026-10-30  
**Entscheidungsträger:** Produktvorgabe des Nutzers; technische Einzelheiten sind vor Implementierung zu prüfen.

## Kontext

Bei jedem Agentenauftrag muss der Benutzer das konkrete Modell und die Stärke des Reasonings wählen können: von niedrig über mittel und hoch bis zu den weiteren jeweils verfügbaren Stufen. Unterschiedliche Agenten und Modellversionen unterstützen unterschiedliche Stufen; der Benutzer möchte die Wahl sowohl am Mac als auch auf dem iPhone.

## Entscheidung

Modell und Denk-/Effort-Stufe als **zwei getrennte Felder** in einer dynamischen Provider-Capability-Matrix. Drei Voreinstellungsebenen: global je Agent, pro Projekt je Agent, Override pro Auftrag; Auflösung Auftrag > Projekt > global > Anbieterstandard. Stufen `auto`, `low`, `medium`, `high`, `xhigh` und `max` nur anzeigen/aktivieren, wenn tatsächlich unterstützt. Modelle anhand der installierten Agentenversion und Accountberechtigung ermitteln, nicht nur anhand eines öffentlichen API-Katalogs. Ausführungskonfiguration vor Start validieren und als Snapshot dauerhaft an den Job binden. Bei inkompatibler Konfiguration blockieren und explizite Neuauswahl verlangen, kein stiller Fallback. Effektives Modell/Effort nur als bestätigt anzeigen, wenn vom Adapter nachweisbar. Die **Aufgabenkomplexität als Planungsmetadatum** ist von der Effort-Stufe getrennt. KI-Textausarbeitung/Transkription haben eigene unabhängige Modellsettings.

## Erwogene Alternativen

Ein einziges globales Modell; feste Liste von heute verfügbaren Modell-IDs; Effort als künstliche Prompt-Formulierung simulieren; Agentenunterschiede ignorieren.

## Konsequenzen

Mehr benutzerseitige Kontrolle, konsistentes Scheduling und bessere Nachvollziehbarkeit; zusätzliche Capability-Checks und modellabhängige UI/Tests nötig. Keine unbelegte Unterstützung behaupten.

## Verifikation / Akzeptanz

A35–A42. Tests für Stufenfilter, globale/Projekt-/Job-Vererbung, Offline-Metadaten, geplante Jobs, Agentenupgrade, effektive Startparameter.

## Verweise

- Verbindliches Pflichtenheft
- [ADR-Index](README.md)
