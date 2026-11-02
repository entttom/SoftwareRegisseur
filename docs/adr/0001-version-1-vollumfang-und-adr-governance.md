---
adr: 0001
title: "Version 1.0 ist vollständig; ADR-Verfahren"
status: accepted
date: 2026-10-30
---

# ADR-0001: Version 1.0 ist vollständig; ADR-Verfahren

**Status:** Accepted  
**Datum:** 2026-10-30  
**Entscheidungsträger:** Produktvorgabe des Nutzers; technische Einzelheiten sind vor Implementierung zu prüfen.

## Kontext

Alle bisher bestätigten Produktanforderungen sollen bereits in der ersten veröffentlichten Version enthalten sein. Neue Implementierungsagenten benötigen ein belastbares Entscheidungsregister statt eines nur mündlich beschriebenen Vorhabens.

## Entscheidung

Software Regisseur Version 1.0 umfasst den gesamten im Pflichtenheft beschriebenen Funktionsumfang; interne Meilensteine sind lediglich Entwicklungsschritte. Das Projekt verwendet ab Repository-Initialisierung MADR-artige Markdown-ADRs unter `docs/adr/`. `accepted`-ADRs sind verbindlich, `proposed`-ADRs sind zu validieren. Substantielle Änderungen werden in einem neuen ADR dokumentiert, der den Vorgänger `superseded` setzt. Nur der Benutzer beziehungsweise ein ausdrücklich autorisierter Entscheider akzeptiert grundlegende Produktentscheidungen. Die Implementierung kann technische Entscheidungen dokumentieren, darf bestehende angenommene Grundsatzentscheidungen nicht eigenmächtig umkehren.

## Erwogene Alternativen

Kein ADR-Prozess; ADRs erst nach der Implementierung erstellen; reduziertes MVP veröffentlichen.

## Konsequenzen

Entscheidungen bleiben nachvollziehbar; mehr initialer Dokumentationsaufwand. Externe technische Einschränkungen werden nicht verschwiegen, sondern mit erprobten v1-Fallbacks dokumentiert.

## Verifikation / Akzeptanz

V1-Abnahmematrix A01–A42; ADR-Index und Statusänderungs-Historie vorhanden.

## Verweise

- Verbindliches Pflichtenheft
- [ADR-Index](README.md)
