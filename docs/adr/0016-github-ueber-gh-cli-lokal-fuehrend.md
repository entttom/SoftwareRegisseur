---
adr: 0016
title: "GitHub Issues über das gh-Login; lokale Request-Datei ist führend"
status: accepted
date: 2026-10-30
---

# ADR-0016: GitHub Issues über das gh-Login; lokale Request-Datei ist führend

**Status:** Accepted  
**Datum:** 2026-10-30  
**Entscheidungsträger:** Benutzer (Klärung offener Punkte vor M0).

## Kontext

Pflichtenheft M3 verlangt eine optionale GitHub-Issues-Integration mit sicherer Anmeldung, minimalen Rechten und klarer Konfliktregel, legt beides aber nicht fest.

## Entscheidung

- **Anmeldung:** Der Mac-Dienst nutzt das vorhandene Login der GitHub-CLI `gh` (Aufruf über `Process` mit expliziten Argumenten, ohne Shell). Software Regisseur speichert kein eigenes GitHub-Token, weder im Keychain noch in CloudKit.
- Ist `gh` nicht installiert oder nicht angemeldet, ist die Funktion pro Projekt deaktiviert und die UI erklärt, wie man sie einrichtet. Lokale Funktionen bleiben unberührt.
- Das iPhone greift nie direkt auf GitHub zu; Verknüpfungswünsche laufen als Auftrag über den Mac.
- **Konfliktregel:** Die lokale Request-Datei ist führend. Weicht GitHub seit dem letzten Abgleich ab, wird ein Konflikthinweis mit Diff und Übernahmemöglichkeit angezeigt; GitHub-Änderungen werden nicht still verworfen.
- Lokale UUID und GitHub-Issue-Nummer bleiben getrennte Identitäten (`GitHubIssueLink`).

## Erwogene Alternativen

Eigenes Fine-grained Token im Keychain (zusätzliche Token-Verwaltung); Konflikte immer manuell entscheiden (mehr Rückfragen).

## Konsequenzen

Keine eigene Token-Verwaltung und gleiche Rechte wie das `gh`-Login des Benutzers. Abhängigkeit von `gh`-Installation und dessen Ausgabeformat (`--json`); Version wird wie bei den Agenten erkannt und geprüft.

## Verifikation / Akzeptanz

Tests mit und ohne `gh`, Konfliktfall lokal vs. GitHub; A25, A27.

## Verweise

- Verbindliches Pflichtenheft, Abschnitt M3
- [ADR-Index](README.md)
