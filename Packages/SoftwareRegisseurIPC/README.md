# SoftwareRegisseurIPC – Vertrag zwischen Mac-UI und Agent Service

Protokollversion: **4** (`IPCProtocol.version`), Clients ab Protokoll **2** werden weiter bedient
(`IPCProtocol.minimumSupportedVersion`). Nur macOS. iPhone und Mac sprechen ausschließlich
über CloudKit miteinander (ADR-0003, ADR-0011); dieses Paket betrifft nur die zwei Prozesse auf
demselben Mac (ADR-0020).

## Grundsätze

- **Lesen über die Datenbank, Schreiben über XPC.** Die UI öffnet die Datenbank des Dienstes nur
  lesend: `AppDatabase.openReadOnly(at: ServiceStorageLayout(endpoint:)!.databaseURL)` (ADR-0019).
  Projekte, Aufgaben, Jobs, Reviews, Freigaben, Konflikte, ADRs, Fähigkeiten, Verlauf usw. liest sie
  dort direkt (GRDB-Beobachtung möglich). Jede Änderung geht als Befehl über XPC an den Dienst, den
  einzigen Schreiber.
- **Über XPC kommen nur Daten, die es nur im Dienstprozess gibt:** Statusübersicht, Stammordner,
  Vorschläge für AGENTS.md/CLAUDE.md, Migrationsvorschauen, hostlokale Job-/Review-Details,
  GitHub-Issue-Listen, Stand von KI-Ausarbeitungen, Ergebnis gespeicherter Gespräche/Gesprächsentwürfe.
- **Fachliche Entscheidungen** (Freigaben, Reviews, Integration, Erledigt, Anweisungsdateien,
  Ordnermigration) führt der Dienst immer als `EventActor.user(<Geräte-ID dieses Macs>)` aus. Die UI
  zeigt vorher Vorschau/Diff und schickt den Befehl erst nach ausdrücklicher Bestätigung.
- **Keine stillen Erfolge.** Antworten sind entweder ein Ergebnis, `failure(String)` mit deutscher,
  geheimnisfreier Meldung oder `notAvailable(Feature)`.

## Transport

- Mach-Service `<App-Group>.agent` (`ServiceEndpoint`), Peer-Prüfung „gleiches Team **und** erwarteter
  Signing-Identifier“ (`ServicePeerPolicy`, SR-SEC-05): Der Dienst akzeptiert nur die Mac-App
  (Info.plist `SRMacAppBundleIdentifier` = `$(SR_MAC_BUNDLE_ID)`), die App spricht nur mit dem Dienst
  (`SRAgentBundleIdentifier` = `$(SR_AGENT_BUNDLE_ID)`). Fehlt der Wert oder ist er eine nicht aufgelöste
  Build-Variable (Entwicklungs-Build ohne `Config/Local.xcconfig`), gilt dokumentiert gelockert nur „gleiches
  Team“. Unsignierte Builds (`CODE_SIGNING_ALLOWED=NO`) können sich in keinem Fall verbinden.
- Client: `ServiceXPCClient(endpoint:)`, `send(_:) async throws(ServiceClientError) -> ServiceResponse`.
  Die Wartezeit ist `max(Client-Frist, request.minimumTimeout)`: 5 s für Abfragen, 60 s für normale
  Befehle, 180 s für lange Vorgänge (Sync, Scan, Agentenerkennung, Integration, GitHub, Einrichtung).
- Server: `ServiceXPCServer`; jede Nachricht wird asynchron in einem eigenen Task beantwortet.
- Jeder Umschlag trägt `protocolVersion`. Der Dienst bedient Clients von `minimumSupportedVersion` (2) bis
  `version` (4) und antwortet mit der Version des Clients, damit dessen Prüfung besteht. Neue Befehle,
  Ergebnisarten und Felder sind rein additiv (neue Felder optional bzw. mit Standardwert beim Dekodieren).
  Ältere oder neuere Clients → `protocolMismatch(serviceVersion:clientVersion:)` (UI: „Dienst und App haben
  unterschiedliche Versionen – Dienst neu starten“).

## Ablage im App-Group-Container (`ServiceStorageLayout`)

| Pfad | Inhalt |
|---|---|
| `SoftwareRegisseur/Database/SoftwareRegisseur.sqlite` | Datenbank (WAL), UI nur lesend |
| `SoftwareRegisseur/Worktrees/` | Agenten-Worktrees, außerhalb aller Stammordner (L2) |
| `SoftwareRegisseur/Integration/` | Worktree für die Integration (ADR-0015) |
| `SoftwareRegisseur/Runtime/` | hostlokale Laufzeitdaten der Jobs (dienstintern) |
| `SoftwareRegisseur/SyncAssets/`, `Detection/` | dienstintern |

Ein Stammordner, der diese Ablage enthält (oder darin liegt), wird abgelehnt.

Hostlokaler Dienstzustand (nie synchronisiert) liegt in der Tabelle `host_state`, Scope
`agentService`: Host-ID, Geräte-ID des Mac-Benutzers, Pause-Zustand, bestätigte Stammordner,
`ServiceSettings`, Manifeste der KI-Ausarbeitungen. Das Format ist dienstintern – die UI fragt diese
Werte über XPC ab, nicht per SQL.

## Statusübersicht für Menüleiste und Dashboard

`statusSummary` → `.statusSummary(ServiceStatusSummary)`. Empfohlen: alle 5–10 s abfragen, solange
Menü oder Fenster sichtbar sind.

- `macState`: `ready` (Mac bereit), `paused` (pausiert), `degraded` (läuft, aber kein Stammordner,
  kein einsatzbereiter Agent oder kein Git), `starting`. „Offline“ = Dienst nicht erreichbar
  (Client-Fehler), das stellt nur die UI fest.
- `sync`: Zustand (`unavailable` mit Grund, `idle`, `syncing`, `paused`, `failed`), iCloud-Account,
  letzte erfolgreiche Synchronisierung (`lastSync`), ausstehende Änderungen, offene Konflikte,
  deutsche Hinweise (`attention`).
- `agents`: je Anbieter installiert/angemeldet/einsatzbereit, Version, Prüfzeit, Diagnose und
  **aktive Läufe** (`activeJobs`; Summe: `activeAgentCount`).
- `queue`: wartend (`requested`/`pendingMac`), geplant inkl. `nextPlannedStart`, Kontingent,
  Freigaben (`waitingApproval`, `openApprovals`), pausiert, blockiert, fehlgeschlagen,
  `reviewsPending`, deutsche Start-Hindernisse je Job (`admissionBlocks`).
- `workspace`: Stammordner, Projektzahlen nach Status, letzter Scan/Fehler, Scan läuft, offene
  Dateikonflikte, offene Anweisungsvorschläge, laufende KI-Ausarbeitungen, GitHub verfügbar.
- `problems`: deutsche Hinweise, die Aufmerksamkeit brauchen.

## Befehle (`ServiceRequest`) und Antworten

Ergebnis ohne eigene Angabe: `.result(.done(String?))`.

### Dienst

| Befehl | Antwort | UI |
|---|---|---|
| `ping` | `pong(ServiceVersion)` | Erreichbarkeit |
| `health` | `health(ServiceHealth)` | Version, Laufzeit, Pause |
| `statusSummary` | `statusSummary(…)` | Menüleiste, Dashboard |
| `pause` / `resume` | `runState(…)` | „Dienst pausieren/fortsetzen“. Pause stoppt nur neue Agentenstarts; laufende Jobs, Freigaben, Sync und Scanner laufen weiter. Übersteht Neustarts. |
| `stop` | `stopping` | „Dienst beenden“ (launchd startet ihn bei der nächsten Anfrage/Anmeldung neu) |
| `serviceSettings` / `updateServiceSettings(ServiceSettings)` | `result(.serviceSettings)` | Intervalle, Leerlauf-Ruhezustand während Agentenläufen verhindern (Standard aus), iPhone-KI-Aufträge automatisch ausführen. Werte werden auf sinnvolle Mindestwerte begrenzt (`clamped`). |

### iCloud

| Befehl | Antwort |
|---|---|
| `syncNow` | `result(.syncFinished(SyncRunInfo))` oder `notAvailable(.cloudSync)` |
| `resolveSyncConflict(conflictId:choice:)` | Konflikt-ID aus der Tabelle `sync_conflicts`; `keepLocal`, `acceptRemote`, `merged(Data)` |
| `acknowledgeAccountChange(uploadAllLocalData:)` | nach Accountwechsel fortfahren |
| `recreateCloudZone` | nach gelöschten iCloud-Daten alles neu hochladen |

### Stammordner, Scanner, Projekte (E1–E3)

| Befehl | Antwort | Hinweis |
|---|---|---|
| `rootFolders` | `result(.rootFolders(RootFolderState))` | `suggestion` = `~/Developer`, falls vorhanden; nie automatisch übernommen |
| `addRootFolder(path:)` / `removeRootFolder(path:)` | `result(.rootFolders)` | absoluter Pfad aus `NSOpenPanel`; Entfernen löscht keine Projekte |
| `refreshScanner` | `result(.scanFinished(ScanInfo))`, ohne Stammordner `notAvailable(.repositoryScanner)` | |
| `relinkCandidates(projectId:)` | `result(.paths([String]))` | |
| `relinkProject(projectId:path:allowDifferentRepository:)` | | Re-Link-Workflow |
| `reconcileProject(projectId:)` | | Markdown sofort abgleichen |
| `submitProjectSetup(ProjectSetupCommand)` | | Projekt anlegen/verknüpfen wie vom iPhone; `git init` nur mit `gitInitConsent` |
| `resolveFileConflict(conflictId:resolution:)` | | Request-Datei- oder GitHub-Konflikt |

### AGENTS.md / CLAUDE.md (G)

Vorschläge entstehen beim ersten Scan, für neue Projekte und auf Anforderung; sie werden **nie**
ohne Zustimmung geschrieben.

| Befehl | Antwort |
|---|---|
| `instructionProposals(projectId:)` | `result(.instructionProposals([InstructionProposalInfo]))` mit Diff je Datei und Warnungen |
| `proposeInstructions(projectId:createClaudeFileIfMissing:)` | neu berechnet |
| `applyInstructionProposal(proposalId:)` | schreibt atomar; veraltete Vorschläge werden abgelehnt |
| `rejectInstructionProposal(proposalId:)` | verwirft |

### Ordnerstruktur (F2)

| Befehl | Antwort |
|---|---|
| `previewFolderMigration(projectId:layout:)` | `result(.folderMigrationPlan(…))` mit Verschiebungen, Kollisionen, AGENTS.md-Diff |
| `applyFolderMigration(planId:)` / `discardFolderMigration(planId:)` | nur bei `isApplicable` anwenden |

### Agenten (J1)

`redetectAgents` → `result(.agents([AgentProviderSummary]))`. Der Dienst erkennt außerdem beim
Start, alle 30 min und vor jedem Start (Orchestrator) selbst.

### Jobs und Freigaben (J2a, J3, K1–K3, L3)

| Befehl | Antwort |
|---|---|
| `requestJob(JobRequestCommand)` | `result(.job(JobInfo))`; `idempotencyKey` einmal pro Dialog erzeugen, Wiederholung liefert denselben Job (`wasCreated == false`). Modell/Effort `nil` = Projekt-/Globalstandard. Unzulässige Kombination → `failure` mit Begründung. |
| `jobStatus(jobId:)` | `result(.jobStatus(JobStatusInfo))`: Zeitplanzeile, Start-Hindernis, verpasster Termin, Kontingent, Worktree/Branch/PID |
| `answerApproval(approvalId:decision:message:)` | Entscheidung wird synchronisiert und wie eine iPhone-Entscheidung an den Agenten weitergegeben; zweite Antwort → `failure`. Seit Protokoll 4: gekürzte Vorschau (`allowRequiresHostReview`) läuft über `answerApprovalOnHost` ohne Volltext-Bestätigung, „Erlauben“ also → `failure` |
| `fullApprovalPreview(approvalId:)` (seit 4) | `result(.approvalPreview(ApprovalPreviewInfo))`: vollständiger redigierter Text einer gekürzten Vorschau, nur hostlokal aus der laufenden Sitzung (nie synchronisiert); ohne Sitzung `fullText == nil` mit Hinweis (nur Ablehnen) |
| `answerApprovalOnHost(approvalId:decision:message:fullTextConfirmed:)` (seit 4) | SR-SEC-08: Entscheidung am ausführenden Mac. Bei gekürzter Vorschau ist `allow` nur mit `fullTextConfirmed == true` möglich – die UI zeigt vorher `truncationNotice`, den Volltext und lässt das Lesen ausdrücklich bestätigen. Entscheidung wird synchronisiert und sofort weitergegeben |
| `cancelJob`, `pauseJob`, `resumeJob`, `reprioritizeJob` | `result(.job)` |
| `retryJob(jobId:idempotencyKey:)` | `result(.job)` (neuer Job) |
| `replaceJobConfiguration(jobId:model:effort:)` | explizite neue Modell-/Effort-Wahl (A40); bei `needs_configuration` zurück in die Warteschlange |
| `resolveMissedRun(jobId:runNow:)` | Nachholregel `ask` |
| `setExpectedQuotaReset(jobId:at:)` | erwarteter Kontingent-Reset |
| `terminateOrphanedProcess(jobId:)` | verwaisten Agentenprozess nach Dienstneustart beenden |
| `removeWorktree(jobId:)` | Worktree entfernen (Branch bleibt) |

### Review und Integration (M1)

| Befehl | Antwort |
|---|---|
| `reviewDetails(reviewId:)` | `result(.reviewDetails(ReviewDetailsInfo))`: Repository-/Worktree-Pfad, Branch, Basis/Head, Commits, Dateien, Agentenzusammenfassung, Integrationsprobleme, seit Protokoll 4 `excludedSecretPaths` (nicht committete, geheimnisverdächtige Agentenausgaben, ADR-0026; optional). Diff-Inhalte liest die UI selbst mit `git diff <base>..<head>` im Repository – über den gehärteten `GitClient` (`ExecutableLocator`, Hooks/fsmonitor/Filter/externe Diffs/Textconv aus, SR-SEC-10/13). |
| `approveReview`, `requestChanges`, `rejectReview` | |
| `integrateReview(reviewId:)` | `result(.integration(IntegrationInfo))`; Konflikte → `failure` mit Dateiliste, Repository unverändert |
| `markDone(workItemId:)` | nur nach Integration; Request-Datei wandert sofort in den done-Ordner |

### GitHub (M3, ADR-0016)

`gitHubAvailability` → `result(.gitHubAvailability)`; `setGitHubEnabled`, `gitHubIssues(projectId:state:)`
→ `result(.gitHubIssues)`, `linkGitHubIssue`, `importGitHubIssue` → `result(.workItem(WorkItemID))`,
`exportToGitHub`, `resolveGitHubDivergence(conflictId:acceptGitHub:)`, `syncGitHub(projectId:)`.
Ohne angemeldetes `gh` → `failure` mit Einrichtungshinweis.

### KI-Ausarbeitung mit Repo-Kontext (H4)

| Befehl | Antwort |
|---|---|
| `requestMacAIElaboration(MacAIElaborationCommand)` | `result(.macAIElaboration(info))` sofort mit `pending`; läuft im Hintergrund |
| `macAIElaborationStatus(requestId:)` | `result(.macAIElaboration(info))` mit Kontext-Manifest (enthaltene Dateien, Ausschlüsse mit Grund, geschätzte Tokens), Entwurfsversion oder deutscher Fehlermeldung |

Der API-Schlüssel kommt aus dem Mac-Schlüsselbund: Dienst `SoftwareRegisseur.ProviderKeys`, Konto
`<anbieter>.text` (z. B. `openai.text`), Zugriffsgruppe `$(SR_KEYCHAIN_SHARED_GROUP)`
(Info.plist `SRKeychainSharedGroup`). Die Mac-UI muss Schlüssel mit derselben Gruppe speichern
(`ProviderKeyService` aus `SoftwareRegisseurAppCore`). Das Ergebnis ist eine synchronisierte
`DraftVersion`; übernommen wird nur nach Bestätigung in der UI.

## Seit Protokoll 3: Schreibwege der Mac-UI

Alle Befehle laufen als `EventActor.user(<Geräte-ID dieses Macs>)` über die Repositories (Revision,
Verlaufseintrag und Sync-Outbox in einer Transaktion, ADR-0019) und werden dadurch synchronisiert. Request-
und ADR-Dateien folgen über den Markdown-Abgleich; Software Regisseur committet nie (ADR-0024).

### Aufgaben (H1, F1, ADR-0012, ADR-0018)

| Befehl | Antwort | Regeln |
|---|---|---|
| `createWorkItem(CreateWorkItemCommand)` | `result(.workItemSaved(WorkItemSavedInfo))` | ohne Projekt → Inbox (`inbox`), sonst `open`. `workItemId` erzeugt die UI einmal pro Dialog; Wiederholung liefert `wasCreated == false`. Menüleiste „Neue Notiz“. |
| `updateWorkItem(WorkItemEditCommand)` | `workItemSaved` | Titel, Markdown-Inhalt, Priorität, Labels, Abhängigkeiten (UUIDs, nicht auf sich selbst). Optimistische Revision: veraltet → `failure("… inzwischen geändert. Bitte neu laden …")`. |
| `changeWorkItemStatus(workItemId:expectedRevision:status:)` | `workItemSaved` | Zustandsmaschine; abgelehnt bei aktivem Job oder Sperre (ADR-0012) und für Dienst-Status (`WorkItemCommandRules.hostOnlyStatuses`). `integrated → done` läuft wie `markDone` (Datei in den done-Ordner). |
| `assignWorkItem(workItemId:expectedRevision:projectId:)` | `workItemSaved` | `nil` = zurück in die Inbox. Nur ohne menschenlesbare ID und ohne aktiven Job; `inbox ↔ open` wie am iPhone. |
| `setWorkItemArchived(workItemId:expectedRevision:archived:)` | `workItemSaved` | kein Statuswechsel |
| `reclassifyWorkItem(workItemId:expectedRevision:type:)` | `workItemSaved` | nur bevor der Mac eine Nummer vergeben hat; sonst deutsche Erklärung (duplizieren) |
| `duplicateWorkItem(workItemId:newWorkItemId:)` | `workItemSaved` | neue UUID, ohne Nummer, Jobs, Verlauf; idempotent über `newWorkItemId` |
| `deleteWorkItem(workItemId:expectedRevision:)` | `done` | nur, wenn nie Datei, Nummer, Job oder GitHub-Issue entstand; sonst `failure` mit Hinweis „archivieren“ |

### KI-Entwürfe (H3/H4)

| Befehl | Antwort | Regeln |
|---|---|---|
| `acceptDraftVersion(draftId:contentIndex:expectedRevision:)` | `workItemSaved` | Titel, Inhalt, Priorität aus dem Entwurf (wie `DraftAdopter` am iPhone); `contentIndex == nil` für reine Textversionen. Originalnotiz/Transkript bleiben. **Startet nie einen Agenten.** |
| `rejectDraftVersion(draftId:)` | `done` | synchronisierter Verlaufseintrag `comment` mit `DraftDecisionEvent`-Schlüsseln; Aufgabe unverändert |

### ADRs (F4, ADR-0018, ADR-0024)

| Befehl | Antwort | Regeln |
|---|---|---|
| `createADR(CreateADRCommand)` | `result(.adrCreated(ADRCreatedInfo))` | Nummer vom Mac (`allocateADRNumber`, eigener Nummernkreis), Text aus `<ADR-Ordner>/TEMPLATE.md` (sonst Standardvorlage), Status `proposed`, atomar neu geschrieben (nie überschrieben), danach eingelesen, nicht committet |
| `changeADRStatus(adrId:expectedRevision:status:supersededBy:)` | `done` | nur ausdrücklich: `proposed → accepted/deprecated`, `accepted → deprecated/superseded`. Ändert nur Frontmatter-Zeilen: `status` (bei Ersetzen `superseded by NNNN`) und im ersetzenden ADR `supersedes`. Dateien ohne Frontmatter → `failure` (im Editor ändern). Nicht committet. |

### Einstellungen (F2, J1, J2a, L1, M3, ADR-0006)

| Befehl | Antwort | Regeln |
|---|---|---|
| `updateProjectSettings(ProjectSettingsCommand)` | `done` | Standardagent, Modell/Stufe je Agent (gegen die Fähigkeitsmatrix des ausführenden Macs, unzulässig → `failure`, kein stiller Fallback), Integrationsstrategie, Parallelität (1–16), projektweite Sperre, Review, Agentenanweisungen. Optimistische Revision. Ordnerstruktur weiter über `previewFolderMigration`. Gilt für neue Jobs. |
| `gitHubProjectState(projectId:)` | `result(.gitHubProjectState(…))` | aktiv ja/nein, `owner/name` oder Erklärung |
| `updateGlobalSettings(GlobalSettingsCommand)` | `done` | synchronisierte `GlobalSettings` (Ordnerstruktur, Standardagent, Arbeitsbereich-Standards); Revision 0 = erstmals speichern |
| `setGlobalModelPreference(AgentModelChoice)` | `done` | globale Modell-/Stufenwahl, geprüft; ohne Wahl → entfernt |
| `setAgentExecutablePath(providerId:path:)` | `result(.serviceSettings)` | absoluter Pfad zu einer ausführbaren Datei oder `nil` (automatische Suche). Wirkt ohne Neustart: Anbieter werden neu aufgebaut und neu erkannt. `updateServiceSettings` lässt die Pfade unverändert. |

`ServiceSettings.agentExecutablePaths` (Rohwert der `ProviderID` → Pfad) ist neu; fehlende Felder älterer
Clients/Speicherstände werden mit Standardwerten dekodiert.

### Datenlöschung (Q1, A34)

Der Export bleibt im UI-Prozess auf der Nur-Lese-Datenbank (`DataExporter`). Gelöscht wird nur im Dienst.

| Befehl | Antwort | Regeln |
|---|---|---|
| `prepareLocalDeletion(LocalDeletionKind)` | `result(.localDeletionPreview(…))` | `localDatabase`, `apiKeys`, `everythingLocal`. Liste der Einträge, was erhalten bleibt, Folgen, Ablaufzeit, Bestätigungstoken. Nur die neueste Vorschau gilt. Geschützt: alle bekannten Repository-, Stammordner- und Worktree-Pfade; Ordner mit Git-Arbeitskopie werden nie gelöscht. |
| `executeLocalDeletion(planId:confirmationToken:)` | `result(.localDeletionReport(…))` | nur mit dem Token dieser Vorschau, nicht während Agenten laufen. Bei Datenbankumfang: Schleifen, Poller und Beobachter anhalten, Datenbank schließen, löschen, leer neu öffnen und den Dienst ohne Prozessneustart neu aufbauen (neue Host-Kennung, Stammordner neu bestätigen). Die UI schließt vorher ihre Nur-Lese-Verbindung und öffnet danach neu (`databaseReopened`). |
| `prepareCloudDeletion` | `result(.cloudDeletionPreview(…))` | ohne CloudKit `notAvailable(.cloudSync)` |
| `confirmCloudDeletion(planId:confirmationToken:)` | `done` | `SyncCoordinator.deleteCloudData`; lokale Daten bleiben, Sync pausiert |
| `retryCloudDeletion` | `done` | noch nicht bestätigte Löschung erneut senden |

`SyncSummary.cloudDataDeletion` (`deleted` / `pending`) zeigt der UI den Zustand: `deleted` →
„Wieder mit iCloud synchronisieren“ (`recreateCloudZone`), `pending` → `retryCloudDeletion`.

### Sync-Konflikte

`resolveSyncConflict(conflictId:choice: .merged(Data))` nimmt den vom Benutzer zusammengeführten Datensatz im
gespeicherten Payload-Format (`SyncPayloadCodec`). Die Mac-UI bietet dafür bei Aufgaben (Titel, Inhalt,
Transkript) und ADRs (Titel, Abschnitte) einen Editor mit Vorfahr (falls bekannt), Stand dieses Macs und
iCloud-Stand.

## Seit Protokoll 4: „Mit KI besprechen“ am Mac (H3)

Das Gespräch führt die Mac-UI selbst mit dem Text-KI-Anbieter (Schlüssel im Mac-Schlüsselbund); jede Nachricht
zeigt vorher ihr Kontext-Manifest. Gespeichert wird nur über den Dienst, als `EventActor.user(<Geräte-ID dieses
Macs>)` und über die Repositories – damit synchronisiert und am iPhone sichtbar. Beide Befehle legen nie einen Job an
und starten nie einen Agenten.

| Befehl | Antwort | Regeln |
|---|---|---|
| `saveConversation(AIConversation)` | `result(.conversationSaved(ConversationSavedInfo))` | Upsert über die Gesprächs-ID (UI erzeugt sie einmal je Gespräch) nach **jedem** Zug: Nachrichten, Kontextumfang (`itemOnly` → `project` → `repositoryFiles`, nur erweitert), Nutzung. Nachrichten werden nur angehängt: kürzerer Stand mit gleichem Anfang (veraltete Wiederholung) ändert nichts, abweichender Verlauf oder andere Aufgabe → `failure`. Ein vermerkter `proposedDraftVersion` geht nicht verloren. Scheitert das Speichern, sendet die UI beim nächsten Zug den ganzen Stand erneut. |
| `appendConversationDraft(ConversationDraftCommand)` | `result(.conversationDraft(ConversationDraftInfo))` | Vorschlag (`DraftContent`, Anbieter, Modell, `conversationId`, Nutzung) als neue `DraftVersion` mit Quelle `ai` und Kanal `conversation`; Originalnotiz und Transkript werden vorher als eigene Versionen festgehalten, falls geändert (H3: getrennt versioniert). Idempotent über `draftId` (UI erzeugt sie einmal je Vorschlag). Das Gespräch erhält `proposedDraftVersion`. Nur mit `accept == true` (nach ausdrücklicher Bestätigung) übernimmt der Dienst den Entwurf wie `acceptDraftVersion` (Titel, Inhalt, Priorität; Originalnotiz, Transkript, Labels, Abhängigkeiten bleiben), markiert ihn als übernommen und schreibt einen Verlaufseintrag `comment` mit `DraftDecisionEvent.accepted`, Kanal und Gesprächs-ID. |

**Revisionsprüfung:** Mit `accept` wird `expectedRevision` geprüft, **bevor** etwas geschrieben wird – veraltet →
`failure("… inzwischen geändert. Bitte neu laden …")`, kein Entwurf, Aufgabe unverändert. Die Repositories öffnen je
Aufruf eine eigene Transaktion (Entwurf anlegen, Aufgabe ändern + `edited`-Eintrag, Entwurf als übernommen markieren,
Entscheidungseintrag); ein gemeinsames Transaktions-API der Persistenz gibt es noch nicht. Ändert sich die Aufgabe genau
zwischen Anlegen und Übernehmen, bleibt der Entwurf als nicht übernommene Version stehen und der Befehl meldet den
Konflikt; dieselbe `draftId` mit neuer Revision übernimmt ihn dann.

**Gekürzte Freigaben (SR-SEC-08)** sind ebenfalls Teil von Protokoll 4: `fullApprovalPreview`,
`answerApprovalOnHost` und `ServiceResult.approvalPreview` (siehe „Jobs und Freigaben“).

**„Verwerfen“** in der Mac-UI: Das Gespräch bleibt gespeichert, es entsteht kein Entwurf und kein Verlaufseintrag (wie
am iPhone). Bereits gespeicherte, nicht übernommene Gesprächsentwürfe werden wie jeder Entwurf mit
`rejectDraftVersion` verworfen.

## Versionierung

- Neue Befehle oder Ergebnisarten, geänderte Felder oder Bedeutungen → `IPCProtocol.version` erhöhen
  und diese Datei aktualisieren. Bleibt die Änderung additiv, bleibt `minimumSupportedVersion` stehen;
  sonst ebenfalls anheben.
- Der Test `everyRequestKindHasASample` erzwingt für jeden neuen Befehl ein Rundreise-Beispiel.
