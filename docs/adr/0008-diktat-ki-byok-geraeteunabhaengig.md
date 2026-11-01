---
adr: 0008
title: "Diktat und KI-Ausarbeitung auf iOS mit eigenen API-Keys"
status: accepted
date: 2026-10-30
---

# ADR-0008: Diktat und KI-Ausarbeitung auf iOS mit eigenen API-Keys

**Status:** Accepted  
**Datum:** 2026-10-30  
**Entscheidungsträger:** Produktvorgabe des Nutzers; technische Einzelheiten sind vor Implementierung zu prüfen.

## Kontext

Ideen sollen unterwegs schnell gesprochen und vor Git-Ablage in strukturierte Aufgaben umgewandelt werden, auch wenn der Mac nicht erreichbar ist.

## Entscheidung

Native Apple-Spracherkennung und API-basierte Transkription (mindestens OpenAI) sind direkt auf iOS wählbar. KI-Ausarbeitung und Klassifizierung unabhängig vom Mac über BYOK-Anbieter (OpenAI, Anthropic, Gemini) mit gewähltem Modell. Geräteseparater Schlüssel im Keychain; Transkription und Ausarbeitung getrennte Konfiguration. Optional Originalaudio speichern; andernfalls nach erfolgreichem Import löschen. KI-Entwürfe und Originaltext versioniert aufbewahren; Benutzer prüft vor Übernahme. Mac-Kontextanreicherung zusätzlich möglich.

## Erwogene Alternativen

Nur Siri-/Apple-Diktat; immer auf Mac für KI warten; API-Key der Codex-/Claude-Code-Anmeldung wiederverwenden.

## Konsequenzen

Mobiler Workflow unabhängig; datenschutzbewusste Übermittlung und Kostenhinweise notwendig.

## Verifikation / Akzeptanz

A07–A11, A27, A34; iOS-offline und Provider-Fehler testen.

## Verweise

- [Verbindliches Pflichtenheft](../../Software_Regisseur_1.0_Codex_Entwicklungsauftrag.md)
- [ADR-Index](README.md)
