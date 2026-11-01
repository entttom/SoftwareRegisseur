# End-to-End-Testplan Software Regisseur 1.0 (A01–A42)

**Stand:** 2026-10-30. Gehört zur [Abnahmematrix](abnahmematrix.md). Szenarien und Muss-Ergebnisse: [Pflichtenheft, Abschnitt R](../../Software_Regisseur_1.0_Codex_Entwicklungsauftrag.md).

Dieser Plan beschreibt die **realen** Nachweise, die automatisierte Tests nicht ersetzen können. Er wird gemeinsam abgearbeitet:

- **Benutzer:** bedient iPhone, iPad und Mac, meldet sich bei Diensten an, bestätigt Systemabfragen, gibt Kontingent frei.
- **Implementierer-Sitzung** (Entwickler oder Coding-Agent am Mac): führt Prüfbefehle aus (Logs, DB, Git), sammelt Belege und trägt die Ergebnisse in die Matrix ein.

Eine Zeile wird nur mit abgelegtem Beleg auf `passed` oder `failed` gesetzt (AGENTS.md Regel 10).

## 0. Kennzeichnungen

| Marke | Bedeutung |
|---|---|
| **[KONTINGENT Codex]** / **[KONTINGENT Claude]** | Verbraucht Abo-Kontingent des jeweiligen Agenten. Nur nach ausdrücklicher Freigabe durch den Benutzer und immer mit dem **Minimalauftrag** (Abschnitt 2.6). |
| **[API-KOSTEN]** | Echter Aufruf mit eigenem API-Schlüssel (OpenAI/Anthropic/Gemini), wird pro Token oder Audiominute abgerechnet (Cent-Bereich). |
| **[EXTERN SICHTBAR]** | Erzeugt etwas außerhalb dieses Macs, z. B. ein GitHub-Repo oder Issues. Führt nur der Benutzer aus. |
| **[SYSTEMÄNDERUNG]** | Ändert die Installation auf dem Mac (De-/Neuinstallation, Upgrade, Abmelden). Reversibel, aber nur durch den Benutzer. |
| **[DESTRUKTIV]** | Löscht Daten (lokal oder iCloud). Erst ganz am Ende der Kampagne (Session 5). |

Alles ohne Marke kostet nichts und ändert nichts außerhalb des Testordners.

## 1. Gemeinsame Voraussetzungen

| # | Voraussetzung | Prüfung (Implementierer-Sitzung) |
|---|---|---|
| V1 | Mac-App **signiert** mit echtem Team (`Config/Local.xcconfig`, ADR-0013) und nach `/Applications/SoftwareRegisseur.app` kopiert. Sessions 1–4: Apple-Development-Signatur. Session 5: Developer-ID-Release. | `codesign -dv --verbose=2 /Applications/SoftwareRegisseur.app 2>&1 \| grep -E 'Authority\|TeamIdentifier'` |
| V2 | LaunchAgent registriert und freigegeben (SMAppService). Der Benutzer bestätigt das in Systemeinstellungen › Allgemein › Anmeldeobjekte. | `launchctl print gui/$(id -u)/<SR_BUNDLE_ID_PREFIX>.SoftwareRegisseur.Mac.AgentService \| grep -E 'state\|pid'` |
| V3 | iPhone **und** iPad mit derselben Apple-ID, iCloud Drive an, Entwickler-Build (Xcode) bzw. TestFlight installiert. | In der App: Einstellungen zeigen iCloud verfügbar. |
| V4 | **Gleiche CloudKit-Umgebung auf allen Geräten.** Xcode-Entwicklungsbuilds nutzen „Development“, Developer-ID- und TestFlight-Builds „Production“. Mischbetrieb synchronisiert nicht. Vor Session 5 muss der Benutzer das Schema in der CloudKit-Console nach Production deployen. | Abgleich der Signatur von Mac (V1) und iOS-Build. |
| V5 | Claude Code installiert und **angemeldet mit dem Max-Abo**. Laut Spike war die Anmeldung am 2026-10-30 abgelaufen: Der Benutzer führt `claude auth login` selbst aus. | `claude --version`, `claude auth status --text` |
| V6 | Codex installiert und angemeldet (ChatGPT-Konto). | `codex --version`, `codex login status` |
| V7 | `gh` angemeldet (nur für A25). | `gh auth status` |
| V8 | Wegwerf-Testordner angelegt (Abschnitt 2.1). Echte Repos werden in Software Regisseur **nicht** als Stammordner gewählt. | `ls ~/Developer/SR-Testprojekte` |
| V9 | Terminal darf auf „Daten anderer Apps“ zugreifen. macOS fragt beim ersten Lesen des Group Containers, der Benutzer bestätigt. | Abschnitt 2.3 |
| V10 | Automatisierte Tests einmal vollständig gelaufen, Protokoll abgelegt (Basis der „Teilbelege“). | `Scripts/test.sh 2>&1 \| tee docs/acceptance/belege/testlauf-$(date +%F).log` |

**Agentenversionen notieren:** Am Anfang jeder Session `claude --version` und `codex --version` in `docs/acceptance/belege/versionen-<datum>.txt` festhalten. Claude Code wurde am 30.10.2026 vom Benutzer bereits von `2.1.212` auf `2.1.308` aktualisiert (vor jeder E2E-Session). A40 wird deshalb mit dem nächsten verfügbaren Agenten-Update (Claude Code oder Codex) durchgeführt.

## 2. Hilfsmittel

### 2.1 Wegwerf-Testrepositories anlegen

Das Skript schreibt **nur** in `~/Developer/SR-Testprojekte` und `~/Developer/SR-Testprojekte.remotes`. Existiert einer der Ordner bereits, bricht es ab, statt etwas zu überschreiben. Es löscht nichts, pusht nur in die eigenen lokalen Bare-Remotes und verwendet eine eigene Commit-Identität. Die globale Git-Konfiguration bleibt unverändert.

Ablage zum Ausführen: z. B. `~/Developer/sr-abnahme-setup.sh`, dann `bash ~/Developer/sr-abnahme-setup.sh`.

```bash
#!/bin/bash
# SR-Abnahme: Wegwerf-Testrepos anlegen. Schreibt ausschließlich unter $SR_TEST_ROOT und $SR_TEST_ROOT.remotes.
set -euo pipefail

SR_TEST_ROOT="${SR_TEST_ROOT:-$HOME/Developer/SR-Testprojekte}"
REMOTES="${SR_TEST_ROOT}.remotes"

case "$(basename "$SR_TEST_ROOT")" in
  SR-Testprojekte*) ;;
  *) echo "Abbruch: Der Ordnername muss mit 'SR-Testprojekte' beginnen." >&2; exit 1 ;;
esac
for d in "$SR_TEST_ROOT" "$REMOTES"; do
  if [ -e "$d" ]; then
    echo "Abbruch: $d existiert bereits. Es wird nichts überschrieben." >&2
    echo "Anderen Namen wählen, z. B.: SR_TEST_ROOT=~/Developer/SR-Testprojekte-2 bash $0" >&2
    exit 1
  fi
done

# Eigene Identität, keine Signatur-Abfragen, unabhängig von ~/.gitconfig-Defaults.
g() { git -c user.name="SR Abnahme" -c user.email="sr-abnahme@example.invalid" \
          -c commit.gpgsign=false -c tag.gpgsign=false -c init.defaultBranch=main "$@"; }

mkdir -p "$SR_TEST_ROOT/gruppe" "$REMOTES"
printf 'Wegwerf-Testordner für die Software-Regisseur-Abnahme. Darf gelöscht werden.\n' \
  > "$SR_TEST_ROOT/.sr-abnahme-testroot"

# gamma-lib: Quelle für ein Submodul (A02: Submodul darf kein eigenes Doppelprojekt werden)
mkdir "$SR_TEST_ROOT/gamma-lib" && cd "$SR_TEST_ROOT/gamma-lib"
g init -q
printf '# gamma-lib\n' > README.md
g add -A && g commit -qm "gamma: Start"

# alpha-app: bestehende AGENTS.md/CLAUDE.md/ADRs (A06), Dummy-Secret (A11/A27), Submodul,
# Worktree (A02) und lokales Bare-Remote (A30)
mkdir "$SR_TEST_ROOT/alpha-app" && cd "$SR_TEST_ROOT/alpha-app"
g init -q
mkdir -p docs/adr src
cat > AGENTS.md <<'EOF'
# Eigene Regeln (alpha-app)

- SR-ABNAHME-MARKER-AGENTS: Diese Zeile darf Software Regisseur nie verändern.
- Tests mit `make test` ausführen.
EOF
cat > CLAUDE.md <<'EOF'
# Claude-Hinweise (alpha-app)

SR-ABNAHME-MARKER-CLAUDE: Eigene Claude-Regel, bitte unverändert lassen.
EOF
cat > docs/adr/0001-datenbank.md <<'EOF'
---
adr: 0001
title: "SQLite als Datenbank"
status: accepted
date: 2026-10-01
---

# ADR-0001: SQLite als Datenbank

## Kontext
Testinhalt für den Import.

## Entscheidung
SQLite.
EOF
cat > docs/adr/0002-logging.md <<'EOF'
# 2. Logging über os.Logger

Status: proposed

## Context
MADR-Variante ohne Frontmatter (Import-Test).
EOF
printf 'print("alpha")\n' > src/main.py
printf '.env\n' > .gitignore
# Erkennbar falscher Schlüssel – nur für den Secrets-Filter (A11). Wird per .gitignore nie committet.
printf 'OPENAI_API_KEY=sk-DUMMY-NICHT-ECHT-000000000000000000000000\n' > .env
g add -A && g commit -qm "alpha: Start"
g -c protocol.file.allow=always submodule add -q "$SR_TEST_ROOT/gamma-lib" lib/gamma
g commit -qm "alpha: Submodul gamma"
g clone -q --bare . "$REMOTES/alpha-app.git"
g remote add origin "$REMOTES/alpha-app.git"
g fetch -q origin
g branch -q --set-upstream-to=origin/main main
g worktree add -q -b feature/wt "$SR_TEST_ROOT/alpha-app-wt"

# beta-service: Repo ohne AGENTS.md (Software Regisseur soll nur einen Vorschlag machen)
mkdir "$SR_TEST_ROOT/beta-service" && cd "$SR_TEST_ROOT/beta-service"
g init -q
printf '# beta-service\n' > README.md
g add -A && g commit -qm "beta: Start"
g clone -q --bare . "$REMOTES/beta-service.git"
g remote add origin "$REMOTES/beta-service.git"
g fetch -q origin
g branch -q --set-upstream-to=origin/main main

# gruppe/epsilon-repo: verschachteltes Repo (rekursive Indizierung)
mkdir "$SR_TEST_ROOT/gruppe/epsilon-repo" && cd "$SR_TEST_ROOT/gruppe/epsilon-repo"
g init -q
printf '# epsilon\n' > README.md
g add -A && g commit -qm "epsilon: Start"

# delta-ordner: normaler Ordner ohne Git (A03: Projekt am iPhone, optional "git init")
mkdir "$SR_TEST_ROOT/delta-ordner"
printf '# delta – noch kein Git\n' > "$SR_TEST_ROOT/delta-ordner/README.md"

echo "Fertig. Testordner: $SR_TEST_ROOT"
git -C "$SR_TEST_ROOT/alpha-app" worktree list
```

Erwartete Struktur: 4 echte Repos (`alpha-app`, `beta-service`, `gamma-lib`, `gruppe/epsilon-repo`), 1 Worktree (`alpha-app-wt`, gehört zu `alpha-app`), 1 Submodul (`alpha-app/lib/gamma`), 1 normaler Ordner (`delta-ordner`).

### 2.2 Git-Schnappschuss (A30 und Kontrolle nach jeder Session)

```bash
SR_TEST_ROOT="$HOME/Developer/SR-Testprojekte"
sr_git_snapshot() {   # Aufruf: sr_git_snapshot docs/acceptance/belege/A30/<datum>_<phase>.txt
  {
    for repo in "$SR_TEST_ROOT"/*/ "$SR_TEST_ROOT"/gruppe/*/; do
      [ -e "$repo/.git" ] || continue
      echo "### $repo"
      git -C "$repo" for-each-ref --format='%(refname) %(objectname)'
      git -C "$repo" worktree list --porcelain
      git -C "$repo" stash list
      git -C "$repo" status --porcelain=v1
      git -C "$repo" reflog --date=iso -n 30 | grep -E 'reset:|rebase|checkout: moving|branch: deleted' || true
    done
    for bare in "$SR_TEST_ROOT.remotes"/*.git; do
      echo "### REMOTE $bare"
      git -C "$bare" for-each-ref --format='%(refname) %(objectname)'
    done
  } > "$1"
}
```

### 2.3 Datenbank lesen (nur lesend)

Der Dienst ist der einzige Schreiber (ADR-0019). Die Implementierer-Sitzung öffnet die Datenbank nur mit `-readonly`.

```bash
SR_GROUP="$(ls -d "$HOME/Library/Group Containers/"*.<SR_BUNDLE_ID_PREFIX>.SoftwareRegisseur 2>/dev/null | head -1)"
SR_DB="$SR_GROUP/SoftwareRegisseur/Database/SoftwareRegisseur.sqlite"
SR_WT="$SR_GROUP/SoftwareRegisseur/Worktrees"
srsql() { sqlite3 -readonly -header -column "$SR_DB" "$@"; }
# Zeitstempel sind REAL-Sekunden seit 2001-01-01 → Umrechnung:
# datetime(<spalte> + 978307200, 'unixepoch', 'localtime')
```

Häufige Abfragen:

```sql
-- Jobs (A13–A23, A38–A41)
SELECT substr(job_id,1,8) job, provider_id, state, requested_model_id, requested_effort,
       resolved_model_id, resolved_effort, effective_model_id, effective_effort,
       capability_revision, branch, retry_of_job_id,
       datetime(scheduled_at+978307200,'unixepoch','localtime') geplant,
       datetime(started_at+978307200,'unixepoch','localtime') gestartet
FROM agent_jobs ORDER BY created_at DESC LIMIT 10;

-- Konfigurations-Snapshot eines Jobs (A39)
SELECT config_snapshot FROM agent_jobs WHERE job_id LIKE '<präfix>%';

-- Locks (A13, A15, A16, A21)
SELECT substr(task_id,1,8) task, substr(job_id,1,8) job, scope, recovery_state, release_reason,
       datetime(lease_until+978307200,'unixepoch','localtime') lease
FROM task_locks ORDER BY acquired_at DESC LIMIT 10;

-- Aufgaben (A03, A04, A10, A22, A23)
SELECT w.human_id, w.status, w.review_state, t.title
FROM work_items w JOIN work_item_texts t ON t.work_item_id = w.uuid
ORDER BY w.updated_at DESC LIMIT 15;

-- Verlauf einer Aufgabe (M2)
SELECT kind, actor, datetime(timestamp+978307200,'unixepoch','localtime') zeit, substr(payload,1,160) payload
FROM task_events WHERE work_item_id = '<uuid>' ORDER BY timestamp;

-- Agenten und Katalog (A12, A35–A37, A40)
SELECT provider_id, version, installed, authenticated, runnable, supports_remote, capability_revision,
       datetime(last_checked+978307200,'unixepoch','localtime') geprueft FROM agent_capabilities;
SELECT provider_id, position, model_id, supported_effort_ids, default_effort_id, availability
FROM agent_model_capabilities ORDER BY provider_id, position;
SELECT scope_key, provider_id, model_selection, model_id, effort, inherits_default FROM agent_model_preferences;

-- Freigaben (A20)
SELECT substr(id,1,8) id, substr(job_id,1,8) job, state,
       datetime(requested_at+978307200,'unixepoch','localtime') angefragt FROM pending_approvals ORDER BY requested_at DESC LIMIT 10;
SELECT substr(approval_id,1,8) approval, decision, decided_by,
       datetime(decided_at+978307200,'unixepoch','localtime') entschieden FROM approval_decisions ORDER BY decided_at DESC LIMIT 10;

-- Sync und Konflikte (A10, A24, A26)
SELECT state, count(*) FROM sync_outbox GROUP BY state;
SELECT entity_type, substr(entity_id,1,8) entity, remote_change_kind,
       datetime(detected_at+978307200,'unixepoch','localtime') erkannt, resolution FROM sync_conflicts ORDER BY detected_at DESC LIMIT 10;
SELECT kind, substr(work_item_id,1,8) item, datetime(detected_at+978307200,'unixepoch','localtime') erkannt, resolved_at FROM file_conflicts;
```

Suche nach Geheimnissen in der Datenbank (A27). Erwartet: **keine** Ausgabe.

```bash
sqlite3 -readonly "$SR_DB" .dump | grep -nE 'sk-[A-Za-z0-9_-]{20,}|sk-ant-[A-Za-z0-9_-]{10,}|AIza[0-9A-Za-z_-]{30,}|gh[pousr]_[A-Za-z0-9]{30,}' | cut -c1-80
```

### 2.4 Logs

Der Agent Service protokolliert unter seiner Bundle-ID (`ServiceLog.subsystem = Bundle.main.bundleIdentifier`, also **`<SR_BUNDLE_ID_PREFIX>.SoftwareRegisseur.Mac.AgentService`**). Kategorien: `lifecycle`, `jobs`, `sync`, `workspace`, `agents`, `ai`, `ipc`, `power`. Der Updater der Mac-UI protokolliert unter dem Subsystem `SoftwareRegisseur` (Kategorie `Update`). Ein Subsystem `<SR_BUNDLE_ID_PREFIX>.SoftwareRegisseur` gibt es nicht.

```bash
# Rückblick
log show --last 30m --info --debug \
  --predicate 'subsystem == "<SR_BUNDLE_ID_PREFIX>.SoftwareRegisseur.Mac.AgentService"' > /tmp/sr-log.txt
# nur Jobs
log show --last 30m --info \
  --predicate 'subsystem == "<SR_BUNDLE_ID_PREFIX>.SoftwareRegisseur.Mac.AgentService" AND category == "jobs"'
# live mitlesen
log stream --info --predicate 'subsystem == "<SR_BUNDLE_ID_PREFIX>.SoftwareRegisseur.Mac.AgentService"'
# Updater (Session 5)
log show --last 1h --info --predicate 'subsystem == "SoftwareRegisseur" AND category == "Update"'
```

Pfade, Befehle und Fehlertexte stehen mit `privacy: .private` im Log und erscheinen als `<private>`. Das ist erwünscht (Q1) und gehört zum Beleg für A27.

Vor dem Ablegen jedes Log-Auszugs die Geheimnis-Suche aus 2.3 auf die Logdatei anwenden.

### 2.5 Belege ablegen

- Ordner: `docs/acceptance/belege/<A-ID>/`. Dateinamen: `<JJJJ-MM-TT>_<kurz>.<png|txt|mov>`.
- iPhone/iPad: Bildschirmfotos bzw. Bildschirmaufnahme. Mac: `screencapture -i <datei>.png`.
- Persönliche Daten vor dem Einchecken schwärzen: E-Mail-Adressen, Account-IDs, echte Schlüsselfragmente.
- In der Matrix unter „Beleg“ den Pfad nennen, unter „Datum“ das Prüfdatum.

### 2.6 Minimalauftrag (für alle Läufe mit Kontingent)

Aufgabe im Testrepo (Titel und Text so übernehmen, `<agent>` ersetzen):

> **Titel:** Hallo-Datei anlegen (Abnahme)
> **Text:** Lege die Datei `abnahme/hello-<agent>.txt` mit genau dem Inhalt `hello` an. Ändere keine anderen Dateien, führe keine Befehle aus, installiere nichts.

- **Modell:** das kleinste im Katalog angebotene Modell (laut Spike z. B. `sonnet` bei Claude). **Effort:** `low` bzw. die niedrigste angebotene Stufe.
- Claude läuft im Modus `--permission-mode manual` (ADR-0021). Deshalb löst schon das Anlegen der Datei eine Freigabe aus, die am iPhone oder Mac zu erteilen ist. Das gehört zum Test (A20).
- Erwartete Kosten je Lauf: ein Turn, wenige tausend Token.

### 2.7 Kontingentübersicht

| Session | Codex-Läufe | Claude-Läufe | API-Kosten (BYOK) |
|---|---|---|---|
| 1 Mac | 0 | 0 | 0 |
| 2 iPhone/iCloud | 0 | 0 | ca. 6 kleine Aufrufe (A08, A09 ×3, A11, A27) |
| 3 Agenten | ca. 6 (Spikes O1, O3, O5 + A13, A16, A21, A39, A17) | ca. 6 (Spikes T1, T2 + A14, A15, A21, A20-Ablehnung) | 0 |
| 4 Mobil-Spikes | ca. 2 (O6) | ca. 3 (T3, T5, T6) | 0 |
| 5 Release | 0–1 (A33) | 0 | 0 |

Vor jeder Session gibt der Benutzer das Kontingent ausdrücklich frei. Die Zahlen sind Obergrenzen; wiederverwendbare Läufe werden nicht wiederholt.

---

## Session 1 – nur Mac, kein Kontingent

**Dauer:** ca. 2 h. **Vorbedingungen:** V1, V2, V5, V6, V8, V9, V10. Basis-Schnappschuss nach 2.2: `sr_git_snapshot docs/acceptance/belege/A30/<datum>_0-basis.txt`.

### A01 – Mac-App startet nach Login ohne Hauptfenster
1. Benutzer: Software Regisseur aus `/Applications` starten (nicht aus Xcode: sonst gehört die Registrierung zur Kopie im Build-Ordner). Den LaunchAgent in Systemeinstellungen › Anmeldeobjekte erlauben. In der App unter Einstellungen › Dienst › Anmeldung „Menüleisten-App beim Anmelden öffnen“ prüfen (nach der Einrichtung beim ersten Start bereits eingeschaltet, sonst einschalten).
2. Benutzer: abmelden und wieder anmelden (in Session 5 zusätzlich Neustart auf frischem System).
3. Implementierer: `launchctl print gui/$(id -u)/<SR_BUNDLE_ID_PREFIX>.SoftwareRegisseur.Mac.AgentService | grep -E 'state|pid|last exit'` und `pgrep -lf SoftwareRegisseur`.
4. Benutzer: Menüsymbol anklicken, „Dienst prüfen“, dann „Einstellungen“ öffnen.

**Erwartet:** Menüsymbol vorhanden, **kein** Hauptfenster und kein Dock-Symbol. Der Dienst läuft (`state = running`), die Statusanzeige ist nur nach echter Antwort grün. Einstellungen öffnen sich.
**Belege:** Screenshot der Menüleiste direkt nach dem Login, `launchctl`-Auszug, Log `category == "lifecycle"` seit dem Login.

### A02 – Git-Stammordner mit mehreren Repos
1. Benutzer: im Hauptfenster `~/Developer/SR-Testprojekte` als Stammordner wählen.
2. Während des Scans Fenster verschieben, zwischen Bereichen wechseln (Bildschirmaufnahme).
3. Implementierer: `srsql "SELECT p.name, p.repository_kind, p.status, r.canonical_path FROM projects p JOIN repository_locations r ON r.project_id = p.id;"`.

**Erwartet:** genau 4 Projekte (`alpha-app`, `beta-service`, `gamma-lib`, `epsilon-repo`). `alpha-app-wt` erscheint als Worktree von `alpha-app`, nicht als eigenes Projekt. `lib/gamma` ist kein Doppelprojekt. `delta-ordner` wird als Ordner angeboten. Die UI bleibt bedienbar.
**Belege:** Screenshot der Projektliste, DB-Abfrage, Bildschirmaufnahme.

### A06 – Import bestehender AGENTS.md/CLAUDE.md/ADRs (vor A05 ausführen)
1. Implementierer: `shasum alpha-app/AGENTS.md alpha-app/CLAUDE.md alpha-app/docs/adr/*` vorher festhalten.
2. Benutzer: Projekt `alpha-app` öffnen, ADR-Liste und Anweisungsstatus ansehen. Den angebotenen Vorschlag für den verwalteten Block zuerst **nicht** übernehmen.
3. Implementierer: Prüfsummen erneut vergleichen. Erwartet: unverändert.
4. Benutzer: Vorschlag ansehen (Diff) und übernehmen.
5. Implementierer: `git -C ~/Developer/SR-Testprojekte/alpha-app diff`.

**Erwartet:** ADR 0001 als `accepted` mit Nummer 1 importiert. ADR 0002 (MADR ohne Frontmatter) erkannt oder klar als inkompatibel markiert, nie verändert. Ohne Freigabe keine Dateiänderung. Mit Freigabe nur ein angehängter Block bzw. `@AGENTS.md`-Import in CLAUDE.md. Die Zeilen `SR-ABNAHME-MARKER-*` bleiben unverändert. **Kein Commit** durch Software Regisseur (ADR-0024).
**Belege:** Prüfsummen vorher/nachher, `git diff`, `git log --oneline -3`, Screenshot der ADR-Liste.

### A05 – Pfadwechsel `docs/requests` → anderer Pfad
1. Benutzer: in `beta-service` drei Aufgaben am Mac anlegen und auf unterschiedliche Status setzen (offen, in Arbeit, Review), damit Dateien entstehen.
2. Benutzer: in den Projekteinstellungen Requests-Wurzel und Statusordner auf `aufgaben/offen`, `aufgaben/in-arbeit`, `aufgaben/pruefung`, `aufgaben/erledigt` ändern.
3. Vorschau prüfen. Für eine Kollision vorher von Hand `aufgaben/offen/<gleicher-dateiname>.md` anlegen.
4. Migration anwenden. Implementierer: `git -C …/beta-service status --porcelain` und `git diff AGENTS.md`.

**Erwartet:** Die Vorschau listet jede Verschiebung und die Kollision, nichts wird überschrieben. Nur geplante Dateien werden verschoben. Der verwaltete AGENTS.md-Block nennt die neuen Pfade, Text außerhalb der Marker bleibt gleich.
**Belege:** Screenshot der Vorschau, `git status`, Diff von AGENTS.md.

### A04 (Mac-Teil) – extern geänderter Request
1. Benutzer: in `beta-service` eine Request-Datei im Texteditor öffnen. Einen eigenen Abschnitt `## Notiz von Hand` ergänzen und im Frontmatter `priority: high` setzen. Speichern.
2. Implementierer: `log show --last 5m --info --predicate 'subsystem == "<SR_BUNDLE_ID_PREFIX>.SoftwareRegisseur.Mac.AgentService" AND category == "workspace"'` und die Aufgabe per `srsql` abfragen.
3. Benutzer: in der Mac-UI den Status ändern. Implementierer: `git diff` der Datei.

**Erwartet:** Die Mac-UI zeigt die Änderung innerhalb weniger Sekunden. Beim Statuswechsel ändern sich nur `status`/`updatedAt` und der Ordner, der Handabschnitt bleibt byte-genau erhalten. (iPhone-Teil in Session 2.)
**Belege:** Log-Auszug, `git diff`, Screenshot.

### A35 / A36 / A37 (Mac-Teil) – Modellkataloge
1. Implementierer, ohne Kontingent: `cd Packages/SoftwareRegisseurAgents && SR_REAL_AGENT_TESTS=1 swift test --filter RealAgentTests 2>&1 | tee docs/acceptance/belege/A35/<datum>_real-agent-tests.txt` (gibt `REAL-CODEX:`/`REAL-CLAUDE:` mit Modell- und Effort-Liste aus).
2. Spike **T0** (Claude-Katalog im angemeldeten Zustand) nach `docs/integration-spikes/claude-code.md` §2.2: `account.subscriptionType` und Modellliste notieren.
3. Benutzer: Mac › Agentenübersicht › „Modellkatalog und Effort-Matrix …“ öffnen.
4. Implementierer: `agent_capabilities` und `agent_model_capabilities` abfragen (2.3).

**Erwartet:** Die Modelle in UI, DB und `REAL-*`-Ausgabe stimmen überein. Codex- und Claude-Modelle sind getrennt, keine Vermischung. Je Modell sind nur die gemeldeten Stufen plus `auto` wählbar, keine Pseudo-Optionen.
**Belege:** Testausgabe, DB-Abfrage, Screenshot der Matrix.

### A25 – GitHub Issues **[EXTERN SICHTBAR]**
1. Benutzer: ein privates Wegwerf-Repo anlegen und mit `beta-service` verbinden, z. B. `cd ~/Developer/SR-Testprojekte/beta-service && gh repo create sr-abnahme-beta --private --source . --remote github`. Ein Issue „Abnahme-Issue 1“ im Browser anlegen.
2. Benutzer: in den Einstellungen „GitHub (über gh)“ aktivieren. Das Issue importieren, eine Aufgabe mit einem Issue verknüpfen, den Titel ändern und synchronisieren.
3. Gegenprobe: WLAN aus. Aufgabe anlegen und Status ändern, das muss weiter funktionieren. GitHub-Fehler werden verständlich angezeigt.
4. Gegenprobe ohne `gh`: Benutzer setzt in den Einstellungen einen ungültigen gh-Pfad, falls die UI das erlaubt. Sonst entfällt dieser Schritt und wird in der Matrix genannt.

**Erwartet:** Import, Verknüpfung und Abgleich funktionieren. Ohne Netz oder `gh` bleibt die lokale App voll nutzbar, mit deutscher Erklärung.
**Belege:** Screenshots, `gh issue list -R <owner>/sr-abnahme-beta`, Log `category == "workspace"`.
**Aufräumen:** Repo nach der Kampagne löschen (Benutzer, `gh repo delete` braucht den Scope `delete_repo`).

### A27 (Mac-Teil) – Schlüssel am Mac **[API-KOSTEN, minimal]**
1. Benutzer: Einstellungen › „API-Schlüssel für die KI-Ausarbeitung am Mac“ › OpenAI-Schlüssel eintragen › „Prüfen“.
2. Benutzer: Schlüssel löschen („Schlüssel löschen?“ bestätigen).
3. Implementierer: Geheimnis-Suche (2.3) in DB und Logs der letzten Stunde, dazu `grep -rn "sk-" ~/Developer/SR-Testprojekte --include='*.md'`.

**Erwartet:** Erst „Schlüssel gültig“, nach dem Löschen „kein Schlüssel“ und KI-Funktionen mit Erklärung deaktiviert. Keine Treffer in DB, Logs und Repos. (iPhone/iCloud-Teil in Session 2.)
**Belege:** Screenshots, leere Suchausgaben.

### A29 (Mac-Teil) – Oberfläche
Siehe Session 2 (A29). Am Mac zusätzlich: Xcode › Open Developer Tool › Accessibility Inspector › Audit für Menüleiste, Hauptfenster (Projekte, Aufgaben, Queue, Review, Agenten, Einstellungen). VoiceOver (⌘F5) durch Menüleiste und Aufgabenliste. Dark/Light Mode und „Kontrast erhöhen“.

**Abschluss Session 1:** `sr_git_snapshot …/A30/<datum>_1-nach-session1.txt` und `diff` gegen die Basis. Erwartet sind nur die in A05/A06 freigegebenen Änderungen im Arbeitsbaum, keine Ref-Änderungen.

---

## Session 2 – iPhone/iPad und iCloud, kein Agentenkontingent

**Dauer:** ca. 3 h. **Vorbedingungen:** Session 1, V3, V4. Mac-Dienst läuft, iPhone und iPad in der App angemeldet bei iCloud.

### A03 – Neues Projekt am iPhone
1. Benutzer (iPhone): Projekte › „Neues Projekt“ › Ordner `delta-ordner` wählen, „Git-Repository anlegen („git init“)“ einschalten, anlegen.
2. iPhone zeigt „Einrichtung wartet auf den Mac“. Mac-Dienst läuft.
3. Implementierer: `srsql "SELECT kind, state FROM project_setup_commands ORDER BY rowid DESC LIMIT 3;"` (Spaltennamen ggf. mit `.schema project_setup_commands` prüfen), dazu `git -C ~/Developer/SR-Testprojekte/delta-ordner log --oneline`.
4. Gegenprobe: zweites Projekt in einem neuen Unterordner **ohne** git-init-Einwilligung.

**Erwartet:** Der Mac validiert und verknüpft das Projekt, `delta-ordner` hat jetzt `.git` **ohne Commit** (ADR-0024). Das iPhone zeigt den Status „bereit“ nach dem Öffnen bzw. „Jetzt synchronisieren“. Ohne Einwilligung gibt es kein `git init`.
**Belege:** iPhone-Screenshots (wartend, bereit), DB-Abfrage, `git log` (leer bzw. „does not have any commits yet“).

### A04 (iPhone-Teil)
Nach A04 Session 1: iPhone öffnen, die Aufgabe ansehen. Erwartet: Priorität „hoch“, Handabschnitt im Text sichtbar. Screenshot.

### A07 – Todo per Apple-Diktat (iPhone **und** iPad)
1. Benutzer: App neu installieren oder Berechtigungen zurücksetzen (Einstellungen › Allgemein › Übertragen/Zurücksetzen › Standort & Datenschutz zurücksetzen).
2. Diktat öffnen. Erwartet: Erklärbildschirm mit **nur** „Weiter“, kein „Später“ und kein Schließen. „Weiter“ löst sofort die Systemabfrage für Mikrofon und Spracherkennung aus (Q4, Guideline 5.1.1(iv)).
3. Erlauben, deutschen Satz diktieren, Transkript korrigieren, als Aufgabe speichern.
4. Fehlerfall: in iOS-Einstellungen die Spracherkennung entziehen und das Diktat erneut öffnen. Erwartet: Erklärung und Link in die Einstellungen, **keine** erneute Abfrage.
5. Offline-Fall (Flugmodus): Verhalten notieren (Spike S7: On-Device-Asset).

**Belege:** Bildschirmaufnahme der Schritte 2–4 auf iPhone und iPad, Aufgabe in der Liste.

### A08 – Todo per OpenAI Audio API **[API-KOSTEN]**
1. Benutzer: Einstellungen › OpenAI-Schlüssel am iPhone eintragen, „Prüfen“.
2. Diktat › Methode OpenAI › Aufnahme (ca. 10 s). Erwartet: Einwilligungsdialog **vor** dem Upload. Erst ablehnen: kein Upload, Hinweis. Dann zustimmen.
3. Transkript erscheint, korrigieren, speichern.

**Erwartet:** Upload nur nach Einwilligung, Transkript korrigierbar, Kostenschätzung sichtbar (falls Preistabelle gepflegt).
**Belege:** Screenshots, OpenAI-Usage-Seite (Benutzer) mit genau einem Transkriptionsaufruf.

### A09 – Notiz mit OpenAI, Anthropic und Gemini ausarbeiten **[API-KOSTEN ×3]**
1. Kurze Notiz „Senderliste auf dem iPad größer“ anlegen.
2. „Mit KI ausarbeiten“ je einmal mit OpenAI, Anthropic und Gemini (Schlüssel vorher eintragen).
3. Entwurf bearbeiten, „In diese Aufgabe übernehmen“.
4. Implementierer: `srsql "SELECT original_note, substr(structured_body,1,80) FROM work_item_texts WHERE title LIKE '%Senderliste%';"`.

**Erwartet:** Strukturierter, editierbarer Entwurf je Anbieter. `original_note` ist unverändert. Entwurfsversionen werden angehängt.
**Belege:** Screenshots je Anbieter, DB-Auszug.

### A10 – iPhone ohne Mac
1. Benutzer: Mac-Menü › „Dienst stoppen“ (oder Mac herunterfahren).
2. iPhone: Notiz, KI-Entwurf (Netz am iPhone nötig) und Jobwunsch „Mit Agent umsetzen“ mit Zeitplan **weit in der Zukunft** erfassen (kein Kontingent). App beenden.
3. Mac/Dienst starten. Implementierer: `srsql "SELECT t.title, count(*) n FROM work_items w JOIN work_item_texts t ON t.work_item_id=w.uuid GROUP BY t.title HAVING t.title LIKE '%<Testtitel>%';"` und `SELECT count(*) FROM agent_jobs WHERE …`.
4. Mac-Dienst noch zweimal neu starten und die Zählung wiederholen.

**Erwartet:** Alles kommt am Mac genau **einmal** an (n = 1), auch nach Neustarts. Der Job steht als `scheduled`. Danach Job abbrechen.
**Belege:** DB-Zählungen nach jedem Neustart, Log `category == "sync"`.

### A11 – Git-Projektkontext für KI **[API-KOSTEN]**
1. iPhone: Notiz zu `alpha-app` › „Am Mac mit Repo-Kontext ausarbeiten“ › „Kontext prüfen“.
2. Erwartet: Das Manifest listet die gesendeten Dateien und den Umfang. `.env` ist **nicht** enthalten.
3. „Kontext prüfen und senden …“. Entwurf als Aufgabe übernehmen.
4. Implementierer: Log `category == "ai"` und Geheimnis-Suche (2.3). Der Benutzer prüft in der Anbieter-Konsole, falls verfügbar, dass kein `sk-DUMMY` gesendet wurde.

**Belege:** Screenshot des Manifests, erzeugte Aufgabe, Log-Auszug.

### A12 – Codex/Claude deinstalliert bzw. installiert **[SYSTEMÄNDERUNG]**
1. Implementierer: `codex --version` und `npm ls -g --depth=0` notieren (Paketname und Version für die Neuinstallation).
2. Benutzer: Codex deinstallieren: `npm uninstall -g <paketname>`.
3. Mac: Agentenübersicht neu prüfen lassen (oder periodische Erkennung abwarten). iPhone: „Jetzt synchronisieren“, Agentenauswahl öffnen.
4. Benutzer: genau die notierte Version wieder installieren: `npm install -g <paketname>@<version>`. Schritt 3 wiederholen.
5. Claude: Die De- und Neuinstallation wird mit A40 kombiniert (`brew upgrade --cask claude-code` ersetzt die Installation).

**Erwartet:** Nach der Deinstallation ist Codex am Mac und iPhone „nicht installiert“ bzw. nicht startbar. Wird die gebündelte CLI der Desktop-App gefunden, ist sie ausdrücklich als „Codex Desktop-App, undokumentierter Pfad“ gekennzeichnet und nicht stillschweigend gleichwertig (Spike Codex §Erkennung). Nach der Neuinstallation ist wieder alles wie vorher. `capability_revision` ändert sich nur bei Katalogänderung.
**Belege:** Screenshots Mac und iPhone vorher, nach Deinstallation und nach Neuinstallation, `agent_capabilities`-Abfragen.

### A24 – gleiche Aufgabe offline auf Mac und iPhone
1. Mac: WLAN/Netz aus. iPhone: Flugmodus.
2. Dieselbe Aufgabe auf beiden Geräten im **gleichen Absatz** unterschiedlich ändern. Eine zweite Aufgabe auf beiden Geräten in **verschiedenen** Feldern ändern.
3. Netz wieder an, beide Geräte synchronisieren.
4. Implementierer: `sync_conflicts`-Abfrage (2.3).

**Erwartet:** Aufgabe 1 zeigt einen Konflikt auf beiden Geräten („Fassung dieses iPhones behalten“ / „Fassung des anderen Geräts übernehmen“), beide Texte sind erhalten. Aufgabe 2 wird per 3-Wege-Merge zusammengeführt. Keine stille Überschreibung.
**Belege:** Screenshots der Konfliktansicht, DB-Auszug vor und nach der Auflösung.

### A26 – keine sichtbaren Push-Mitteilungen (iPhone und iPad)
1. iOS-Einstellungen › Mitteilungen: Software Regisseur darf **nicht** auftauchen (nie angefragt).
2. Am Mac den Status einer Aufgabe ändern. iPhone im Hintergrund lassen: Es erscheint keine Mitteilung.
3. App in den Vordergrund holen bzw. „Jetzt synchronisieren“. Die Änderung erscheint, der Sync-Zeitpunkt wird angezeigt und aktualisiert.

**Belege:** Screenshot der Mitteilungseinstellungen, Vorher/Nachher mit Sync-Zeitpunkt.

### A27 (iPhone/iCloud-Teil) **[API-KOSTEN, minimal]**
1. iPhone: OpenAI-Schlüssel mit „Über iCloud-Schlüsselbund synchronisieren“ speichern. Am Mac erscheint er unter derselben Access-Group (Spike S8).
2. Benutzer: in der CloudKit-Console (icloud.developer.apple.com, Container `<SR_CLOUDKIT_CONTAINER>`, Private Database, eigene Zone) die Provider-Profil-Records ansehen: **kein** Schlüsselfeld und kein Schlüsselwert.
3. Schlüssel löschen (am iPhone, „Schlüssel löschen“). Funktionen degradieren mit Erklärung, am Mac ebenfalls.
4. Implementierer: Geheimnis-Suche in DB und Logs.

**Belege:** Screenshot der CloudKit-Console (geschwärzt), leere Suchausgaben, Screenshots der Degradierung.

### A29 – deutsche Oberflächen, Bedienungshilfen (iPhone, iPad, Mac)
Für jede Hauptansicht (Übersicht, Inbox, Aufgaben, Aufgabendetail, Projekte, Diktat, KI-Ausarbeitung, Agenten/Start, Freigaben, Review, Einstellungen, Daten exportieren/löschen):
1. VoiceOver: jedes Bedienelement hat eine deutsche, sinnvolle Bezeichnung, die Reihenfolge ist logisch.
2. Dynamic Type auf die größte Bedienungshilfen-Größe: nichts abgeschnitten, keine Überlappung.
3. Dark Mode und Light Mode: Kontraste lesbar.
4. Leerzustände (frisches Projekt, keine Reviews, „Kein Mac verbunden“) und Fehlerzustände (kein Netz, kein Schlüssel, Mac offline) mit verständlicher deutscher Erklärung.
5. iPad: Vollbild, Split View ½ und ⅓, Hardware-Tastatur und Zeiger (ADR-0025). Texte sagen „iPad“ oder sind neutral.

**Belege:** Screenshot-Serie je Gerät und Modus, Liste der gefundenen Mängel (→ `failed`, falls Muss verletzt).

### A37 / A38 (iPhone-Teil) – Voreinstellungen
1. iPhone/Mac: global Codex = Modell M1, Effort `low`. Projekt `alpha-app` = Effort `medium`. 
2. Job J1 für `alpha-app` ohne Job-Überschreibung, Job J2 mit Job-Effort `high`, Job J3 in `beta-service`. Alle mit Zeitplan weit in der Zukunft.
3. Implementierer: `SELECT substr(job_id,1,8), resolved_model_id, resolved_effort FROM agent_jobs ORDER BY created_at DESC LIMIT 3;`.
4. Projekt-Effort auf `xhigh` ändern (falls M1 das anbietet, sonst eine andere angebotene Stufe). J1 bleibt unverändert, ein neuer Job J4 bekommt die neue Stufe.
5. Für jedes Modell im iPhone-Dialog die Stufenliste fotografieren und mit `supported_effort_ids` vergleichen (A37).

**Erwartet:** J1 = M1/`medium`, J2 = M1/`high`, J3 = M1/`low`, J4 = neue Stufe, J1 unverändert. Danach alle Jobs abbrechen.
**Belege:** DB-Auszüge, Screenshots.

### A39 (Teil 1) – Snapshot über iCloud und Neustart
1. iPhone: Job für morgen mit ausdrücklich gewähltem Modell und Effort planen. Implementierer: `config_snapshot` sichern (`…/A39/<datum>_snapshot-1.txt`).
2. Benutzer: Mac neu starten (echter Neustart). Danach die globalen und Projekt-Voreinstellungen ändern.
3. `config_snapshot` erneut sichern und `diff` bilden. Erwartet: identisch.
4. Der Job bleibt für A39 Teil 2 (Session 3) bestehen, oder wird für Session 3 neu angelegt.

### A40 – Upgrade bzw. Wegfall der Unterstützung **[SYSTEMÄNDERUNG]**
1. Implementierer: `claude --version` (die aktuell installierte Version, Stand 30.10.2026: 2.1.308), `agent_capabilities` und `agent_model_capabilities` für Claude sichern.
2. Benutzer: einen Claude-Job mit Modell X und Effort Y für morgen planen (kein Kontingent).
3. Benutzer: `brew upgrade --cask claude-code` (ersetzt die Installation, deckt den Claude-Teil von A12 ab). Falls danach abgemeldet: `claude auth login`.
4. Mac: Agenten neu prüfen lassen. Implementierer: Abfragen aus Schritt 1 wiederholen und `diff` bilden.
5. Wegfall erzwingen (reversibel): Benutzer sichert `~/.claude/settings.json` und setzt dort `"availableModels"` auf eine Liste **ohne** Modell X (Admin-Einschränkung laut Spike 4a). Danach neu prüfen lassen. Ob der `initialize`-Katalog diese Einschränkung widerspiegelt, ist nicht belegt. Spiegelt er sie nicht, das Ergebnis dokumentieren und stattdessen auf den nächsten realen Modellwegfall warten. Danach die gesicherte Datei zurückspielen.
6. Spikes **T9** und **O2** (unbekanntes Modell, Fehlerform) laut Spike-Protokollen. Sie verbrauchen voraussichtlich kein Kontingent, weil der Lauf abgelehnt wird. Falls doch, als **[KONTINGENT]** werten.

**Erwartet:** Neue Version und `capability_revision` erkannt, Katalog aktualisiert (Mac und iPhone). Ein Job mit nicht mehr unterstütztem Modell oder Effort steht **vor dem Start** auf `needs_configuration`, mit Begründung und Neuauswahl. Kein stilles Herabstufen.
**Belege:** Versionen, DB-Diffs, Screenshots der Neuauswahl.

### A42 – UI- und Sync-Grenzfälle
Je Fall Screenshot auf iPhone **und** Mac:
1. iPhone offline (Flugmodus): Offline-Hinweis, Erfassen geht weiter.
2. Mac offline (Dienst gestoppt bzw. Mac aus): „Mac zuletzt online …“, nie „läuft“.
3. Veralteter Modellkatalog: Mac mehrere Stunden aus, iPhone zeigt das Alter des Katalogs bzw. einen Hinweis.
4. Agent ohne Effort-Unterstützung: Modell mit leerer `supported_effort_ids` wählen, nur `auto` angeboten. Gibt es real kein solches Modell, in der Matrix vermerken.
5. Fehlende Accountberechtigung: Benutzer meldet Codex ab (`codex logout`), Status am iPhone prüfen, danach wieder `codex login` **[SYSTEMÄNDERUNG]**.

### A18 (Variante ohne Kontingent) – Mac zum Startzeitpunkt aus
1. Projekt-Nachholregel auf `skipExpired` stellen (bzw. `ask`). iPhone: Codex-Job für in 15 min planen.
2. Benutzer: Mac herunterfahren. Nach dem Sollzeitpunkt iPhone öffnen: Erwartet „für hh:mm geplant, Mac zuletzt online hh:mm“, **nicht** „läuft“.
3. Mac starten. Erwartet bei `skipExpired`: Job übersprungen bzw. abgelaufen mit Vermerk. Bei `ask`: Nachfrage an Mac und iPhone, kein Start ohne Antwort.

**Belege:** iPhone-Screenshots, `agent_jobs`-Zeile, `task_events` des Jobs.

### A15 (Variante A, ohne Kontingent) – Doppelstart
1. iPhone: bei einer Aufgabe „Mit Agent umsetzen“ mit Zeitplan morgen zweimal schnell bestätigen. Gleichzeitig am Mac für dieselbe Aufgabe einen Job anfordern.
2. Implementierer: `SELECT count(*) FROM agent_jobs WHERE work_item_id='<uuid>' AND state NOT IN ('finished','failed','cancelled');`.

**Erwartet:** genau 1 aktiver Job. Der zweite Wunsch wird verständlich abgewiesen bzw. führt auf denselben Job. Danach abbrechen. Variante B mit echtem Lauf folgt in Session 3.

**Abschluss Session 2:** Git-Schnappschuss `…/A30/<datum>_2-nach-session2.txt`.

---

## Session 3 – echte Agenten mit Kontingent

**Vorbedingungen:** Sessions 1–2, V5 und V6 frisch geprüft, Kontingentfreigabe durch den Benutzer. Live-Log in einem zweiten Terminal: `log stream --info --predicate 'subsystem == "<SR_BUNDLE_ID_PREFIX>.SoftwareRegisseur.Mac.AgentService"'`.

### 3.0 Adapter-Spikes vorab (Implementierer, laut Spike-Protokollen)

| Spike | Kosten | Zweck |
|---|---|---|
| O1 (Codex app-server, „Antworte nur mit OK.“, Effort `low`) | **[KONTINGENT Codex]** ×1 | wirksame Modell-/Effort-Parameter, Event-Felder → A41 |
| O3 (Approval-Roundtrip, `decline`) | **[KONTINGENT Codex]** ×1 | Freigabeform → A20 |
| O4 (`codex exec`-Parität) | **[KONTINGENT Codex]** ×1, optional | Diagnose-Fallback |
| O5 (Resume nach Neustart) | **[KONTINGENT Codex]** ×1 | A21 |
| T1 (Headless-Grundlauf, `--model sonnet --effort low --max-turns 1`) | **[KONTINGENT Claude]** ×1 | `init.model`, `modelUsage` → A41 |
| T2 (Freigabe-Roundtrip, deny) | **[KONTINGENT Claude]** ×1 | → A20 |
| T7 (Effort im Debug-Log) | im T1-Lauf mit `--debug-file` | → A41 (bleibt „nicht bestätigt“, falls nur Debug-Log) |

Die Befehle stehen wörtlich in `docs/integration-spikes/codex.md` (Tabelle „Offene Punkte“) und `docs/integration-spikes/claude-code.md` §4. Ergebnisse dort nachtragen. Diese Läufe sind **außerhalb** von Software Regisseur und laufen deshalb in einem Wegwerf-Repo (`gamma-lib`).

### A13 – sofortiger Codex-Lauf **[KONTINGENT Codex]** + A22 + A23 + A41 (Codex)
1. Benutzer (iPhone): in `alpha-app` eine Aufgabe mit dem Minimalauftrag (2.6, `<agent>` = `codex`) anlegen › „Mit Agent umsetzen“ › Codex, kleinstes Modell, `low`, sofort.
2. Während des Laufs Implementierer:
   - `srsql` Jobs und Locks (2.3): Job `running`, Lock `task`.
   - `git -C ~/Developer/SR-Testprojekte/alpha-app worktree list`: neuer Worktree unter `$SR_WT`.
   - Prozess finden (A41): `for p in $(pgrep -f 'codex'); do c=$(lsof -a -p $p -d cwd -Fn 2>/dev/null | sed -n 's/^n//p'); case "$c" in "$SR_WT"*) echo "$p $c"; ps -o args= -p $p;; esac; done`.
3. Nach dem Ende: Job `finished`, Aufgabe **`review`** (nicht `done`). Request-Datei im Review-Ordner. Diff und Testergebnis am Mac (Review) und iPhone (Review) sichtbar → **A22**.
4. A41: `effective_model_id` und `effective_effort` gegen die Wahl prüfen, Verlauf (`task_events`) zeigt die effektiven Werte. Ergänzend und nur als Hinweis: Codex' eigene Sitzungsprotokolle unter `~/.codex/sessions/` (Format undokumentiert).
5. **A23:** Benutzer gibt im Mac-Review frei und integriert (Squash). Danach:
   - `git -C …/alpha-app log --oneline -3`: ein Integrations-Commit mit nachvollziehbarer Nachricht.
   - `ls …/alpha-app/abnahme/`: `hello-codex.txt`.
   - Request-Datei im `done`-Ordner, Status `done`. iPhone zeigt „Erledigt“.
   - Software Regisseur hat **keine** eigenen Commits für Request-Dateien gemacht (ADR-0024). Die verschobene Request-Datei ist unversioniert bzw. geändert und wird vom Benutzer selbst committet.
6. Worktree-Aufräumen in der Queue auslösen. `git worktree list` zeigt danach den Worktree nicht mehr, der Haupt-Worktree ist unberührt.

**Belege:** DB-Auszüge (vor, während, nach), `ps`-Zeile, `git worktree list`, `git log`, Screenshots Review Mac und iPhone, Log `category == "jobs"`.

### A14 – sofortiger Claude-Code-Lauf **[KONTINGENT Claude]** + A20 (Claude) + A41 (Claude)
1. iPhone: Minimalauftrag (`<agent>` = `claude`) in `beta-service` › Claude, kleinstes Modell, `low`, sofort.
2. Während des Laufs: `ps -o args= -p <pid>` zeigt `claude -p … --session-id <job-uuid> --model <id> --effort low --permission-mode manual --permission-prompt-tool stdio`, **ohne** `--remote-control`, `--dangerously-skip-permissions`, `-w` oder `--bg` (ADR-0021) → A41, A30.
3. Die Freigabeanfrage zum Anlegen der Datei erscheint am iPhone (nach Öffnen bzw. Sync, ADR-0023) → „Erlauben“. Implementierer: `pending_approvals` und `approval_decisions` (genau eine Entscheidung, genau einmal weitergeleitet).
4. Nach dem Ende: Review wie A22. `effective_model_id` = `system/init.model`, Effort „nicht bestätigt“ (Spike 5c).
5. Mobile Weiterführung: Die UI bietet **keinen** Link in die Claude-App an, solange A32 offen ist, sondern den ehrlich beschrifteten V1-Weg (Status und Freigaben in Software Regisseur). Das Ergebnis aus Session 4 wird hier nachgetragen.

**Belege:** `ps`-Zeile, DB-Auszüge, Screenshots Freigabe und Review.

### A20 – Freigaben
- **Erlauben:** in A14 erledigt.
- **Ablehnen** **[KONTINGENT Claude]** ×1: Minimalauftrag erneut, Freigabe am iPhone „Ablehnen“. Erwartet: Datei nicht angelegt, Lauf meldet die Ablehnung, kein Weiterlaufen mit Zustimmung.
- **Zeitüberschreitung** (im selben oder nächsten Lauf): Freigabe-Timeout in den Diensteinstellungen auf das Minimum stellen, nicht antworten. Erwartet: Job `paused` (bzw. `failed` bei Fail-Regel), **nie** eine automatische Zustimmung. Eine Entscheidung nach Ablauf wird ignoriert.
- **Codex:** über O3 (3.0) belegt. Ein Lauf in Software Regisseur mit dem Auftrag „Führe `curl -sI https://example.com` aus und nenne den Statuscode.“ **[KONTINGENT Codex]** ×1, optional.

**Belege:** Screenshots, `pending_approvals`/`approval_decisions`, `task_events`.

### A15 (Variante B) – Doppelstart mit echtem Lauf **[KONTINGENT Claude oder Codex]** ×1
Wie Session 2/A15, aber „sofort“. Zusätzlich während des Laufs die Prozesssuche aus A13 Schritt 2: genau **ein** Agentenprozess für die Aufgabe.

### A16 – zwei Aufgaben parallel **[KONTINGENT Codex]** ×2
1. Zwei Aufgaben in `alpha-app` (`hello-codex-a.txt`, `hello-codex-b.txt`), beide sofort starten. Projektsperre **aus**, „Parallele Läufe erlauben“ an.
2. Während des Laufs: zwei Worktrees, zwei Branches (`git branch -a`), zwei Locks mit Scope `task`.
3. Nach dem Ende: `git -C <worktree-a> diff --stat main` enthält nur Datei a, Worktree b nur Datei b.
4. Gegenprobe Limit: max. parallele Jobs = 1 setzen und zwei Jobs **planen** (morgen). Die Queue zeigt, dass der zweite wartet. Danach abbrechen (kein Kontingent).

**Belege:** `git worktree list`, Branches, Diffs, Lock-Abfrage.

### A21 – Agent abrupt beendet / Dienst-Absturz **[KONTINGENT]** ×2
Für ausreichend Laufzeit den Auftrag nehmen: „Führe `sleep 120` aus und lege danach `abnahme/slow.txt` mit Inhalt `ok` an.“ (Claude fragt für `sleep` eine Freigabe an: erlauben.)
1. **Agentenprozess töten:** PID mit der Prozesssuche aus A13 ermitteln (nur Prozesse mit cwd unter `$SR_WT`) und `kill -9 <pid>`. Erwartet: Job `failed` (bzw. laut Regel), Lock freigegeben, Worktree erhalten, **kein** automatischer Neustart, Aufgabe nicht `done`.
2. **Dienst töten** (neuer Lauf): `kill -9 $(pgrep -x SoftwareRegisseurAgentService)`. launchd startet den Dienst neu (`KeepAlive`, `SuccessfulExit = false`). Erwartet: Läuft der Agent noch, wird der Job `paused` und der Lock bleibt, bis der Prozess endet, ohne zweiten Start. Ist der Agent tot, wird der Job `failed` und der Lock freigegeben.
3. Nach beiden Fällen: `sync_outbox`-Zustände ohne hängende `inFlight`-Einträge. Der iPhone-Status ist konsistent.

**Belege:** DB vor und nach dem Kill, `launchctl print` (Neustart, `last exit`), `git worktree list`, Log `category == "lifecycle"` und `"jobs"`.

### A39 (Teil 2) – Lauf und Wiederholung mit fixiertem Snapshot **[KONTINGENT]** ×2
1. Den Job aus Teil 1 (oder einen neu geplanten in 10 min) laufen lassen.
2. Danach in der Queue „Wiederholen“: Der neue Job verweist per `retry_of_job_id` auf den alten.
3. `config_snapshot`, `resolved_*` und `effective_*` beider Jobs vergleichen. Erwartet: identisch zur ursprünglichen Auswahl, unabhängig von den inzwischen geänderten Voreinstellungen.

### A17 – Start morgen 07:00 **[KONTINGENT]** ×1 (über Nacht)
1. Abends am iPhone: Minimalauftrag, „Zu einem Zeitpunkt“: morgen 07:00, Zeitzone Europe/Vienna.
2. Benutzer: Mac abends einmal neu starten, danach über Nacht am Netzteil eingeschaltet lassen. Der Mac muss um 07:00 wach sein: In Systemeinstellungen › Energie den automatischen Ruhezustand verhindern. Die App-Option „Leerlauf-Ruhezustand verhindern, solange ein Agent arbeitet“ greift erst während eines Laufs und weckt den Mac nicht.
3. Morgens: `started_at` = 07:00 ±1 min lokal, genau **ein** Job und ein Lauf. `log show --start "<datum> 06:55" --end "<datum> 07:10" --predicate '… AND category == "jobs"'`.

**Belege:** DB-Zeile mit Zeitstempeln, Log-Auszug, iPhone-Screenshot am Abend („geplant für 07:00“).

### A18 (Variante B, optional) **[KONTINGENT]** ×1
Wie Session 2/A18 mit Nachholregel `runImmediatelyWhenAvailable`. Erwartet: genau ein Start kurz nach dem Hochfahren und Status-Vermerk „nachgeholt“.

### A19 – Kontingent erreicht (passiv)
**Nicht absichtlich herbeiführen.** Während aller Läufe dieser und späterer Sessions:
- Claude: jedes `rate_limit_event` bzw. `api_retry` (Spike T8) wird im Log `category == "agents"` sichtbar. Bei `status = rejected` ist zu belegen: Job `waiting_quota`, angezeigter nächster Versuch (gemeldetes `resetsAt` oder begrenzter Backoff), Lock nach Prozessende frei, **genau ein** späterer Wiederholversuch.
- Codex: beim ersten natürlichen `usageLimitExceeded` das Gleiche protokollieren (Spike O7).
- Bis dahin bleibt A19 `offen`.

### A30 – Abschlusskontrolle nach Session 3
`sr_git_snapshot …/A30/<datum>_3-nach-session3.txt` und `diff` gegen den Stand nach Session 2:
- Remotes in `SR-Testprojekte.remotes`: **unverändert** (kein Push).
- Reflogs ohne `reset:` oder `rebase` außer im Integrations-Worktree des Dienstes.
- Neue Commits nur: Integrations-Commits aus A23 (bestätigt) und Commits der Agenten auf ihren Job-Branches.
- Keine gelöschten Branches außer per „Worktree entfernen“ bestätigter Job-Branches.

---

## Session 4 – mobile Weiterführung (Spikes O6, T3–T6)

**Ziel:** ADR-0010 entscheiden und A31/A32 belegen. **Vorbedingungen:** Claude Code auf aktueller Version (nach A40), Max-Login, Claude-iOS-App mit demselben Konto. ChatGPT-iOS-App mit Codex-Zugang, Desktop-App bzw. CLI-Remote-Control verfügbar. Eigene Wegwerf-Worktrees.

### A32 – Claude (Spikes T3–T6) **[KONTINGENT Claude]** ×3
Ausführung laut `docs/integration-spikes/claude-code.md` §4 (Befehle wörtlich dort):
1. **T3:** interaktive Remote-Control-Sitzung mit Erst-Prompt im PTY (`script -q /dev/null claude --remote-control "SR-Spike" --session-id <uuid> --model sonnet --effort low "Antworte nur mit OK."`) im Testrepo. Prüfen: Läuft der Prompt automatisch? Ist die Sitzung in der Claude-iOS-App sichtbar? URL-Format notieren. Chat und Freigabe vom iPhone möglich? Werden Modell und Effort angezeigt?
2. **T4:** am iPhone `claude://code/<remote-id>` aus der T3-URL öffnen. Öffnet sich genau diese Sitzung?
3. **T5:** Übergabe Headless → Remote Control (`claude --resume <uuid> --remote-control …` nach einem T1-artigen Lauf). Ist der Verlauf in der App sichtbar und kann man weiterchatten?
4. **T6:** T3 in einem frisch angelegten Worktree unterhalb eines vertrauten Pfads. Erscheint eine Trust-Abfrage?

**Auswertung:** Bestehen T3, T4 und T6, ist Modus B vollautomatisch möglich: ADR-0010 annehmen, Umsetzung, danach A32 mit echtem Lauf aus Software Regisseur belegen. Scheitert der Erst-Prompt bzw. Trust, gilt der Fallback aus Spike §2.5 („headless starten, dann übergeben“ oder „manuell-transparent“). A32 wird `passed`, wenn der Fallback real funktioniert und ehrlich beschriftet ist.
**Belege:** Bildschirmaufnahme iPhone, Terminal-Mitschnitt (Login-Daten geschwärzt), Nachtrag im Spike-Protokoll.

### A31 – Codex (Spike O6) **[KONTINGENT Codex]** ×2
Ausführung laut `docs/integration-spikes/codex.md` (Zeile O6): `codex remote-control start --json` → `pair --json` → iPhone (ChatGPT-App, Codex) koppeln (Benutzer) → Client über `codex app-server proxy` → O1-Turn mit `ephemeral: false`. Ist der Thread in der iOS-App sichtbar? Folgenachricht und Approval vom iPhone? Gegenprobe mit separatem `codex app-server --listen stdio://`. Danach `codex remote-control stop`. Vorher die Config-Einstellung `remote_connections` klären.

**Auswertung:** Sichtbar und bedienbar: ADR-0010 annehmen, Adapter umstellen, A31 mit echtem Lauf aus Software Regisseur belegen. Nicht sichtbar: Der V1-Fallback (Status und Freigaben über iCloud, ADR-0023, keine `codex://`-Links) ist der belegte Weg. A31 wird mit dem Fallback-Nachweis aus Session 3 `passed`, mit Verweis auf dieses Spike-Ergebnis.
**Belege:** Bildschirmaufnahme iPhone, JSON-Mitschnitt (geschwärzt), Nachtrag im Spike-Protokoll.

---

## Session 5 – Release, Notarisierung, frisches System, Abschluss

**Vorbedingungen:** Developer-ID-Zertifikat, Notarisierungs-Profil und Sparkle-Schlüssel (docs/release/README.md, „Einmalige Einrichtung“). CloudKit-Schema nach Production deployt (V4). Ein **frischer Mac oder ein neues macOS-Benutzerkonto** und dazu das iPhone mit TestFlight-Build (Production).

### A28 – Signing und Notarisierung
1. Implementierer: `Scripts/release.sh 1.0.0 <build>`, danach `Scripts/sign-and-notarize.sh DerivedData/Releases/1.0.0-<build>/SoftwareRegisseur-1.0.0.dmg --keychain-profile SoftwareRegisseur-Notary`.
2. `Scripts/verify-release.sh <dmg>` (ohne `--pre-notarization`): keine `FEHLER`-Zeile.
3. Benutzer: DMG auf das frische System kopieren (nicht per Xcode), per Doppelklick installieren und starten. Gatekeeper-Dialog ohne Warnung zu „nicht verifiziertem Entwickler“. LaunchAgent erlauben.
4. A01 auf dem frischen System wiederholen (Neustart, Menüleiste, Dienst aktiv).
5. Sparkle: Release n+1 bauen, Appcast lokal bereitstellen, „Nach Updates suchen …“ → Update auf n+1. Danach prüfen, ob der **Dienst** die neue Version ausführt (offener Punkt S3, docs/release/README.md). Manipuliertes Paket (ein Byte verändert, Original-`edSignature`) wird abgelehnt.
6. Agenten-Start aus dem notarisierten Dienst (Spike S5): ein Minimalauftrag **[KONTINGENT]** ×1, optional, oder nur Erkennung ohne Kontingent.

**Belege:** `verify-release.sh`-Ausgabe, `*.notarytool-log.json`, `spctl -a -vv`, Screenshots der Installation, Updater-Log (`subsystem == "SoftwareRegisseur"`).

### A33 – mehrere Hosts **[KONTINGENT]** ×1
Vorbedingung: zweiter Mac (oder das frische Benutzerkonto mit derselben Apple-ID, sofern es eine eigene Host-ID erhält: `SELECT host_id, name FROM agent_hosts;` auf beiden Seiten prüfen). Testordner per Skript auch dort anlegen.
1. Projekt `alpha-app` auf Host A festlegen. Beide Hosts online.
2. iPhone: Job in 10 min planen. Erwartet: Nur Host A startet, Host B zeigt bzw. loggt keine Übernahme.
3. Rennen: Job in 10 min planen, **beide** Macs vor dem Zeitpunkt herunterfahren und nach dem Zeitpunkt gleichzeitig starten. Erwartet: höchstens ein Start, und zwar auf Host A.
4. Hostwechsel bewusst über die UI: Erst danach darf Host B ausführen.

**Belege:** `agent_jobs.host_id` und `started_at` auf beiden Hosts, Logs beider Hosts, Prozesssuche auf beiden.

### A34 – Datenauskunft und Löschen **[DESTRUKTIV]** – ganz am Ende
1. **Export Mac:** Menü › „Daten exportieren …“. Manifest-Zählungen gegen die DB vergleichen (`SELECT count(*) FROM work_items;`, `adrs`, `task_events`, `projects` …). `grep` der Exportdateien nach Schlüsselmustern (2.3): keine Treffer.
2. **Export iPhone:** Einstellungen › „Daten exportieren“ › „Export erstellen“ (mit „Diktataufnahmen einschließen“). Archiv in Dateien sichern und stichprobenartig öffnen.
3. **Löschen lokal** (Mac und iPhone): „Daten löschen“. Die Vorschau zeigt exakt die betroffenen Dateien. Reihenfolge: Audios, dann Schlüssel eines Anbieters, dann lokale Datenbank. Danach: `ls "$SR_GROUP/SoftwareRegisseur"`, Keychain-Einträge entfernt, Repos unverändert (`sr_git_snapshot` + `diff`).
4. **Löschen iCloud:** „iCloud-Daten löschen“ an einem Gerät. Erwartet: Zone gelöscht, Sync pausiert, das zweite Gerät lädt **nicht** automatisch neu hoch. „Lokale Daten erneut hochladen“ nur auf ausdrückliche Wahl.

**Belege:** Exportmanifest, Zählvergleich, Screenshots der Vorschau, Verzeichnislisting, CloudKit-Console (Zone weg), Git-Schnappschuss-Diff.

### A30 – Endabgleich
Letzter `sr_git_snapshot` und Diff gegen die Basis aus Session 1. Zusammenfassung im Beleg: jede Ref-Änderung mit Ursache (Testschritt).

---

## 6. Zuordnung A-ID → Session

| ID | Session | Kosten |
|---|---|---|
| A01 | 1 (Wiederholung 5) | – |
| A02 | 1 | – |
| A03 | 2 | – |
| A04 | 1 + 2 | – |
| A05 | 1 | – |
| A06 | 1 | – |
| A07 | 2 | – |
| A08 | 2 | API |
| A09 | 2 | API ×3 |
| A10 | 2 | – |
| A11 | 2 | API |
| A12 | 2 | Systemänderung |
| A13 | 3 | Codex ×1 |
| A14 | 3 (+ Nachtrag 4) | Claude ×1 |
| A15 | 2 (A) + 3 (B) | B: ×1 |
| A16 | 3 | Codex ×2 |
| A17 | 3 (über Nacht) | ×1 |
| A18 | 2 (A) + 3 (B, optional) | B: ×1 |
| A19 | 3 ff. (passiv) | kein zusätzliches |
| A20 | 3 | Claude ×1 (+ Codex ×1 optional) |
| A21 | 3 | ×2 |
| A22 | 3 | aus A13 |
| A23 | 3 | aus A13 |
| A24 | 2 | – |
| A25 | 1 | extern sichtbar |
| A26 | 2 | – |
| A27 | 1 + 2 | API minimal |
| A28 | 5 | – (optional ×1) |
| A29 | 1 + 2 | – |
| A30 | 1 → 5 (Schnappschüsse) | – |
| A31 | 4 | Codex ×2 |
| A32 | 4 | Claude ×3 |
| A33 | 5 | ×1 |
| A34 | 5 (zuletzt) | destruktiv |
| A35 | 1 | – |
| A36 | 1 | – |
| A37 | 1 + 2 | – |
| A38 | 2 | – |
| A39 | 2 + 3 | ×2 |
| A40 | 2 | Systemänderung |
| A41 | 3 | aus A13/A14 und Spikes |
| A42 | 2 | Systemänderung (Abmelden) |
