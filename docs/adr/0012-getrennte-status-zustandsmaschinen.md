---
adr: 0012
title: "Getrennte Zustandsmaschinen für Projekt, Aufgabe und Agentenjob"
status: accepted
date: 2026-10-30
---

# ADR-0012: Getrennte Zustandsmaschinen für Projekt, Aufgabe und Agentenjob

**Status:** Accepted  
**Datum:** 2026-10-30  
**Entscheidungsträger:** Benutzer (Klärung offener Punkte vor M0).

## Kontext

Das Pflichtenheft nennt Statuswerte an mehreren Stellen: die Aufgabenkette in F5, Projektstatus in E2, sowie `needs_configuration` (J2a), `waiting_quota` (K2) und `pendingMac` (N3). Diese Werte sind nicht einer Entität zugeordnet. Ohne klare Trennung würden Aufgabe und Agentenlauf vermischt: Eine Aufgabe kann mehrere Jobs haben (Retry, neuer Lauf nach Review), und laufbezogene Wartezustände sind keine fachliche Aussage über die Aufgabe.

## Entscheidung

Drei getrennte, versionierte Zustandsmaschinen im Domain-Package:

**Project** – `pendingMacSetup`, `ready`, `unavailable`, `needsAttention`, `archived`.

**WorkItem** (im Frontmatter `status` und im Sync-Index) –
`inbox → open → queued → scheduled → in_progress → waiting_approval → implementation_finished → review → integrated → done`, zusätzlich `blocked`, `failed`, `cancelled`, `paused`.

**AgentJob** (nur Sync-Index/Datenbank, nicht im Markdown-Frontmatter) –
`requested → pendingMac → scheduled → admitted → starting → running → finished`, zusätzlich `needs_configuration`, `waiting_approval`, `waiting_quota`, `paused`, `failed`, `cancelled`.

- `requested`: vom iPhone oder Mac erzeugter Jobwunsch mit idempotenter UUID.
- `pendingMac`: Ausführungshost hat den Wunsch noch nicht übernommen.
- `scheduled`: vom Host übernommen, wartet auf Startzeit, Sperrfrist oder Parallelitätslimit.
- `admitted`: Host hat Projekt, Aufgabe, Lock und Modell-/Effort-Snapshot validiert.
- `starting` / `running`: Worktree vorbereitet bzw. Agentenprozess läuft.
- `finished`: Agentenprozess sauber beendet, Ergebnis erfasst.

Während eines aktiven Jobs wird der Aufgabenstatus **ausschließlich vom Mac-Host** aus dem Jobstatus abgeleitet:

| AgentJob | WorkItem |
|---|---|
| `requested`, `pendingMac` | `queued` |
| `scheduled`, `waiting_quota` | `scheduled` |
| `admitted`, `starting`, `running` | `in_progress` |
| `waiting_approval` | `waiting_approval` |
| `needs_configuration` | `blocked` |
| `paused` | `paused` |
| `finished` | `implementation_finished`, nach Erfassung von Diff/Tests `review` |
| `failed` | `failed` |
| `cancelled` | zurück auf den Status vor dem Job (in der Regel `open`) |

`integrated` und `done` entstehen nie aus einem Jobstatus, sondern nur durch Übernahme und Benutzerfreigabe (ADR-0007). Manuelle Statusänderungen an einer Aufgabe mit aktivem Job werden abgelehnt oder als Konflikt angezeigt, nicht still überschrieben.

## Erwogene Alternativen

Ein gemeinsamer Status auf der Aufgabe für alle Zustände: einfacher, aber Aufgabe und Lauf sind nicht unterscheidbar, mehrere Jobs pro Aufgabe nicht abbildbar, und Wartezustände eines Laufs würden ins Markdown-Frontmatter geschrieben.

## Konsequenzen

Klare Verantwortung (Mac ist maßgeblich für Jobzustände, N2), saubere Historie pro Lauf und weniger Git-Änderungen an Request-Dateien. Dafür zusätzliche Ableitungslogik, die mit Tests abgesichert werden muss. iPhone-UI zeigt Aufgaben- und Jobstatus getrennt an (z. B. „Geplant – wartet auf Kontingent“).

## Verifikation / Akzeptanz

Unit-Tests für alle erlaubten und verbotenen Übergänge jeder Zustandsmaschine und für die Abbildungstabelle. A13–A23, A39, A40.

## Verweise

- Verbindliches Pflichtenheft, Abschnitte E2, F5, J2a, K2, N3, O
- [ADR-0006](0006-modell-und-effort-auswahl.md), [ADR-0007](0007-job-queue-locks-worktrees-review.md)
- [ADR-Index](README.md)
