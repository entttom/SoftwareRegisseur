---
adr: 0025
title: "Die iOS-App unterstützt iPhone und iPad"
status: accepted
date: 2026-10-30
---

# ADR-0025: Die iOS-App unterstützt iPhone und iPad

**Status:** Accepted  
**Datum:** 2026-10-30  
**Entscheidungsträger:** Benutzer.

## Kontext

Das Pflichtenheft nannte als mobile Plattform nur das iPhone. Die iOS-App lief bereits als Universal-App auf dem iPad, enthielt aber iPhone-spezifische Texte.

## Entscheidung

- Die iOS-App ist eine Universal-App für iPhone und iPad (iOS/iPadOS 26).
- Das iPad erhält eine eigene, großflächige Darstellung (Seitenleiste mit allen Bereichen, Split-View-Detailansichten), unterstützt Multitasking-Fenstergrößen, Tastatur und Zeiger.
- Texte sind gerätegerecht („auf diesem iPad“ bzw. „auf diesem iPhone“ oder neutral „auf diesem Gerät“), auch in Berechtigungs-Erklärungen.
- Funktionsumfang, Synchronisierung und Regeln (Berechtigungs-Erklärbildschirme nach Q4, keine Push-Mitteilungen) sind auf beiden Geräten gleich.

## Erwogene Alternativen

Nur iPhone (iPad im Kompatibilitätsmodus): schlechtere Nutzung auf dem iPad.

## Konsequenzen

Zusätzliche Layout- und UI-Tests für iPad-Größen; A29 (Bedienungshilfen, Dark Mode, Dynamic Type) gilt auch für das iPad.

## Verifikation / Akzeptanz

Screenshots und UI-Prüfung auf iPad-Simulatoren in Vollbild und Split View; A07–A10, A26, A29 zusätzlich auf dem iPad.

## Verweise

- Pflichtenheft, Abschnitte B, H1, P
- [ADR-0002](0002-native-apple-menuleiste-hintergrunddienst.md)
- [ADR-Index](README.md)
