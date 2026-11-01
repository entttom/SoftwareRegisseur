---
adr: 0014
title: "Version 1.0 für Eigengebrauch; Vertrieb an Dritte nur per neuem ADR"
status: accepted
date: 2026-10-30
---

# ADR-0014: Version 1.0 für Eigengebrauch; Vertrieb an Dritte nur per neuem ADR

**Status:** Accepted  
**Datum:** 2026-10-30  
**Entscheidungsträger:** Benutzer (Klärung offener Punkte vor M0).

## Kontext

Das Pflichtenheft nennt Direktvertrieb und App-Store-Distribution, legt aber nicht fest, ob die App an Dritte geht. Davon hängen Lizenzfragen bei der Anbindung von Claude Code und Codex (J5: kein Weiterreichen von Abo-Logins oder Kontingenten an Drittprodukte), App-Store-Prüfung, Datenschutzerklärung und Support ab.

## Entscheidung

Version 1.0 ist für den Eigengebrauch des Entwicklers bestimmt.

- iOS: Installation über TestFlight bzw. Entwickler-Builds. App-Store-Konformität (Privacy Manifest, Nutzungsbeschreibungen, Guideline 5.1.1(iv)) wird trotzdem eingehalten, damit ein späterer Vertrieb nicht an der Grundlage scheitert.
- macOS: Developer-ID-signiert, notarisiert, gestapelt (ADR-0009 bleibt unverändert).
- Codex und Claude Code laufen ausschließlich mit dem eigenen Login des Benutzers und nur über offiziell dokumentierte Wege (CLI, app-server, Remote Control, Agent SDK, soweit die jeweiligen Bedingungen den Einsatz erlauben). Die Bedingungen werden in M0 gegen die aktuelle Herstellerdokumentation geprüft und im Spike-Protokoll belegt.
- Der volle Funktionsumfang nach ADR-0001 bleibt bestehen; Eigengebrauch ist keine Funktionsreduktion.

## Erwogene Alternativen

Vertrieb an Dritte bereits in v1: erfordert vorab Lizenzklärung mit Anthropic und OpenAI, öffentliche Datenschutzerklärung und Support-Prozesse.

## Konsequenzen

Weniger rechtliche Vorarbeit vor v1. Ein späterer Vertrieb braucht einen neuen ADR, der diesen ersetzt, und eine erneute Prüfung von J5 und der App-Store-Richtlinien.

## Verifikation / Akzeptanz

Spike-Protokoll zu den Nutzungsbedingungen von Codex und Claude Code unter `docs/integration-spikes/`; A14, A28, A31, A32.

## Verweise

- [Verbindliches Pflichtenheft](../../Software_Regisseur_1.0_Codex_Entwicklungsauftrag.md), Abschnitte B, J5, Q3, Q4
- [ADR-0001](0001-version-1-vollumfang-und-adr-governance.md), [ADR-0009](0009-direktvertrieb-signierung-sandbox-prufung.md)
- [ADR-Index](README.md)
