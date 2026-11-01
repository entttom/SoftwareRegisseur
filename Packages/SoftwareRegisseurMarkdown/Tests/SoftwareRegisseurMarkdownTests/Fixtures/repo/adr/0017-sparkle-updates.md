---
adr: 0017
title: "Mac-Updates über Sparkle mit EdDSA-Signatur"
status: accepted
date: 2026-10-30
---

# ADR-0017: Mac-Updates über Sparkle mit EdDSA-Signatur

**Status:** Accepted  
**Datum:** 2026-10-30  
**Entscheidungsträger:** Benutzer (Klärung offener Punkte vor M0).

## Kontext

Pflichtenheft Q3 erlaubt automatische Updates nur, wenn sie signiert, sicher und nachprüfbar sind. Die Mac-App wird außerhalb des Mac App Stores verteilt (ADR-0009).

## Entscheidung

- Updates der Mac-App über das Framework **Sparkle** (Swift Package).
- Appcast nur über HTTPS; jedes Update-Paket mit EdDSA signiert und zusätzlich Developer-ID-signiert, notarisiert und gestapelt.
- Der private EdDSA-Schlüssel liegt nur im Keychain des Release-Macs, nie im Repository oder in CI-Logs.
- App, eingebetteter Agent Service und Login Item werden gemeinsam aktualisiert; laufende Agentenjobs werden vor dem Neustart sauber pausiert bzw. nach dem Update per Recovery fortgeführt (ADR-0007).
- **Speicherort:** Appcast und Update-Pakete liegen in **GitHub Releases eines öffentlichen Repositorys**. Soll der Quellcode privat bleiben, wird dafür ein eigenes öffentliches Release-Repository ohne Quellcode verwendet. Das Repository ist vor dem ersten Release anzulegen (Stand 30.10.2026: noch kein Remote vorhanden).
- Appcast-URL und öffentlicher EdDSA-Schlüssel kommen über Build-Variablen (`SR_SPARKLE_FEED_URL`, `SR_SPARKLE_PUBLIC_ED_KEY`) aus `Config/Local.xcconfig` (ADR-0013).

## Erwogene Alternativen

Nur manuelle Updates per DMG (kein Update-Server, aber mehr Handarbeit).

## Konsequenzen

Bequeme, geprüfte Updates ohne eigenen Server. Zusätzliche Abhängigkeit (Sparkle) und ein zu sichernder Signaturschlüssel. Die Release-Pakete sind öffentlich herunterladbar; das widerspricht ADR-0014 nicht, solange kein aktiver Vertrieb an Dritte erfolgt.

## Verifikation / Akzeptanz

Release-Skript erzeugt signierten Appcast; Test: Update von Version n auf n+1 auf einem sauberen Mac, manipuliertes Paket wird abgelehnt; laufender Job übersteht das Update. A21, A28.

## Verweise

- [Verbindliches Pflichtenheft](../../Software_Regisseur_1.0_Codex_Entwicklungsauftrag.md), Abschnitt Q3
- [ADR-0007](0007-job-queue-locks-worktrees-review.md), [ADR-0009](0009-direktvertrieb-signierung-sandbox-prufung.md)
- [ADR-Index](README.md)
