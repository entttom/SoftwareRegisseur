---
adr: 0020
title: "Agent Service als unsandboxed SMAppService-Agent mit XPC; UI-Sandbox nach Spike"
status: accepted
date: 2026-10-30
---

# ADR-0020: Agent Service als unsandboxed SMAppService-Agent mit XPC; UI-Sandbox nach Spike

**Status:** Accepted  
**Datum:** 2026-10-30  
**Entscheidungsträger:** Implementierung, auf Basis von [M0-Recherche](../integration-spikes/apple-platform.md); konkretisiert ADR-0002 und ADR-0009.

## Kontext

Der Hintergrunddienst startet `git`, `codex` und `claude` in benutzergewählten Repositories. Kindprozesse erben die App Sandbox eines sandboxed Elternprozesses; die Hardened Runtime kennt kein Entitlement für das Starten externer Programme.

## Entscheidung

- Der Agent Service ist ein eigenes, im App-Bundle eingebettetes, app-artiges Bundle mit Provisioning-Profil (für CloudKit-, Push- und Keychain-Group-Entitlements), registriert über `SMAppService.agent(plistName:)` im Benutzerkontext, ohne Root.
- Der Agent Service läuft **ohne App Sandbox**, mit Hardened Runtime, Developer-ID-signiert und notarisiert (ADR-0009).
- IPC zwischen UI-App und Service über XPC (`XPCListener`/`XPCSession`) mit Mach-Service-Namen im App-Group-Präfix und Peer-Prüfung auf dasselbe Team (`XPCPeerRequirement`).
- **Offen (Spike):** ob die UI-App sandboxed laufen soll. Sie wird zunächst ohne Sandbox gebaut; die Entscheidung folgt als eigener ADR nach dem Spike mit Security-Scoped Bookmarks und Sparkle-Installer-XPC.

## Erwogene Alternativen

Komplett sandboxed (Agenten und Git nicht zuverlässig ausführbar); Daemon mit Root-Rechten (unnötige Rechte, widerspricht L3); Service nur als Teil des UI-Prozesses (läuft nicht ohne geöffnete App).

## Konsequenzen

Klare Prozessgrenze: der Service trägt die Verantwortung für Pfadprüfung, Prozessausführung ohne Shell und Secret-Redaction. Bundle-, Signatur- und Profilaufbau sind aufwendiger (Spike S2). Neustart des Service nach Sparkle-Update braucht einen eigenen Handshake (Spike S3).

## Verifikation / Akzeptanz

Spikes S1–S3 aus der M0-Recherche; A01, A21, A28, A30.

## Verweise

- Pflichtenheft, Abschnitte C, D3, L3, Q2
- [ADR-0002](0002-native-apple-menuleiste-hintergrunddienst.md), [ADR-0009](0009-direktvertrieb-signierung-sandbox-prufung.md), [ADR-0017](0017-sparkle-updates.md), [ADR-0019](0019-persistenz-grdb-einzelner-schreiber.md)
- [ADR-Index](README.md)
