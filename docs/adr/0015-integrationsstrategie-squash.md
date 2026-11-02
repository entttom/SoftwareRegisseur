---
adr: 0015
title: "Squash-Merge als Standard-Integration, pro Projekt wählbar"
status: accepted
date: 2026-10-30
---

# ADR-0015: Squash-Merge als Standard-Integration, pro Projekt wählbar

**Status:** Accepted  
**Datum:** 2026-10-30  
**Entscheidungsträger:** Benutzer (Klärung offener Punkte vor M0).

## Kontext

ADR-0007 legt fest, dass Agentenergebnisse erst nach Review und Benutzerfreigabe integriert werden. Offen war, wie die Übernahme technisch erfolgt und wann eine Aufgabe als `done` gilt (Pflichtenheft M1 nannte „Merge/Cherry-pick/Apply“ ohne Standard).

## Entscheidung

- Standard-Integrationsstrategie ist **Squash-Merge** des Agenten-Branches in den Default-Branch des Projekts.
- Pro Projekt einstellbar (`ProjectSettings.integrationStrategy`): `squash`, `mergeCommit`, `cherryPick`.
- Eine Aufgabe wird erst `integrated` und nach Freigabe `done`, wenn die Änderung nachweislich im Default-Branch enthalten ist (Commit-Hash wird im `Review` gespeichert).
- Kein `git push` als Teil der Integration; Push bleibt eine eigene, ausdrücklich freizugebende Aktion.
- Nach erfolgreicher Integration wird der Worktree nur nach Bestätigung entfernt; der Agenten-Branch bleibt erhalten, bis der Benutzer ihn löscht.

## Erwogene Alternativen

Merge-Commit als Standard (unübersichtlichere Historie); nur Branch/PR ohne Integration durch Software Regisseur (kein nachprüfbares `done`).

## Konsequenzen

Saubere, lineare Historie pro Aufgabe. Einzelne Agenten-Commits sind im Default-Branch nicht mehr sichtbar, bleiben aber im Agenten-Branch erhalten. Integrationskonflikte müssen vor dem Squash im Worktree gelöst werden.

## Verifikation / Akzeptanz

Integrationstests auf temporären Repos für alle drei Strategien inkl. Konfliktfall; A22, A23, A30.

## Verweise

- Verbindliches Pflichtenheft, Abschnitte L2, M1, O
- [ADR-0007](0007-job-queue-locks-worktrees-review.md), [ADR-0012](0012-getrennte-status-zustandsmaschinen.md)
- [ADR-Index](README.md)
