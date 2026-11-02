---
adr: 0004
title: "Konfigurierbare Markdown-Pfade und dynamische Agentenanweisungen"
status: accepted
date: 2026-10-30
---

# ADR-0004: Konfigurierbare Markdown-Pfade und dynamische Agentenanweisungen

**Status:** Accepted  
**Datum:** 2026-10-30  
**Entscheidungsträger:** Produktvorgabe des Nutzers; technische Einzelheiten sind vor Implementierung zu prüfen.

## Kontext

Projekte nutzen verschiedene Ordnerkonventionen. Codex/Claude müssen die Orte von ADRs, Requests und Statusdateien kennen.

## Entscheidung

Globale Standardpfade und Projekt-Overrides für ADRs, Inbox/Requests und Statusordner. Status steht sowohl im Frontmatter als auch in synchronisierten Indizes. Software Regisseur verwaltet einen markierten Teil von `AGENTS.md` und ergänzt kompatible `CLAUDE.md`-Integration nur bei Bedarf. Vorhandene Inhalte dürfen nicht überschrieben werden; Migration mit Vorschau, Sicherung und Git-Diff.

## Erwogene Alternativen

Eine feste Ordnerstruktur für alle Projekte erzwingen; ganze AGENTS.md automatisch überschreiben; Status nur aus Dateipfad ableiten.

## Konsequenzen

Höhere Flexibilität und geringere Agentenfehler; Pfadmigration und bestehende Repository-Strukturen erfordern sorgfältige Tests.

## Verifikation / Akzeptanz

A05, A06, A23, A30; manuelle AGENTS.md-Inhalte bleiben intakt.

## Verweise

- Verbindliches Pflichtenheft
- [ADR-Index](README.md)
