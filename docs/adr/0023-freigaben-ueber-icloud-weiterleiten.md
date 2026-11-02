---
adr: 0023
title: "Agenten-Freigaben werden vom Mac über iCloud an das iPhone weitergeleitet"
status: accepted
date: 2026-10-30
---

# ADR-0023: Agenten-Freigaben werden vom Mac über iCloud an das iPhone weitergeleitet

**Status:** Accepted  
**Datum:** 2026-10-30  
**Entscheidungsträger:** Implementierung; konkretisiert den in Pflichtenheft J4/J6 verlangten V1-Fallback. Entscheidet ADR-0010 nicht.

## Kontext

Laufende Agenten fragen Freigaben an (Befehle, Dateizugriffe). Ob von Software Regisseur gestartete Sitzungen in der offiziellen Codex- bzw. Claude-App bedienbar sind, ist laut Spikes offen (ADR-0010 `proposed`). Pflichtenheft J4 verlangt dafür eine „integrierte minimal notwendige Status-/Approval-Anzeige via unterstütztem Protokoll“, L3 verbietet automatische Freigaben.

## Entscheidung

- Der Mac-Adapter empfängt Freigabeanfragen über das dokumentierte Protokoll des Agenten (Codex app-server, Claude stream-json `can_use_tool`).
- Der Jobs-Orchestrator speichert sie als `PendingApproval` (Zusammenfassung, mit `SecretRedactor` bereinigte Befehlsvorschau, Ablaufzeit) in der Datenbank; sie werden per CloudKit synchronisiert.
- iPhone und Mac zeigen offene Freigaben an; eine Entscheidung wird als `ApprovalDecision` gespeichert und synchronisiert. Der Mac leitet sie genau einmal an den Agenten weiter.
- Entscheidungen zu abgelaufenen, bereits beantworteten oder beendeten Anfragen werden ignoriert. Ohne Antwort greift die konfigurierte Zeitüberschreitung (Standard: Job pausieren); es gibt nie eine automatische Zustimmung.
- Latenz hängt von der Synchronisierung ab (ADR-0011): Am iPhone erscheint eine Anfrage beim Öffnen/Aktualisieren der App, nicht als Push-Mitteilung.

## Erwogene Alternativen

Nur Mac-UI für Freigaben (iPhone-Workflow bricht ab); eigener Relay-Server (widerspricht „kein Backend-Zwang“); sichtbare Push-Mitteilungen (widerspricht ADR-0011); automatische Freigaben nach Regeln (widerspricht L3).

## Konsequenzen

Freigaben funktionieren unabhängig vom Ausgang des ADR-0010-Spikes. Die Befehlsvorschau verlässt den Mac (redigiert) und liegt in der privaten iCloud-Datenbank des Benutzers. Antwortzeiten im Minutenbereich sind möglich.

## Verifikation / Akzeptanz

Jobs-Tests für Weiterleitung, Ablauf und Doppelantwort; End-to-End mit signierter App und echtem Agenten (A20).

## Verweise

- Pflichtenheft, Abschnitte J4, J6, L3
- [ADR-0010](0010-offizielle-mobile-agenten-sitzungen.md), [ADR-0011](0011-cloudkit-ohne-sichtbare-push-benachrichtigungen.md), [ADR-0021](0021-agenten-adapter-schnittstellen.md)
- [ADR-Index](README.md)
