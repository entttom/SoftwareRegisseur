---
adr: 0021
title: "Agenten-Adapter: Codex über app-server, Claude Code headless über stream-json"
status: accepted
date: 2026-10-30
---

# ADR-0021: Agenten-Adapter: Codex über app-server, Claude Code headless über stream-json

**Status:** Accepted  
**Datum:** 2026-10-30  
**Entscheidungsträger:** Implementierung, auf Basis der Spikes [Codex](../integration-spikes/codex.md) und [Claude Code](../integration-spikes/claude-code.md); konkretisiert ADR-0005 und ADR-0006. Die mobile Weiterführung bleibt in ADR-0010 offen.

## Kontext

Beide Agenten bieten mehrere Startwege. Beide nehmen ungültige Modell-/Effort-Werte stillschweigend an oder stufen sie ab. Die Codex-Konfiguration des Benutzers kann gefährliche Standardwerte enthalten (`approval_policy="never"`, `danger-full-access`); geerbte Umgebungsvariablen können Claude-Code-Einstellungen überschreiben.

## Entscheidung

**Gemeinsam für alle Adapter**
- Start immer über `ProcessRunner` mit explizitem Executable, Argumentliste und bereinigter Umgebung; Arbeitsverzeichnis ist der von Software Regisseur angelegte Worktree. Eigene Worktree-Funktionen der Agenten werden nicht genutzt.
- Vor jedem Start Modell und Effort gegen den zur Laufzeit abgefragten Katalog prüfen; unzulässig → Job `needs_configuration` (ADR-0006, ADR-0012). Keine eingebauten Modelllisten.
- Sandbox-/Freigabemodus wird bei jedem Start explizit gesetzt, nie aus der Benutzerkonfiguration geerbt. Keine Bypass-Modi.
- Effektive Werte nur anzeigen, wenn der Agent sie meldet; sonst „nicht bestätigt“.

**Codex**
- `codex app-server` (JSON-RPC über stdio). Katalog über `model/list` (je Modell `supportedReasoningEfforts`, `defaultReasoningEffort`).
- `thread/start` mit `model`, `config.model_reasoning_effort`, `cwd`, `sandbox: "workspace-write"`, `approvalPolicy: "on-request"`; Freigaben laufen über das Protokoll zur App.
- Kontingent über `account/rateLimits/read` und Fehlercodes wie `usageLimitExceeded`. Niemals `account/rateLimitResetCredit/consume` aufrufen.
- Risiko: app-server ist laut OpenAI experimentell; die Protokollversion wird bei Erkennung geprüft. Fallback `codex exec --json` nur ohne interaktive Freigaben.

**Claude Code**
- Headless: `claude -p --input-format stream-json --output-format stream-json --verbose --session-id <job-uuid> --model <id> [--effort <stufe>] --permission-mode manual --permission-prompt-tool stdio`, `git push` per `--disallowedTools` gesperrt.
- Katalog über die SDK-`initialize`-Anfrage im stream-json-Kanal (`models[]` mit `supportsEffort`, `supportedEffortLevels`). Schlägt sie fehl, werden Jobs mit explizitem Modell blockiert statt auf eine Liste zurückzufallen.
- Effektives Modell aus `system/init.model`; effektive Effort-Stufe im Headless-Modus nicht bestätigbar.
- Umgebung ohne `CLAUDE_CODE_EFFORT_LEVEL`, `ANTHROPIC_BASE_URL` und API-Keys, damit Abo-Login und Remote Control greifen. Software Regisseur liest oder speichert nie claude.ai-Anmeldedaten (ADR-0014).

## Erwogene Alternativen

`codex exec` als Standard (keine Freigaben während des Laufs); Claude Agent SDK als eingebettete Bibliothek (Lizenzlage bei Abo-Login nur für Eigengebrauch geklärt, zusätzliche Node-Abhängigkeit); Effort über Prompt-Formulierung (von ADR-0006 verboten).

## Konsequenzen

Beide Adapter brauchen eigene Protokoll-Parser und Versionsprüfungen. Nicht dokumentierte bzw. experimentelle Teile (Codex app-server, Claude-SDK-Kontrollprotokoll über die CLI) werden bei jeder Agentenversion neu verifiziert und bei Abweichung als „nicht einsatzbereit“ markiert.

## Verifikation / Akzeptanz

Offene reale Tests O1–O7 (Codex) und T0–T9 (Claude Code) aus den Spike-Protokollen, sobald der Benutzer kontingentverbrauchende Läufe freigibt. A12–A14, A19, A20, A35–A42.

## Verweise

- Pflichtenheft, Abschnitte J, K2, L3
- [ADR-0005](0005-dynamische-coding-agenten-provider.md), [ADR-0006](0006-modell-und-effort-auswahl.md), [ADR-0010](0010-offizielle-mobile-agenten-sitzungen.md), [ADR-0014](0014-eigengebrauch-in-version-1.md)
- [ADR-Index](README.md)
