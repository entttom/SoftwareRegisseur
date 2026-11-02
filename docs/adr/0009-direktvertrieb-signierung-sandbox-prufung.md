---
adr: 0009
title: "Direktvertrieb als Developer-ID-signierte und notarisierte macOS-App"
status: accepted
date: 2026-10-30
---

# ADR-0009: Direktvertrieb als Developer-ID-signierte und notarisierte macOS-App

**Status:** Accepted  
**Datum:** 2026-10-30  
**Entscheidungsträger:** Produktvorgabe des Nutzers; technische Einzelheiten sind vor Implementierung zu prüfen.

## Kontext

Die Mac-App muss externe Coding-Agenten und Git-Kommandos ausführen; eine strikte App Sandbox könnte dies behindern.

## Entscheidung

Direkter Vertrieb außerhalb des Mac App Stores mit Developer ID Application, Hardened Runtime, Notarisierung und Stapling. Technischen Sandbox-Spike für UI, Dateizugriff, Login-Item und externen Agent Service durchführen. Falls machbar, UI sandboxed mit klar getrennter ausführender Komponente; andernfalls bewusst unsandboxed, mit begrenzten Nutzerberechtigungen, sicherer Prozessausführung und dokumentierten Risiken. Nicht fälschlich behaupten, dass Notarisierung die Sandbox verlangt.

## Erwogene Alternativen

Mac App Store als zwingenden Vertrieb; Sandbox-Sicherheit ohne Prototyp behaupten; ungeprüften unsignierten Installer ausliefern.

## Konsequenzen

Geringere Reibung für lokale Agenten, aber direkte Verantwortung für Updates und Sicherheitsgrenzen.

## Verifikation / Akzeptanz

A01, A28, A30; reale Signatur-/Notarisierungs- und Sandbox-Prüfung erforderlich.

## Verweise

- Verbindliches Pflichtenheft
- [ADR-Index](README.md)
