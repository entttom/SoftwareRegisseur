---
adr: 0002
title: "Native iOS-App und macOS-Menüleisten-App mit Hintergrunddienst"
status: accepted
date: 2026-10-30
---

# ADR-0002: Native iOS-App und macOS-Menüleisten-App mit Hintergrunddienst

**Status:** Accepted  
**Datum:** 2026-10-30  
**Entscheidungsträger:** Produktvorgabe des Nutzers; technische Einzelheiten sind vor Implementierung zu prüfen.

## Kontext

Software Regisseur muss mobil unabhängig funktionieren und auf dem Mac dauerhafte Git-/Agentenarbeiten erledigen, obwohl das Hauptfenster geschlossen ist.

## Entscheidung

SwiftUI für iPhone und macOS; macOS-App mit `MenuBarExtra` und Hauptfenster. Eigenständiger, im Benutzerkontext laufender Hintergrunddienst mit kontrollierter IPC und automatischem Start beim Login. Kein für Kernfunktionen erforderlicher zentraler Server.

## Erwogene Alternativen

Electron/Tauri-Weboberfläche; nur Fenster-App ohne Login-Service; dauerhaft notwendiger externer Server.

## Konsequenzen

Nativ gute Integration, aber IPC, Lifecycle, Power- und App-Update-Recovery müssen explizit getestet werden.

## Verifikation / Akzeptanz

A01, A10, A17–A21; Hintergrunddienst übersteht geschlossene Fenster, keine unbeabsichtigte doppelte Instanz.

## Verweise

- Verbindliches Pflichtenheft
- [ADR-Index](README.md)
