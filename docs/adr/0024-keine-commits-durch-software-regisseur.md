---
adr: 0024
title: "Software Regisseur committet Request- und ADR-Dateien nie selbst"
status: accepted
date: 2026-10-30
---

# ADR-0024: Software Regisseur committet Request- und ADR-Dateien nie selbst

**Status:** Accepted  
**Datum:** 2026-10-30  
**Entscheidungsträger:** Benutzer.

## Kontext

Der Mac-Dienst schreibt Request- und ADR-Dateien in die Repositories und verschiebt sie bei Statuswechseln. Das Pflichtenheft verbietet heimliches Committen. Agenten arbeiten in Worktrees, die vom letzten Commit abzweigen, und die Übernahme (ADR-0015) verlangt bisher einen sauberen Haupt-Working-Tree.

## Entscheidung

- Software Regisseur erstellt **keine Commits** für Request-, ADR- oder Anweisungsdateien. Der Benutzer committet sie selbst.
- Agenten erhalten den Auftrag vollständig über den Prompt. Sie dürfen Request-Dateien weder anlegen noch ändern oder verschieben; der Status wird ausschließlich vom Mac-Dienst im Haupt-Working-Tree gepflegt. Der verwaltete AGENTS.md-Block und der Agenten-Prompt sagen das ausdrücklich.
- Die Übernahme ignoriert beim Sauberkeits-Check nicht committete Änderungen **unterhalb der konfigurierten Dokumentpfade** (ADR-Ordner, Requests-Wurzel) des Projekts. Andere Änderungen blockieren weiterhin.
- Würde die Übernahme Dateien unterhalb dieser Pfade verändern, die im Haupt-Working-Tree nicht committet sind, bricht sie sauber ab und meldet die betroffenen Dateien, statt sie zu überschreiben.
- Ausgenommen sind Commits, die zur Übernahme selbst gehören (ADR-0015), und Commits des Agenten auf seinem eigenen Job-Branch.

## Erwogene Alternativen

Sichtbarer Auto-Commit der eigenen Dokumentdateien; Commit jeweils nach Rückfrage.

## Konsequenzen

Keine Commits ohne Benutzerhandlung in den Dokumentpfaden. Neue Requests sind für Agenten nur über den Prompt sichtbar, nicht als Datei im Worktree. Die Git-Historie der Request-Dateien hängt davon ab, wann der Benutzer committet.

## Verifikation / Akzeptanz

Integrationstests: Übernahme mit nicht committeten Request-Dateien gelingt; Übernahme, die solche Dateien überschreiben würde, bricht ohne Teilzustand ab; Prompt und Managed Block enthalten das Verbot. A22, A23, A30.

## Verweise

- [Pflichtenheft](../../Software_Regisseur_1.0_Codex_Entwicklungsauftrag.md), Abschnitte A.4, G, L2, M1
- [ADR-0004](0004-konfigurierbare-verzeichnisse-und-agentenanweisungen.md), [ADR-0015](0015-integrationsstrategie-squash.md)
- [ADR-Index](README.md)
