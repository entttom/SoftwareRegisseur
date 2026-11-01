# 3. KI und API-Schlüssel

Software Regisseur verkauft keine KI-Nutzung. Für Transkription und Textausarbeitung hinterlegen Sie **eigene API-Schlüssel** (Bring Your Own Key). Die Kosten trägt Ihr Konto beim jeweiligen Anbieter.

## Drei getrennte Bereiche

| Bereich | Anbieter in v1 | Wo konfiguriert | Anmeldung |
|---|---|---|---|
| Transkription (Diktat) | Apple-Spracherkennung oder OpenAI Speech-to-Text | je Gerät | OpenAI-API-Schlüssel |
| KI-Textausarbeitung | OpenAI, Anthropic, Google Gemini | je Gerät | API-Schlüssel des Anbieters |
| Coding-Agenten | Codex, Claude Code | am Mac | Ihr eigenes Login in der jeweiligen CLI ([Kapitel 4](04-agenten.md)) |

Die Bereiche sind unabhängig: Transkription und Ausarbeitung können verschiedene Anbieter nutzen, und Modell- bzw. Denkstufenwahl der Agenten hat mit der Modellwahl der Textausarbeitung nichts zu tun. **Ein OpenAI-API-Schlüssel ist keine Codex-Anmeldung, und ein Anthropic-API-Schlüssel ist kein Claude-Code-Abonnement.**

## Schlüssel hinterlegen

### iPhone und iPad

Einstellungen › „Eigene API-Schlüssel“ › Anbieter und Zweck (z. B. „OpenAI – Transkription“, „Anthropic – KI-Ausarbeitung“):

- **Sichern:** speichert den Schlüssel im Schlüsselbund. Danach zeigt die App nur noch „Ein Schlüssel ist hinterlegt. Der Wert wird nicht angezeigt.“
- **Schlüssel prüfen:** ruft die Modellliste des Anbieters ab (keine Textgenerierung). Für die Transkription warnt die Prüfung, wenn `gpt-transcribe` für Ihren Schlüssel nicht gelistet ist.
- **Schlüssel löschen:** entfernt den Schlüssel; die zugehörigen Funktionen werden mit Erklärung deaktiviert, nicht abgebrochen.

Fehlt ein Schlüssel, sind die betroffenen Funktionen deaktiviert und die App sagt, welcher Schlüssel fehlt.

### iCloud-Schlüsselbund (optional)

Standard ist **„nur dieses Gerät“**. Mit „Über iCloud-Schlüsselbund synchronisieren“ fordern Sie die Synchronisierung über den iCloud-Schlüsselbund an (Anzeige: „Hinterlegt (iCloud-Schlüsselbund-Synchronisierung angefordert)“).

- Ob der iCloud-Schlüsselbund auf Ihrem Gerät aktiv ist, kann die App nicht prüfen; sie behauptet deshalb nie „synchronisiert“.
- Löschen eines synchronisierten Schlüssels wirkt auf allen Geräten.
- Schlüssel landen nie im Klartext in iCloud-Datensätzen (CloudKit), Git, Markdown oder Logs.

> **Nicht verifiziert:** Übertragung eines synchronisierten Schlüssels zwischen iPhone und Mac über die gemeinsame Schlüsselbund-Gruppe (Spike S8). Rechnen Sie damit, den Schlüssel am Mac separat einzutragen.

### Mac

Einstellungen › „API-Schlüssel für die KI-Ausarbeitung am Mac“: Speichern, Prüfen, Löschen. Schlüssel liegen gerätebezogen im Schlüsselbund dieses Mac; der Hintergrunddienst liest sie über eine gemeinsame Schlüsselbund-Gruppe. In unsignierten Builds gibt es diese Gruppe nicht; die App warnt dann, dass der Dienst gespeicherte Schlüssel nicht lesen kann.

## Diktat und Transkription

Die Methode wählen Sie je Gerät (Einstellungen › „Diktat“). Ein Wechsel verwirft keine Aufnahme und kein Transkript.

**Apple-Spracherkennung**

- Die Verarbeitung erfolgt auf dem Gerät; Audio geht laut Apple nicht an Apple-Server.
- Das Sprachmodell muss einmalig geladen werden (Internet nötig). Die App zeigt den echten Zustand: „Auf diesem Gerät verfügbar, auch offline“, „Sprachmodell … muss einmalig geladen werden“ oder „nicht verfügbar“ mit Hinweis auf die OpenAI-Transkription.

> **Nicht verifiziert:** Qualität und Verfügbarkeit für Deutsch auf echten Geräten (Spike S7, A07).

**OpenAI Speech-to-Text**

- Standardmodell `gpt-transcribe`.
- **Vor jeder Übertragung** fragt die App: „Audio an OpenAI übertragen?“ mit Dauer der Aufnahme. Erst „Übertragen und transkribieren“ sendet; „Nicht übertragen“ behält die Aufnahme lokal.
- Lange Aufnahmen werden an Sprechpausen in Abschnitte unter dem Limit von 25 MB geteilt.
- „Projektbegriffe als Hinweise“: Fachbegriffe und Akronyme werden als Erkennungshilfe mitgesendet, nicht als gesprochener Text eingefügt.

**Transkript korrigieren:** Das Transkript ist vor dem Speichern editierbar. Gespeichert werden Ihre korrigierte Fassung als Originalnotiz und das unveränderte Transkript.

**Originalaufnahme:** Standard „Nach erfolgreicher Verarbeitung löschen“; alternativ „Auf diesem iPhone behalten“ oder für einige Tage behalten. **Audio wird nie synchronisiert.**

## KI-Textausarbeitung

Einstellungen › „KI-Ausarbeitung“: Anbieter wählen, „Modelle vom Anbieter laden“, Modell übernehmen. Modelle werden beim Anbieter abgefragt, nicht fest eingebaut.

In einer Aufgabe:

- **„Mit KI ausarbeiten“** erzeugt einen strukturierten Entwurf (Typ, Titel, Ziel, Kontext, Akzeptanzkriterien, technische Hinweise, Testfälle, Abhängigkeiten, offene Fragen). Mehrere vorgeschlagene Aufgaben übernehmen oder verwerfen Sie einzeln.
- Option „Projektdaten mitsenden (bestehende Requests, ADR-Index)“. Mit **„Kontext prüfen“** sehen Sie vor dem Senden genau, was übertragen wird, mit geschätzter Token-Zahl und Anzahl geschwärzter möglicher Geheimnisse.
- **„Mit KI besprechen“** (iPhone/iPad): Gespräch zu Notiz oder Aufgabe, kein Coding-Agent. Vorschläge werden erst nach Ihrer Freigabe als neue Entwurfsversion übernommen.
- Originalnotiz, Transkript und Entwürfe werden getrennt versioniert; das Original bleibt unverändert.
- Option „Nach dem Diktat automatisch einen Entwurf vorbereiten“: Der Entwurf wird vorbereitet; den Kontext sehen und senden Sie trotzdem selbst.
- **Eine KI-Ausarbeitung startet nie einen Coding-Agenten.** Notizinhalte werden als Daten gekennzeichnet, nicht als Anweisungen.

## Kosten

Kein Anbieter liefert Preise per API. Alle Kostenangaben in der App sind **geschätzt** aus Token- bzw. Audiominuten und den Preisen, die Sie selbst unter Einstellungen › „Kosten“ eintragen (mit „Preise geprüft am“). Ohne hinterlegten Preis zeigt die App „Kosten unbekannt“ und die reinen Verbrauchswerte (Tokens, Audiosekunden).

## Was wohin übertragen wird

| Daten | Ziel | Wann |
|---|---|---|
| Audioaufnahme | OpenAI (Ihr Schlüssel) | nur nach Bestätigung „Übertragen und transkribieren“ |
| Audioaufnahme | niemand (Apple-Spracherkennung auf dem Gerät) | – |
| Notiz, Transkript, Entwurf, ggf. Projektdaten (Requests, ADR-Index) | gewählter Textanbieter (Ihr Schlüssel) | nur nach „Kontext prüfen“ und Senden |
| Repository-Kontext (Struktur, akzeptierte ADRs, Requests, gewählte Dateien) | Textanbieter, vom Mac aus (Schlüssel des Mac) | nur bei Ausarbeitung mit Repo-Kontext |
| API-Schlüssel | nur an den jeweiligen Anbieter (TLS) | bei jeder Anfrage; nie an iCloud, Git oder Logs |
| Aufgaben, Entwürfe, Einstellungen | Ihre private iCloud-Datenbank | Synchronisierung ([Kapitel 5](05-synchronisierung.md)) |

Es gelten die Datenschutzbedingungen des jeweiligen Anbieters.

## Ausarbeitung mit Repo-Kontext am Mac

Für eine vertiefte Ausarbeitung ergänzt der Mac Kontext aus dem Repository.

**Starten:**

- iPhone: in der Aufgabe „Am Mac mit Repo-Kontext ausarbeiten“. Ist der Mac nicht erreichbar, wartet der Auftrag. Der Mac führt solche Aufträge automatisch aus, solange in Einstellungen › „Diensteinstellungen (nur dieser Mac)“ die Option „KI-Ausarbeitungen vom iPhone automatisch am Mac ausführen“ aktiv ist (Standard: an).
- Mac: in der Aufgabe „Mit KI ausarbeiten (Mac, mit Repo-Kontext) …“. Die App zeigt vorab, dass Repository-Inhalte an den gewählten Anbieter gehen.

Verwendet wird der Text-Schlüssel des Mac.

**Was in den Kontext kommt:**

- Verzeichnisbaum (bis Tiefe 4, höchstens 400 Einträge), ohne `.git`, `node_modules`, `.build`, `DerivedData`, `Pods`, `build`, `dist`, `.venv`, `.swiftpm`,
- akzeptierte ADRs,
- bestehende Requests in den Status Inbox, offen, eingereiht, geplant, in Arbeit, Review, blockiert,
- von Ihnen ausgewählte Quelldateien,
- insgesamt höchstens 60 000 Zeichen.

**Immer ausgeschlossen** (Inhalt wird gar nicht gelesen): Pfade, die auf `.env*`, `*.pem`, `*.p12`, `*.p8`, `*.pfx`, `*.key`, `*.cer`, `*.der`, `*.jks`, `*.keystore`, `*.keychain*`, `*.mobileprovision`, `id_rsa*`, `id_dsa*`, `id_ecdsa*`, `id_ed25519*`, `credentials*`, `secrets.*`, `.netrc`, `.npmrc`, `.pypirc`, `.ssh`, `.aws`, `.gnupg`, `Local.xcconfig` passen, außerdem Binärdateien, symbolische Links und Dateien außerhalb des Repositorys. Im übrigen Text werden Zeichenfolgen, die wie Schlüssel aussehen, geschwärzt.

**Kontext-Manifest:** Zu jeder Ausarbeitung zeigt die App, welche Dateien enthalten sind, welche mit welchem Grund ausgeschlossen wurden („mögliche Geheimnisse (Muster …)“, „Kontextbudget überschritten“, „keine Textdatei“, „symbolischer Link“, …) und die geschätzte Token-Zahl.

Das Ergebnis ist ein synchronisierter Entwurf, den Sie prüfen und erst danach übernehmen.

> **Nicht verifiziert:** End-to-End mit echtem Schlüssel und echtem Repository (A11).
