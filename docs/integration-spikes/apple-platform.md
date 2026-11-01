# Integrations-Spike: Apple-Plattform (M0)

| Feld | Wert |
|---|---|
| Datum | 2026-10-30 |
| Recherche-Host | macOS 27.0 (Build 26A428), Xcode 27.0 (27A266a) |
| Zielplattformen | iOS 26.0 / macOS 26.0 (ADR-0013), Swift 6.4 |
| Bezug | Pflichtenheft C, D, H, I, N, Q; ADR-0002, 0003, 0008, 0009, 0011, 0013, 0017 |
| Art | Reine Dokumentationsrecherche. **Kein Code gebaut, kein Gerät getestet.** Alle Punkte mit Status „Spike“ müssen auf echter Hardware nachgewiesen werden, bevor sie als erfüllt gelten (AGENTS.md Regel 10). |

**Quellen.** Ausschließlich offizielle Dokumentation: developer.apple.com (gelesen über die DocC-JSON-Darstellung derselben Seiten), die lokale Apple-Manpage `launchd.plist(5)` von macOS 27, sparkle-project.org und github.com/groue/GRDB.swift. Die Quell-URLs sind die menschenlesbaren Seiten.

**Statuslegende.** **belegt** = wörtlich/sinngemäß in offizieller Doku; **abgeleitet** = logische Folgerung aus belegten Aussagen, nicht wörtlich dokumentiert; **Spike** = nicht dokumentiert oder widersprüchlich, muss real getestet werden.

---

## 1. Lokale Persistenz: SwiftData vs. GRDB (SQLite)

### 1.1 Fakten

| Kriterium | SwiftData | GRDB 7 (SQLite) | Status / Quelle |
|---|---|---|---|
| Versioniertes Schema, Migrationen | `VersionedSchema` + `SchemaMigrationPlan` mit `MigrationStage` (iOS 17 / macOS 14) | `DatabaseMigrator.registerMigration(_:)`, benannte, geordnete SQL-Migrationen; Migrationen laufen mit verzögerten Foreign-Key-Checks | belegt: https://developer.apple.com/documentation/swiftdata/versionedschema, https://developer.apple.com/documentation/swiftdata/schemamigrationplan, https://github.com/groue/GRDB.swift/blob/master/GRDB/Documentation.docc/Migrations.md |
| Transaktionen | `ModelContext.transaction(block:)` schreibt nach Ende des Blocks alle pending Änderungen | `dbPool.write { }` / `writeInTransaction`, Savepoints; schreibende Transaktionen werden als `IMMEDIATE` geöffnet | belegt: https://developer.apple.com/documentation/swiftdata/modelcontext/transaction(block:), https://github.com/groue/GRDB.swift/blob/master/GRDB/Documentation.docc/Transactions.md, https://github.com/groue/GRDB.swift/blob/master/GRDB/Documentation.docc/DatabaseSharing.md |
| Eingebaute CloudKit-Sync | Nutzt intern `NSPersistentCloudKitContainer`, benötigt Background-Mode „Remote notifications“; CloudKit erzwingt kein `unique`, alle Relationships müssen optional sein, Schema in Production nur additiv | keine – Sync ist komplett eigene Schicht | belegt: https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices |
| Abschalten der eingebauten Sync (für eigene `CKSyncEngine`-Schicht) | `ModelConfiguration.CloudKitDatabase.none` | n/a | belegt: https://developer.apple.com/documentation/swiftdata/modelconfiguration/cloudkitdatabase-swift.struct |
| Änderungsverfolgung (für Outbox/Reconciliation) | SwiftData History (`fetchHistory`, Token, Author, Tombstones via `.preserveValueOnDeletion`) – ausdrücklich auch für Änderungen „by another process“ | `DatabaseRegionObservation`/`ValueObservation` innerhalb eines Prozesses; **erkennt keine Änderungen anderer Prozesse** – dafür Darwin-Notifications/`NSFileCoordinator` | belegt: https://developer.apple.com/documentation/swiftdata/fetching-and-filtering-time-based-model-changes, https://github.com/groue/GRDB.swift/blob/master/GRDB/Documentation.docc/DatabaseSharing.md |
| Zwei Prozesse auf einer DB | App-Group-Container per `ModelConfiguration.GroupContainer`; **keine offizielle Anleitung für mehrere schreibende Prozesse** gefunden | Eigener Leitfaden „Sharing a Database“: `DatabasePool` (WAL), DB-Erzeugung mit `NSFileCoordinator` schützen, `busyMode = .timeout`, Persistent-WAL für Read-only-Verbindungen. GRDB warnt selbst: „Always consider sharing plain files, or any other inter-process communication technique, before sharing an SQLite database.“ | belegt (GRDB), Spike (SwiftData): https://developer.apple.com/documentation/swiftdata/modelconfiguration/groupcontainer-swift.struct, https://github.com/groue/GRDB.swift/blob/master/GRDB/Documentation.docc/DatabaseSharing.md |
| iOS-Risiko bei geteilter DB | – | `0xDEAD10CC` bei gehaltenen SQLite-Locks während Suspend; Gegenmittel experimentell (`observesSuspensionNotifications`) | belegt: GRDB DatabaseSharing.md (s. o.) |
| Eigener Storage | `DataStore`-Protokoll erst ab iOS 18 / macOS 15 | SQL direkt | belegt: https://developer.apple.com/documentation/swiftdata/datastore |
| Version / Anforderungen | Systemframework | Letztes Release **v7.11.1 (2026-06-18)**; Requirements „Swift 6.1+ / Xcode 16.3+“ | belegt: https://github.com/groue/GRDB.swift/releases, https://github.com/groue/GRDB.swift/blob/master/README.md |

### 1.2 Empfehlung: **GRDB 7 (SQLite, WAL)**

1. **Sync ist ohnehin Eigenbau.** Pflichtenheft C3/N3 verlangt kontrollierbares `fetchChanges`/`sendChanges`, Outbox/Inbox, Operation-IDs, Tombstones. SwiftDatas eingebaute Sync (NSPersistentCloudKitContainer) bietet diese Kontrolle nicht und muss mit `.none` deaktiviert werden (belegt, s. o.). Damit entfällt SwiftDatas Hauptvorteil; übrig bleibt ein ORM, dessen Mapping auf `CKRecord`, Change-Tags und Outbox-Zeilen wir trotzdem selbst bauen.
2. **Explizites Schema und SQL-Transaktionen.** Outbox/Inbox, idempotente Operationen und `UNIQUE`-Constraints (z. B. Operation-ID für Replay-Schutz) sind in SQL direkt ausdrückbar; GRDB öffnet Schreibtransaktionen als `IMMEDIATE` (belegt). Migrationen sind benannte, testbare Schritte.
3. **Mehrprozess-Fall dokumentiert.** Nur GRDB hat eine offizielle Anleitung für WAL/App-Group/Sandbox mit mehreren Prozessen (belegt). Für SwiftData fehlt sie (Spike-Risiko).
4. **Testbarkeit.** In-Memory-DB bzw. temporäre Datei pro Test; Migrationstests „Version n → n+1“ mit echten SQL-Dumps. (abgeleitet)
5. **Swift 6.** GRDB 7 verlangt Swift 6.1+ (belegt); `ModelContext` ist nicht `Sendable` und erzwingt `@ModelActor`-Konstrukte (allgemein bekannt, hier nicht separat belegt).

**Architekturfolgerung für macOS (abgeleitet aus GRDB-Leitfaden + ADR-0002/0003):**
- **Der Agent Service ist der einzige Schreiber** der Mac-Datenbank und der **einzige Besitzer der `CKSyncEngine`** auf dem Mac. Die UI liest/ändert über XPC. Zwei `CKSyncEngine`-Instanzen in zwei Prozessen auf demselben State wären ein Korrektheitsrisiko (State-Serialisierung muss „alongside any changes fetched“ persistiert werden, s. §2).
- Optional darf die UI eine **Read-only-`DatabasePool`**-Verbindung für schnelle Listen öffnen (Persistent-WAL nötig, belegt), Änderungen aber nur per XPC anstoßen. Cross-Process-Invalidierung über Darwin-Notification (`CFNotificationCenterGetDarwinNotifyCenter`) – laut GRDB nötig, weil Observation andere Prozesse nicht sieht.
- DB-Datei im **App-Group-Container** `~/Library/Group Containers/<TEAMID>.<name>/`, damit eine eventuell sandboxed UI lesen darf (siehe §5).
- **iOS:** DB im **eigenen App-Container**, nicht im App-Group-Container, solange keine Extension mitliest → vermeidet `0xDEAD10CC` (abgeleitet).

Entscheidung braucht laut AGENTS.md Regel 9 einen **neuen ADR** (nächste freie Nummer). ADR-0013 nennt SwiftData als „benötigte API“ – das ist mit GRDB nicht falsch (nur nicht genutzt), sollte im neuen ADR aber klargestellt werden.

---

## 2. CKSyncEngine

| Thema | Befund | Status / Quelle |
|---|---|---|
| Verfügbarkeit | iOS 17.0, macOS 14.0 (damit in iOS 26 / macOS 26 vorhanden) | belegt: https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5 |
| Entitlements | „`CKSyncEngine` requires the CloudKit and Remote notifications entitlements.“ | belegt: ebd. |
| Datenbanken / Zonen | Für Private und Shared DB; **nicht** für die Public DB („Don’t use `CKSyncEngine` to sync your app’s public database.“). Custom Zones nur in der Private DB; Custom Zones erlauben atomare Mehrfach-Writes; `CKRecord.Reference` nicht zonenübergreifend | belegt: ebd.; https://developer.apple.com/documentation/cloudkit/ckrecordzone |
| Automatik | Standardmäßig plant die Engine Sync selbst; Zeitpunkt „indeterminate“ (Akku, Netz, iCloud-Login) | belegt: cksyncengine-5sie5 |
| Silent Push | Engine sucht/erstellt eine `CKDatabaseSubscription` und empfängt **stille** Notifications; bei Empfang plant sie einen Fetch | belegt: cksyncengine-5sie5; https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/configuration/subscriptionid |
| Manuell | `fetchChanges(_:)` / `sendChanges(_:)` (async throws); kehren erst zurück, nachdem der Delegate alle zugehörigen Events verarbeitet hat; `FetchChangesOptions(scope:operationGroup:)`, `prioritizedZoneIDs` | belegt: https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/fetchchanges(_:), https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/sendchanges(_:), https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/fetchchangesoptions |
| Automatik abschalten | `Configuration.automaticallySync = false` → nur noch `fetchChanges`/`sendChanges`, z. B. „sync at a specific time of day“ oder deterministische Tests. Default `true` | belegt: https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/configuration/automaticallysync |
| State-Serialisierung | Engine persistiert ihren State **nicht** selbst; `Event.StateUpdate` liefert `stateSerialization`, das „alongside any changes fetched prior to receiving this state“ gespeichert werden muss; beim Start an `Configuration(database:stateSerialization:delegate:)` übergeben | belegt: https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/event/stateupdate, https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/configuration/init(database:stateserialization:delegate:) |
| Senden | Pending Changes über `state.add(pendingRecordZoneChanges:)`; Delegate liefert Batches in `nextRecordZoneChangeBatch`; **max. 250 Records pro Request** (Saves + Deletes), sonst `limitExceeded`; `RecordZoneChangeBatch(pendingChanges:recordProvider:)` hält das Limit ein; ein `sentRecordZoneChanges`-Event pro Batch | belegt: cksyncengine-5sie5 |
| Fehler, die die Engine selbst wiederholt | `notAuthenticated`, `accountTemporarilyUnavailable`, `networkFailure`, `networkUnavailable`, `requestRateLimited` (respektiert retry-after), `serviceUnavailable`, `zoneBusy` | belegt: cksyncengine-5sie5 |
| Konflikte | `serverRecordChanged` muss die App selbst lösen. `userInfo` enthält Client-, Server- und Ancestor-Record; **in den Server-Record mergen** und erneut speichern, sonst erneuter Konflikt (alter Change-Tag) | belegt: cksyncengine-5sie5; https://developer.apple.com/documentation/cloudkit/ckerror/code/serverrecordchanged |
| Account-Wechsel | Engine bleibt ohne Account dormant; `Event.accountChange` → App muss lokale Daten anpassen | belegt: cksyncengine-5sie5 |
| Record-Größe | Nicht-Asset-Daten eines Records max. 1 MB | belegt: https://developer.apple.com/documentation/cloudkit/ckrecord |
| Beispielprojekt | https://github.com/apple/sample-cloudkit-sync-engine | belegt (verlinkt aus cksyncengine-5sie5) |

### 2.1 Polling-only auf dem macOS-Dienst (ADR-0011)

- **Empfehlung (abgeleitet):** Im Agent Service `automaticallySync = false`; eigener Scheduler ruft `fetchChanges()` periodisch (z. B. Basisintervall + Jitter, Backoff bei Fehlern), bei Netzwiederkehr, nach Aufwachen und bei „Jetzt synchronisieren“; `sendChanges()` nach jedem lokalen Commit (debounced). Damit ist das Verhalten deterministisch und testbar, wie von C3/N3 gefordert.
- **Spike 1 (Push-Abhängigkeit im Helper):** Die Doku verlangt das Remote-Notifications-Entitlement auch bei manuellem Betrieb. Ob ein **LaunchAgent ohne `NSApplication`** (kein `registerForRemoteNotifications()`, das unter macOS an `NSApplication` hängt – https://developer.apple.com/documentation/appkit/nsapplication/registerforremotenotifications()) die Engine fehlerfrei initialisiert und ob die Engine trotz fehlender Push-Zustellung korrekt manuell fetcht, ist **nicht dokumentiert**. Testen: Engine im Helper, `automaticallySync=false`, Änderungen vom iPhone, nur Polling.
- **Spike 2 (Entitlements im Helper):** CloudKit- und APS-Entitlements sind provisioning-profile-pflichtig. Ein Standalone-Executable kann kein Profil einbetten; Apple empfiehlt eine **app-ähnliche Bundle-Struktur** („Wrap a daemon in an app-like structure“) (belegt: https://developer.apple.com/documentation/xcode/signing-a-daemon-with-a-restricted-entitlement). Für Developer-ID sind „iCloud: CloudKit“ und „Push notifications“ als Capability verfügbar (belegt: https://developer.apple.com/help/account/reference/supported-capabilities-macos). → Agent Service als `.app`-Bundle innerhalb der Haupt-App bauen.
- **Quoten:** Eine konkrete Polling-Quote veröffentlicht Apple in den gelesenen Seiten nicht; nur dass `requestRateLimited` mit retry-after kommt und die Engine das respektiert (belegt). Polling-Intervall daher konservativ wählen und Fehlerraten messen (Spike).
- **iOS:** `automaticallySync = true` lassen (stille Pushes optimieren opportunistisch), plus explizit `fetchChanges()` bei Start/Foreground/Pull-to-Refresh und `sendChanges()` nach Erfassung (N3). Stille Pushes brauchen **keine Nutzerberechtigung**: Ohne `requestAuthorization` „the system delivers all remote notifications to your app silently“ (belegt: https://developer.apple.com/documentation/uikit/uiapplication/registerforremotenotifications()). Das ist mit ADR-0011 vereinbar, muss aber laut N3 in Doku/UI als „interne Synchronisation, keine Mitteilungen“ benannt werden.

---

## 3. macOS-Hintergrunddienst: SMAppService, launchd, XPC

### 3.1 SMAppService-Varianten

| Variante | Ablageort im Bundle | Verhalten bei `register()` | Quelle |
|---|---|---|---|
| `agent(plistName:)` | `Contents/Library/LaunchAgents/<name>.plist` | LaunchAgent wird sofort gebootstrappt und bei jedem Login erneut; pro Benutzer einmal registrieren | belegt: https://developer.apple.com/documentation/servicemanagement/smappservice/agent(plistname:), https://developer.apple.com/documentation/servicemanagement/smappservice/register() |
| `loginItem(identifier:)` | `Contents/Library/LoginItems/` (Helper-App) | startet sofort und bei Login; Neustart bei Crash/Exit ≠ 0 | belegt: https://developer.apple.com/documentation/servicemanagement/smappservice/loginitem(identifier:), register() |
| `daemon(plistName:)` | `Contents/Library/LaunchDaemons/` | erst nach Admin-Freigabe, läuft als root | belegt: https://developer.apple.com/documentation/servicemanagement/smappservice/daemon(plistname:) |
| `mainApp` | – | Haupt-App startet bei Login | belegt: register() |

- Status: `notRegistered`, `enabled`, `requiresApproval`, `notFound`; `openSystemSettingsLoginItems()` öffnet die Einstellungen; Fehler `kSMErrorLaunchDeniedByUser` bei fehlender Freigabe (belegt: https://developer.apple.com/documentation/servicemanagement/smappservice, https://developer.apple.com/documentation/servicemanagement/smappservice/status-swift.enum).
- Vorteil gebündelter Plists: im signierten Bundle, Nutzer sieht in „Systemeinstellungen > Allgemein > Anmeldeobjekte“, welche App den Dienst liefert (belegt: https://developer.apple.com/documentation/servicemanagement/updating-your-app-package-installer-to-use-the-new-service-management-api).
- launchd-Keys (belegt, `man launchd.plist`, macOS 27):
  - `BundleProgram` – app-bundle-relativer Pfad zum Executable, **nur für per SMAppService installierte Plists**.
  - `MachServices` – Mach-Service-Namen, die launchd on demand bereitstellt (für XPC).
  - `KeepAlive` – Default `false` (nur on demand); `true` hält den Job dauerhaft am Leben.
  - `ProcessType` – ohne Angabe „light resource limits … throttling its CPU usage and I/O bandwidth“; Werte `Background`, `Standard`, `Adaptive` (abhängig von XPC-Aktivität), `Interactive`.
  - `AssociatedBundleIdentifiers` – Zuordnung im Login-Items-UI (für Legacy-Plists).

**Empfehlung (abgeleitet):** `SMAppService.agent(plistName:)` mit gebündelter Plist (`BundleProgram` → `Contents/Library/Helpers/RegisseurAgent.app/Contents/MacOS/RegisseurAgent`, `MachServices` → ein Name, `KeepAlive` → true oder Dictionary-Bedingung, `ProcessType` → `Adaptive` oder `Standard` nach Messung). Begründung: deklarierter Mach-Service für XPC, kontrollierbares KeepAlive/ProcessType, kein root (C5). `loginItem` ist für eine sichtbare Helper-App gedacht; ob ein Login-Item automatisch einen Mach-Service erhält, ist in den gelesenen Seiten **nicht** dokumentiert. `daemon` scheidet aus (root, Admin-Freigabe, keine Data-Protection-Keychain – TN3137).

**Q4/Global-Regel:** Wenn vor `register()` ein eigener Erklärbildschirm gezeigt wird, gilt 5.1.1(iv): neutraler Button „Weiter“, kein „Später“, `register()` sofort auslösen; bei `requiresApproval` Erklärung plus `openSystemSettingsLoginItems()` statt erneutem Fragen.

### 3.2 XPC zwischen App und Agent

| Thema | Befund | Status / Quelle |
|---|---|---|
| Klassisch | `NSXPCConnection(machServiceName:options:)` verbindet zu einem LaunchAgent, dessen Name in der launchd.plist steht; Agent nutzt `NSXPCListener` | belegt: https://developer.apple.com/documentation/foundation/nsxpcconnection/init(machservicename:options:) |
| Peer-Prüfung (alt) | `NSXPCConnection.setCodeSigningRequirement(_:)` (macOS 13) – invalidiert Verbindung bei nicht passendem Peer; vor `resume()` aufrufen | belegt: https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:) |
| Swift-API | `XPCSession` / `XPCListener` (macOS 14); ab **macOS 26** Varianten mit `requirement: XPCPeerRequirement`; Listener verwirft Requests, die die Anforderung nicht erfüllen. `XPCPeerRequirement.isFromSameTeam(andMatchesSigningIdentifier:)`, `.hasEntitlement(_:)`, `.codeRequirement(_:)` | belegt: https://developer.apple.com/documentation/xpc/xpcsession, https://developer.apple.com/documentation/xpc/xpclistener, https://developer.apple.com/documentation/xpc/xpcpeerrequirement, https://developer.apple.com/documentation/xpc/xpclistener/init(service:targetqueue:options:requirement:incomingsessionhandler:) |
| Sandboxed App ↔ unsandboxed Agent | Über App Groups: Mach-/XPC-Servicename muss Format `<group identifier>.<unique name>` haben; „use app groups to enable IPC communication … between a sandboxed app and a nonsandboxed app“ | belegt: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups |

**Empfehlung:** `XPCListener`/`XPCSession` mit `XPCPeerRequirement.isFromSameTeam(andMatchesSigningIdentifier:)` in beide Richtungen (Deployment-Target macOS 26 erlaubt das). Mach-Service-Name **immer** mit App-Group-Präfix `<TEAMID>.<group>.agent` benennen – dann funktioniert er unverändert, falls die UI später sandboxed wird. Team-ID kommt aus `Config/Local.xcconfig` (ADR-0013). Protokoll versionieren (Handshake mit Build-Nummer), damit nach Updates Version-Mismatch erkannt wird.

### 3.3 Signierung und Einbettung

- Agent als **app-ähnliches Bundle** (wegen CloudKit/APS/Keychain-Access-Group-Entitlements mit Provisioning-Profile; belegt: signing-a-daemon-with-a-restricted-entitlement; TN3137 https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains: „These entitlements must be authorized by a provisioning profile. Your program needs an app-like bundle structure …“).
- Data-Protection-Keychain nur im User-Login-Kontext verfügbar – ein LaunchAgent ist User-Kontext, ein Daemon nicht (belegt: TN3137).
- Jedes ausführbare Teil mit Developer ID, Hardened Runtime und Secure Timestamp signieren (Notarisierungsvoraussetzung, §6).

### 3.4 Verhalten über App-Updates (ADR-0017)

- Belegt ist nur: `BundleProgram` ist bundle-relativ, Plist und Executable liegen im signierten Bundle.
- **Spike:** Ob nach Austausch des App-Bundles (Sparkle) der laufende Agent automatisch neu gestartet wird, ob die Registrierung den neuen Bundle-Inhalt verwendet und was nach Verschieben der App passiert, ist **nicht dokumentiert**. Vorschlag (abgeleitet): Agent erkennt per XPC-Handshake/Bundle-Version, dass er veraltet ist, pausiert Jobs (ADR-0007) und beendet sich; `KeepAlive` lässt launchd die neue Binary starten. Zusätzlich nach Update `status` prüfen und ggf. `unregister()`/`register()`.
- Sparkle-Hooks zum sauberen Pausieren: `updater(_:willInstallUpdate:)`, `updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)`, `updaterWillRelaunchApplication(_:)` (belegt: https://sparkle-project.org/documentation/api-reference/Protocols/SPUUpdaterDelegate.html).

---

## 4. MenuBarExtra, Hauptfenster, kein Dock-Icon

| Thema | Befund | Status / Quelle |
|---|---|---|
| `MenuBarExtra` | Scene, macOS 13; `.menuBarExtraStyle(.window)` für popover-artiges Fenster mit Standard-Controls | belegt: https://developer.apple.com/documentation/swiftui/menubarextra, https://developer.apple.com/documentation/swiftui/menubarextrastyle/window |
| Nur-Menüleisten-App | wird beendet, wenn der Nutzer das Extra aus der Menüleiste entfernt; für kein Dock-Icon `LSUIElement = true` | belegt: menubarextra |
| `LSUIElement` | „agent app that runs in the background and doesn’t appear in the Dock“ | belegt: https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement |
| Activation Policy | `.accessory` entspricht `LSUIElement = 1`; kann programmatisch aktiviert werden | belegt: https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum/accessory |
| Hauptfenster öffnen | `@Environment(\.openWindow)` → `openWindow(id:)`; bei `Window`-Scene wird das bestehende Fenster nach vorn geholt | belegt: https://developer.apple.com/documentation/swiftui/openwindowaction |
| Fenster nicht beim Start zeigen | `.defaultLaunchBehavior(_:)` (macOS 15) | belegt: https://developer.apple.com/documentation/swiftui/scene/defaultlaunchbehavior(_:) |
| In den Vordergrund | `NSApplication.activate()` (macOS 14) – „doesn’t guarantee app activation“ | belegt: https://developer.apple.com/documentation/appkit/nsapplication/activate() |

**Empfehlung:** `LSUIElement = YES`, Scenes: `MenuBarExtra(...).menuBarExtraStyle(.window)` + `Window("Software Regisseur", id: "main")` mit `.defaultLaunchBehavior(.suppressed)`; Menüpunkt ruft `openWindow(id: "main")` und `NSApp.activate()`. Optional beim Öffnen des Hauptfensters `setActivationPolicy(.regular)` und beim Schließen zurück auf `.accessory`, falls Cmd-Tab/Dock gewünscht (Spike, UX). „App beenden“ beendet nur die GUI; „Dienst stoppen“ separat über XPC/`unregister()` (D, C5).

---

## 5. App Sandbox – Machbarkeit und Empfehlung (ADR-0009, Q2)

### 5.1 Fakten

| Thema | Befund | Status / Quelle |
|---|---|---|
| Kindprozesse | Ein eingebettetes Kommandozeilen-Tool einer sandboxed App „must inherit the containing app’s sandbox configuration“ | belegt: https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox, https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app |
| Programme in User-Ordnern | Sandbox-App kann Programme außerhalb Bundle/Container/App-Group-Container nur mit `com.apple.security.files.user-selected.executable` ausführen | belegt: https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox |
| Ordnerauswahl | Open-Panel/`fileImporter` erweitert die Sandbox rekursiv auf den gewählten Ordner | belegt: ebd. |
| Persistenz | Security-scoped Bookmark (`.withSecurityScope`), beim Auflösen `startAccessingSecurityScopedResource()`; bei `bookmarkDataIsStale` neu erzeugen | belegt: ebd. |
| Bookmarks zwischen Prozessen | Bookmark mit Optionen `[]` erstellen und an LaunchAgent/XPC-Service übergeben; Empfänger erweitert seine Sandbox beim Zugriff automatisch | belegt: ebd. |
| App-Group-Container (Developer ID) | Zugriff ohne Rückfrage nur, wenn notarisiert **und** Group-ID im Provisioning-Profile oder mit Team-ID präfixiert | belegt: ebd. |
| Container-Zugriff durch Helper | Seit macOS 14 ordnet das System Container per Code-Signatur zu, auch für Launch Agents; fremder Container-Zugriff löst Nutzerabfrage aus | belegt: ebd. |
| Notarisierung ≠ Sandbox | Notarisierungsvoraussetzungen: Developer-ID-Signatur, Hardened Runtime, Secure Timestamp, kein `get-task-allow` – **App Sandbox ist keine Voraussetzung** | belegt: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution |
| Sparkle in Sandbox | Erfordert Installer-XPC (`SUEnableInstallerLauncherService = YES`) und `com.apple.security.temporary-exception.mach-lookup.global-name` für `$(PRODUCT_BUNDLE_IDENTIFIER)-spks`/`-spki` | belegt: https://sparkle-project.org/documentation/sandboxing/ |

### 5.2 Empfehlung (konsistent mit ADR-0009)

1. **Agent Service: bewusst unsandboxed** (Hardened Runtime, Developer ID). Grund (abgeleitet aus belegten Fakten): Er startet `git`, `codex`, `claude` in beliebigen Repos; Kindprozesse würden eine Sandbox erben, die CLIs bräuchten Zugriff auf `~/.codex`, `~/.claude`, eigene Keychain-Einträge, Netzwerk und Toolchains außerhalb jeder Sandbox. Restrisiko dokumentieren: ein kompromittierter Agent hat volle Benutzerrechte → strikte Prozess-Ausführung (Argument-Arrays statt Shell, Pfad-Validierung, L3).
2. **UI: Sandbox technisch machbar – Ziel, aber per Spike zu bestätigen (Q2 Schritt 1–3).** Bausteine sind alle dokumentiert: Ordnerauswahl in der UI → Bookmark ohne Security-Scope per XPC an den Agent (der unsandboxed ohnehin keinen braucht) bzw. security-scoped Bookmark für die UI selbst; XPC über App-Group-präfixierten Mach-Namen; DB im App-Group-Container mit Team-ID-Präfix; Sparkle mit Installer-XPC + temporary-exception. **Realistischer Sicherheitsgewinn ist begrenzt**, weil die UI den vollmächtigen Agent fernsteuert; der Nutzen liegt in der Isolation von Markdown-Rendering und Provider-Netzwerkcode in der UI. Fällt der Spike negativ aus (z. B. Sparkle-Neustart des Agents, TCC-Abfragen, Bookmark-Staleness), UI ebenfalls unsandboxed – in einem ADR begründen.
3. **TCC unabhängig von der Sandbox (Spike):** Auch ein unsandboxed Agent kann bei Repos in `~/Documents`, `~/Desktop`, iCloud Drive, Wechsel- oder Netzwerkvolumes Datenschutzabfragen auslösen. Die gelesene Seite verweist darauf („discretionary access controls … or mandatory access controls … may cause errors“), Details pro Ort sind auf echtem Mac zu prüfen; Erklärbildschirm-Regel 5.1.1(iv) gilt auch dafür (Q4).

---

## 6. Notarisierung, Hardened Runtime, Sparkle 2

### 6.1 Notarisierung (belegt)

- Voraussetzungen: alle Executables gültig signiert, **Developer ID Application**, Hardened Runtime für App- und Command-Line-Targets, Secure Timestamp, kein `com.apple.security.get-task-allow=true`, korrekt formatierte Entitlements (https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
- Workflow (https://developer.apple.com/documentation/security/customizing-the-notarization-workflow):
  1. `ditto -c -k --keepParent App.app App.zip` (bzw. DMG)
  2. `xcrun notarytool store-credentials "<profil>"` einmalig; `xcrun notarytool submit <datei> --keychain-profile "<profil>" --wait`
  3. bei Fehlern `xcrun notarytool log <id> --keychain-profile "<profil>"`
  4. `xcrun stapler staple App.app` bzw. auf das DMG; ZIPs können nicht gestapelt werden (Inhalt stapeln, neu zippen).
  5. Prüfung `spctl`/`codesign --verify` (Q3; Befehle selbst hier nicht aus Doku zitiert).
- `stapler` lädt Tickets über CloudKit; `notarytool` nutzt S3 Transfer Acceleration (Firewall-Hinweis, belegt ebd.).

### 6.2 Hardened-Runtime-Entitlements für das Starten von Kindprozessen

- Die Hardened-Runtime-Ausnahmen sind: JIT, Unsigned Executable Memory, DYLD-Umgebungsvariablen, Disable Library Validation, Disable Executable Memory Protection, Debugging Tool; dazu Resource-Access-Entitlements (Audio, Kamera, …, Apple Events) (belegt: https://developer.apple.com/documentation/security/hardened-runtime).
- **Für `posix_spawn`/`Process` externer, eigenständig signierter Programme (git, codex, claude) ist keine dieser Ausnahmen aufgeführt** (abgeleitet: Liste enthält keinen „spawn“-Punkt; Entitlements gelten für das eigene Executable und von ihm geladene Bibliotheken, „Shared libraries, frameworks, and in-process plug-ins inherit the entitlements of their host executable“). Kindprozesse laufen mit ihrer eigenen Signatur. **Spike:** realer Start von `codex`/`claude` (Node-basiert) aus dem notarisierten Agent.
- `disable-library-validation` nur nötig, wenn fremde Dylibs in den eigenen Prozess geladen werden – nicht geplant. Sparkle-Doku nennt Library Validation als Grund, für Debug-Builds mit Apple-Development-Zertifikat zu signieren (belegt: https://sparkle-project.org/documentation/).

### 6.3 Sparkle 2 (ADR-0017)

| Thema | Befund | Status / Quelle |
|---|---|---|
| Version | Letztes Release **2.10.1 (2026-10-25)** | belegt: https://github.com/sparkle-project/Sparkle/releases |
| Einbindung | Swift Package; `SPUStandardUpdaterController` | belegt: https://sparkle-project.org/documentation/ |
| EdDSA | `./bin/generate_keys` erzeugt ed25519-Schlüssel im Keychain und gibt Public Key aus → `SUPublicEDKey` in Info.plist; Archive/Deltas/PKGs werden signiert | belegt: ebd. |
| Appcast | `SUFeedURL` (HTTPS); `./bin/generate_appcast <ordner>` erzeugt Appcast + Deltas mit Signaturen | belegt: ebd. |
| Signierter Feed | `SURequireSignedFeed` (ab Sparkle 2.9) validiert Appcast und Release Notes per Signatur | belegt: https://sparkle-project.org/documentation/customization/ |
| Schlüsselrotation | Bei Developer-ID-Signatur + EdDSA kann einer der beiden Schlüssel per Update rotiert werden | belegt: https://sparkle-project.org/documentation/ |
| Archive-Formate | dmg, zip, tar, Apple Archive, pkg | belegt: ebd. |
| Signieren | Archive & Export über Xcode Organizer signiert Sparkles XPC-Services/Helper korrekt; manuell: `codesign -f -s … -o runtime` je Komponente, ohne `--deep` | belegt: https://sparkle-project.org/documentation/sandboxing/ |
| Hintergrund-Apps (`LSUIElement`) | Ab 2.2 stehlen geplante Update-Alerts keinen Fokus; Dockless-Apps sollen „gentle reminders“ implementieren (`supportsGentleScheduledUpdateReminders`), sonst Log-Warnung | belegt: https://sparkle-project.org/documentation/gentle-reminders/ |
| Automatik | `SUEnableAutomaticChecks`, `SUAutomaticallyUpdate` (Default NO); Prüfung standardmäßig alle 24 h | belegt: https://sparkle-project.org/documentation/customization/, https://sparkle-project.org/documentation/programmatic-setup/ |
| Sandbox | siehe §5.1 | belegt |

**Empfehlung:** Sparkle nur in der Haupt-App (Agent ist Teil des Bundles und wird mit ersetzt). `SURequireSignedFeed = YES` (passt zu „signiert, nachprüfbar“, Q3), gentle reminders implementieren, Agent-Neustart nach Update per Handshake (§3.4). EdDSA-Private-Key nur im Keychain des Release-Macs (ADR-0017) – `generate_keys` legt ihn dort ab (belegt).

---

## 7. iOS: Spracherkennung, Aufnahme, Keychain, App Groups

### 7.1 Speech-Framework

| Thema | Befund | Status / Quelle |
|---|---|---|
| `SpeechAnalyzer` | Actor, iOS 26 / macOS 26; Module liefern Ergebnisse als `AsyncSequence` | belegt: https://developer.apple.com/documentation/speech/speechanalyzer |
| `SpeechTranscriber` | Modul für „normal conversation and general purposes“; Geräteunterstützung über `isAvailable`, `supportedLocales`, `installedLocales`, `supportedLocale(equivalentTo:)`; sonst `DictationTranscriber` | belegt: https://developer.apple.com/documentation/speech/speechtranscriber |
| `DictationTranscriber` | gleiche Modelle wie Systemdiktat bzw. `SFSpeechRecognizer` on-device, „compatible with older devices“; Bias über `AnalysisContext.contextualStrings`, eigenes Vokabular über `SFSpeechLanguageModel` | belegt: https://developer.apple.com/documentation/speech/dictationtranscriber, https://developer.apple.com/documentation/speech/analysiscontext |
| Modelle / Offline | Assets werden **von Apple-Servern heruntergeladen** (`AssetInventory.assetInstallationRequest(supporting:)` → `downloadAndInstall()`), danach persistent und app-übergreifend geteilt; Status über `AssetInventory.status(forModules:)`; begrenzte Locale-Reservierungen (`maximumReservedLocales`) | belegt: https://developer.apple.com/documentation/speech/assetinventory |
| Datenfluss | „`SpeechAnalyzer` transcriber modules don’t send audio data of the user’s voice to Apple’s servers.“ | belegt: https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition |
| `SFSpeechRecognizer` | `supportsOnDeviceRecognition`; `requiresOnDeviceRecognition` nur wirksam, wenn unterstützt, sonst Netz nötig | belegt: https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition |
| Berechtigung | `NSSpeechRecognitionUsageDescription` Pflicht für `SFSpeechRecognizer.requestAuthorization` (sonst Crash); die Seite sagt, dieser Prozess gilt „only … using `SFSpeechRecognizer`“ | belegt: asking-permission-to-use-speech-recognition |

**Wahrheitsgemäße Anzeige (H2 A):** „Auf diesem Gerät verfügbar“ = `SpeechTranscriber.isAvailable` und Locale in `installedLocales`; „Download nötig (einmalig Internet)“ = in `supportedLocales`, aber nicht installiert; sonst Fallback `DictationTranscriber` bzw. „nicht verfügbar“. **Spike:** ob `SpeechAnalyzer` ohne Speech-Recognition-Berechtigung startet (Doku impliziert es, sagt es aber nicht ausdrücklich), und Qualität für Deutsch (`de_DE`). Mikrofon-Berechtigung ist immer nötig.

### 7.2 Aufnahme

- `AVAudioRecorder`: Aufnahme in Datei, Pause/Resume, Metering; Audio-Session-Kategorie `record`/`playAndRecord` nötig (belegt: https://developer.apple.com/documentation/avfaudio/avaudiorecorder).
- Mikrofon: `AVAudioApplication.requestRecordPermission()` (iOS 17); ohne Purpose-String `NSMicrophoneUsageDescription` beendet sich die App; ohne Erlaubnis nur Stille (belegt: https://developer.apple.com/documentation/avfaudio/avaudioapplication/requestrecordpermission(completionhandler:), https://developer.apple.com/documentation/bundleresources/information-property-list/nsmicrophoneusagedescription).
- **Format-Empfehlung (abgeleitet):** AAC in `.m4a` (wird von OpenAI akzeptiert, s. ai-providers.md), mono, 16–24 kHz, ca. 32–48 kbit/s. Rechnung: 32 kbit/s ≈ 14,4 MB pro Stunde → unter dem 25-MB-Limit; Segmentierung trotzdem implementieren. Für SpeechAnalyzer liefert `bestAvailableAudioFormat(compatibleWith:)` das Zielformat (belegt: speechanalyzer).

### 7.3 Keychain mit iCloud-Keychain-Sync

| Thema | Befund | Status / Quelle |
|---|---|---|
| Sync | `kSecAttrSynchronizable = true`; Abfragen ohne den Key liefern keine synchronisierten Items; `kSecAttrSynchronizableAny` für beides | belegt: https://developer.apple.com/documentation/security/ksecattrsynchronizable |
| Einschränkungen | keine `…ThisDeviceOnly`-Accessibility; Update/Delete wirkt auf **alle** Geräte; keine persistenten Referenzen; bei mehreren Apps `kSecAttrAccessGroup` + gemeinsames Access-Group-Entitlement | belegt: ebd. |
| macOS | `kSecUseDataProtectionKeychain = true` für iOS-artiges Verhalten; synchronisierte Items verhalten sich automatisch so | belegt: https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain |
| Access Groups | Keychain-Access-Group `$(TeamID).<name>` per Keychain-Sharing-Capability; erste Gruppe = Default; fremde Gruppe → `errSecMissingEntitlement` | belegt: https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps |
| macOS-Voraussetzung | Data-Protection-Keychain-Gruppen aus Entitlements, die per Provisioning-Profile autorisiert sein müssen → app-ähnliches Bundle; nur im User-Login-Kontext | belegt: https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains |
| Developer ID | „Keychain sharing“ für Developer ID verfügbar | belegt: https://developer.apple.com/help/account/reference/supported-capabilities-macos |

**Empfehlung (I):** Standard: geräteeigenes Item, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` o. ä., nicht synchronisiert. Opt-in „über iCloud-Schlüsselbund teilen“: Item mit `kSecAttrSynchronizable = true`, synchronisierbare Accessibility, gemeinsame Access-Group `$(SR_TEAM_ID).<prefix>.shared-keys` in iOS-App, macOS-App **und** Agent-Bundle (Werte aus `Local.xcconfig`, ADR-0013). Löschen eines synchronisierten Keys im UI klar als „auf allen Geräten“ kennzeichnen (belegt: Delete wirkt überall). **Nicht belegt:** eine API, die abfragt, ob iCloud-Schlüsselbund beim Nutzer aktiv ist – UI darf daher nicht „synchronisiert“ behaupten, nur „zur Synchronisierung markiert“.

### 7.4 App Groups

- iOS-Format `group.<name>` (registrieren); macOS zusätzlich `<TEAMID>.<name>` ohne Registrierung; ermöglicht gemeinsame Container, Keychain-Gruppen und IPC (belegt: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups).
- iOS↔macOS teilen **keine** App Group (verschiedene Geräte); geräteübergreifend nur CloudKit und iCloud-Keychain. Auf dem Mac App Group mit Team-ID-Präfix für UI + Agent (DB, Mach-Service-Name).

---

## 8. iOS-Hintergrundaktualisierung – was ehrlich zugesagt werden kann

| Mechanismus | Belegte Eigenschaften | Quelle |
|---|---|---|
| `BGAppRefreshTask` | braucht `UIBackgroundModes` `fetch` und `BGTaskSchedulerPermittedIdentifiers`; „The system decides the best time“; bis zu 30 s Laufzeit; `earliestBeginDate` ist nur Untergrenze, kein Startversprechen | https://developer.apple.com/documentation/backgroundtasks/bgapprefreshtask, https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app, https://developer.apple.com/documentation/backgroundtasks/bgtaskrequest/earliestbegindate, https://developer.apple.com/documentation/bundleresources/information-property-list/bgtaskschedulerpermittedidentifiers |
| Stille Pushes (CloudKit) | Low Priority, Zustellung **nicht garantiert**, Drosselung, „don’t try to send more than two or three per hour“; nur neueste wird gehalten; bei Force-Quit verworfen; 30 s Laufzeit | https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app |
| `BGContinuedProcessingTask` (iOS 26) | vom Nutzer im Vordergrund gestartete Arbeit läuft im Hintergrund weiter, mit Live-Activity-Fortschritt, vom Nutzer abbrechbar, vom System beendbar | https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask |
| `beginBackgroundTask` | begrenzte Zeit zum Abschließen (z. B. Outbox senden) | choosing-background-strategies-for-your-app |

**Ehrliche Zusage (ADR-0011, N3):** iPhone synchronisiert garantiert beim Öffnen, beim Wechsel in den Vordergrund und manuell; danach schickt es offene Outbox-Einträge mit `beginBackgroundTask`. Hintergrund-Sync per App-Refresh oder stillem CloudKit-Push ist **opportunistisch ohne Zeitzusage**. Für lange Transkriptions-Uploads eignen sich `BGContinuedProcessingTask` oder eine Background-`URLSession` (Spike). UI zeigt „zuletzt synchronisiert“ und den Mac-Heartbeat.

---

## 9. Widersprüche und Risiken gegenüber Pflichtenheft/ADRs

1. **ADR-0011 vs. CKSyncEngine:** Die Engine verlangt das Remote-Notifications-Entitlement und nutzt stille Pushes (belegt). Kein Widerspruch zum Produktwunsch (keine Nutzer-Mitteilungen, keine Berechtigungsabfrage), muss aber laut N3 explizit dokumentiert werden. Polling-only im Mac-Helper ist **nicht** offiziell beschrieben → Spike 1/2 (§2.1).
2. **ADR-0013 nennt SwiftData als benötigte API;** Empfehlung GRDB → neuer ADR, ADR-0013 bleibt gültig (Mindestversion unverändert).
3. **ADR-0017 „gemeinsam aktualisiert“:** Austausch des Bundles startet den laufenden Agent nicht nachweislich neu → Neustart-Mechanik nötig (§3.4, Spike).
4. **ADR-0009/Q2 UI-Sandbox:** machbar, aber geringer Sicherheitsgewinn, und Sparkle braucht in der Sandbox eine `temporary-exception` – im Sandbox-ADR als Trade-off aufführen.
5. **Agent muss ein app-ähnliches Bundle sein** (CloudKit, APS, Keychain-Group brauchen Provisioning-Profile). Das Pflichtenheft (C5) spricht von „LaunchAgent“ – kompatibel, aber Build-Struktur entsprechend planen.
6. **SpeechAnalyzer-Assets brauchen einmalig Internet** – Anzeige „offline verfügbar“ erst nach installiertem Asset (H2 A).

## 10. Offene Spikes (Abnahme nur mit Testbeleg)

| # | Spike | Bezug |
|---|---|---|
| S1 | CKSyncEngine im LaunchAgent-App-Bundle, `automaticallySync=false`, nur Polling; Konfliktfall `serverRecordChanged` | ADR-0011, A10, A24, A33 |
| S2 | Provisioning-Profile/Entitlements (CloudKit, APS, Keychain-Group, App-Group) im eingebetteten Agent-Bundle, notarisiert | ADR-0009, A28 |
| S3 | SMAppService.agent: Registrierung, `requiresApproval`-Pfad, Verhalten nach Sparkle-Update und nach Verschieben der App | ADR-0002, ADR-0017, A21 |
| S4 | XPC mit `XPCPeerRequirement` (sandboxed UI ↔ unsandboxed Agent, App-Group-Mach-Name) | Q2, A01 |
| S5 | `codex`/`claude`/`git` aus notarisiertem Hardened-Runtime-Agent starten; TCC-Abfragen in `~/Documents`/iCloud Drive | Q2, A30 |
| S6 | Sparkle in sandboxed UI (Installer-XPC, temporary-exception) inklusive manipuliertem Paket | ADR-0017, A21, A28 |
| S7 | SpeechTranscriber `de_DE`: Verfügbarkeit, Asset-Download, Berechtigungen | H2 A, A07 |
| S8 | iCloud-Keychain-Sync iOS ↔ macOS mit gemeinsamer Access-Group | I, A27 |
