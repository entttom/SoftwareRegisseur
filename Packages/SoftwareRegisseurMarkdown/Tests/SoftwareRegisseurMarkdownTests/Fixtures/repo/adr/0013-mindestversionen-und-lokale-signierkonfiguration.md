---
adr: 0013
title: "Mindestversionen iOS 26 / macOS 26; Signier- und CloudKit-IDs in lokaler xcconfig"
status: accepted
date: 2026-10-30
---

# ADR-0013: Mindestversionen iOS 26 / macOS 26; Signier- und CloudKit-IDs in lokaler xcconfig

**Status:** Accepted  
**Datum:** 2026-10-30  
**Entscheidungsträger:** Benutzer (Klärung offener Punkte vor M0).

## Kontext

Das Pflichtenheft (B) verlangt, die Mindestversion bei Projektanlage konservativ festzulegen und zu dokumentieren. Q3 verbietet hart kodierte Team-Identifier. Entwicklungsumgebung zum Entscheidungszeitpunkt: Xcode 27.0, Swift 6.4, macOS 27.

## Entscheidung

- **Deployment Targets:** iOS 26.0 und macOS 26.0, Apple Silicon als primäres Mac-Ziel. Alle benötigten APIs (`CKSyncEngine`, SwiftData, `MenuBarExtra`, `SMAppService`, Speech) sind dort verfügbar. Ein Jahrgang Rückstand zur aktuellen Version 27.
- **Team-ID, Bundle-ID-Präfix und CloudKit-Container** stehen ausschließlich in `Config/Local.xcconfig`, die per `.gitignore` ausgeschlossen ist. Eingecheckt wird nur `Config/Local.xcconfig.template` mit Platzhaltern. Projekt-Build-Settings, Entitlements und Code referenzieren die Werte über Build-Variablen.
- Fehlt `Local.xcconfig`, schlägt der Build mit verständlicher Meldung fehl statt mit fremder oder leerer Team-ID zu signieren.

## Erwogene Alternativen

iOS 27 / macOS 27 (kleinste Zielgruppe ohne nötigen API-Gewinn); iOS 18 / macOS 15 (breiter, aber mehr Verfügbarkeitsprüfungen und ältere SwiftData-/Sync-Stände). Team-ID direkt im Xcode-Projekt (verletzt Q3 und erschwert Fremd-Builds).

## Konsequenzen

Jeder Entwickler bzw. CI-Lauf braucht eine eigene `Local.xcconfig`. Release-Skripte lesen dieselben Variablen. Eine spätere Anhebung der Mindestversion erfolgt per neuem ADR.

## Verifikation / Akzeptanz

Build ohne `Local.xcconfig` scheitert mit Hinweis; Build mit Vorlage-Werten erzeugt keine Commits mit echten IDs (`git grep` auf Team-ID im Release-Check). A28.

## Verweise

- [Verbindliches Pflichtenheft](../../Software_Regisseur_1.0_Codex_Entwicklungsauftrag.md), Abschnitte B, Q3, Q4
- [ADR-0009](0009-direktvertrieb-signierung-sandbox-prufung.md)
- [ADR-Index](README.md)
