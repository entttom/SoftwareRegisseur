---
adr: 0018
title: "Menschenlesbare Aufgaben-IDs vergibt ausschließlich der Mac-Host"
status: accepted
date: 2026-10-30
---

# ADR-0018: Menschenlesbare Aufgaben-IDs vergibt ausschließlich der Mac-Host

**Status:** Accepted  
**Datum:** 2026-10-30  
**Entscheidungsträger:** Implementierung (technischer Standard, dem Benutzer am 30.10.2026 vorgestellt).

## Kontext

Pflichtenheft F3 verlangt IDs wie `FR-0001`, eindeutig pro Repository, plus eine global eindeutige UUID. Das iPhone legt Aufgaben auch offline an und kennt dann weder die zuletzt vergebene Nummer im Repository noch Aufgaben, die ein anderes Gerät oder ein Agent inzwischen angelegt hat. Für Todo, Improvement und Notiz nennt das Pflichtenheft keine Präfixe.

## Entscheidung

- Jede Aufgabe erhält bei Anlage sofort eine UUID; sie ist die einzige Identität für Sync, Jobs und Verweise.
- Die menschenlesbare ID vergibt **nur der Mac-Host**, wenn er die Request-Datei im Repository anlegt. Er bestimmt die nächste freie Nummer aus den vorhandenen Dateien und dem lokalen Index, nicht aus einem Zähler in CloudKit. Bis dahin zeigt die UI „noch keine Nummer“.
- Präfixe: Feature `FR`, Bug `BUG`, Todo `TODO`, Improvement/Refactoring `IMP`, Notiz `NOTE`. Vierstellig mit führenden Nullen, bei Bedarf mehr Stellen. Nummernkreis pro Präfix und Repository.
- ADRs nutzen weiterhin `NNNN` ohne Präfix und einen eigenen Nummernkreis.
- Eine vergebene ID wird nie neu vergeben, auch nicht nach Löschen oder Umbenennen.

## Erwogene Alternativen

Zähler in CloudKit (Konflikte bei Offline-Anlage auf mehreren Geräten); ID am iPhone vorläufig vergeben und später umnummerieren (verwirrend, Verweise brechen).

## Konsequenzen

Keine doppelten IDs durch Offline-Anlage. Aufgaben ohne Mac-Verbindung haben vorübergehend keine Nummer; Verweise zwischen Aufgaben laufen daher immer über die UUID.

## Verifikation / Akzeptanz

Unit-Tests für Parsen/Formatieren; Integrationstest: zwei offline angelegte Aufgaben erhalten nach Mac-Sync unterschiedliche, lückenlose Nummern. A03, A10, A24.

## Verweise

- Verbindliches Pflichtenheft, Abschnitt F3
- [ADR-0003](0003-git-markdown-und-cloudkit.md), [ADR-0012](0012-getrennte-status-zustandsmaschinen.md)
- [ADR-Index](README.md)
