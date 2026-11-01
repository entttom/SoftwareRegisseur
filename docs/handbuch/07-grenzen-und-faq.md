# 7. Grenzen und FAQ

## Bekannte Einschränkungen

**Nachweise**

- Alle Abnahmekriterien A01–A42 stehen auf `offen` ([Abnahmematrix](../acceptance/abnahmematrix.md)). Automatisierte Tests laufen; Ende-zu-Ende-Nachweise auf echter Hardware und mit echten Agentenläufen fehlen.
- Echte Agentenläufe mit Kontingentverbrauch (Codex O1–O7, Claude Code T0–T9) wurden noch nicht durchgeführt. Modellkataloge und Startparameter sind ohne Prompt bzw. per Test geprüft.

**Agenten**

- **Mobile Weiterführung in den offiziellen Apps ist nicht verifiziert** ([ADR-0010](../adr/0010-offizielle-mobile-agenten-sitzungen.md) `proposed`). Läufe erscheinen nicht in der ChatGPT-/Codex- oder Claude-App; Status und Freigaben laufen über Software Regisseur.
- Codex `app-server` ist laut OpenAI experimentell. Feldnamen können sich zwischen CLI-Versionen ändern; neue Versionen werden erkannt und müssen erneut geprüft werden.
- Claude Code bestätigt die tatsächlich verwendete Denkstufe im Headless-Modus nicht („nicht bestätigt“). Codex meldet nur die konfigurierten Werte.
- Beide Agenten würden ungültige Modell-/Stufenwerte selbst still ersetzen; Software Regisseur verhindert das durch eigene Prüfung vor dem Start. Ohne abrufbaren Modellkatalog sind Aufträge mit explizitem Modell blockiert.
- Kontingent-Rücksetzzeitpunkte sind nur Angaben des Anbieters (sofern geliefert) oder Ihre eigenen; sonst gilt der begrenzte Backoff.
- Sperren verhindern Doppelstarts innerhalb von Software Regisseur, nicht Änderungen durch Editoren oder Terminals.
- Eigene Programmpfade für Agenten sind in der Mac-Oberfläche noch nicht einstellbar ([Kapitel 4](04-agenten.md#erkennung)).

**Mac**

- Der Hintergrunddienst läuft ohne App Sandbox mit Ihren Benutzerrechten ([ADR-0020](../adr/0020-agent-service-unsandboxed-xpc.md)); ob die Mac-App selbst später sandboxed wird, ist offen.
- iCloud, Login-Agent, XPC und Schlüsselbund-Gruppe funktionieren nur in mit Ihrem Team signierten Builds.
- Notarisierter Release, Installation auf einem frischen Mac und Sparkle-Update n → n+1 sind nicht nachgewiesen (A28). Ob der Dienst nach einem Update automatisch neu startet, ist offen (Spike S3).
- Datenschutzabfragen von macOS für Repositories in `~/Documents`, `~/Desktop` oder iCloud Drive sind nicht untersucht (Spike S5).
- Ein ausgeschalteter oder schlafender Mac startet geplante Aufträge nicht zum Sollzeitpunkt; es gilt die Nachholregel.
- Löschen lokaler Daten ist in der Mac-Oberfläche noch nicht verfügbar ([Kapitel 6](06-datenschutz.md#daten-löschen)).
- Das Gespräch „Mit KI besprechen“ gibt es derzeit nur auf iPhone und iPad.

**iPhone/iPad und Synchronisierung**

- Keine Push-Benachrichtigungen: Neue Freigaben und Statuswechsel sehen Sie beim Öffnen oder Aktualisieren der App. Hintergrundabgleich auf iOS ist gelegentlich und ohne Zeitzusage.
- Lesbare Aufgaben-IDs (`FR-0001` …) gibt es erst, wenn der Mac die Datei angelegt hat.
- Apple-Spracherkennung braucht einmalig Internet für das Sprachmodell; Qualität für Deutsch ist nicht real geprüft (Spike S7).
- Ob ein über den iCloud-Schlüsselbund synchronisierter Schlüssel am Mac ankommt, ist nicht geprüft (Spike S8).
- TestFlight-Verteilung wurde noch nicht durchgeführt.

**KI-Anbieter**

- Kostenangaben sind Schätzungen aus Ihren eingetragenen Preisen; kein Anbieter liefert Preise per API.
- OpenAI liefert keine Modellfähigkeiten über die API; ob ein Modell strukturierte Ausgaben unterstützt, zeigt sich erst bei der Anfrage.
- Die maximale Audiodauer bei `gpt-transcribe` ist nicht dokumentiert; lange Aufnahmen werden in Abschnitte geteilt.

## FAQ

**Brauche ich ein Abonnement von Software Regisseur?**
Nein. Sie verwenden eigene API-Schlüssel bei OpenAI, Anthropic oder Google und Ihr eigenes Login bei Codex bzw. Claude Code.

**Kann ich meinen OpenAI-API-Schlüssel für Codex verwenden, oder meinen Anthropic-Schlüssel für Claude Code?**
Nein. Die Schlüssel in Software Regisseur dienen nur der Transkription und Textausarbeitung. Codex und Claude Code melden Sie selbst im Terminal an (`codex login`, `claude auth login`).

**Funktioniert die iPhone-App ohne Mac?**
Ja: Erfassen, Diktieren, Transkribieren, KI-Ausarbeitung, Bearbeiten, Freigeben und Planen funktionieren ohne Mac. Ordneroperationen im Repository, Agentenstarts und Ausarbeitungen mit Repo-Kontext warten, bis der Mac erreichbar ist.

**Warum bekomme ich keine Mitteilung, wenn ein Agent fertig ist oder eine Freigabe braucht?**
Software Regisseur verwendet bewusst keine Push-Benachrichtigungen ([ADR-0011](../adr/0011-cloudkit-ohne-sichtbare-push-benachrichtigungen.md)). Öffnen Sie die App oder ziehen Sie die Liste herunter; die Menüleiste am Mac zeigt den Stand laufend.

**Kann ich einen Lauf in der Claude- oder ChatGPT-App auf dem iPhone weiterführen?**
Derzeit nicht. Das ist ein Ziel von Version 1.0, aber nicht nachgewiesen ([Kapitel 4](04-agenten.md#mobile-weiterführung-in-den-offiziellen-apps-und-remote-control)). Freigaben erteilen Sie in Software Regisseur.

**Mein Agent wird nicht als einsatzbereit angezeigt.**
Prüfen Sie: Ist er in `/opt/homebrew/bin`, `/usr/local/bin` oder `~/.local/bin` installiert? Sind Sie angemeldet (`codex login status`, `claude auth status`)? Bei der npm-Variante von Codex muss `node` vorhanden sein. Danach Einstellungen › „Agenten neu erkennen“. Die Diagnose in der Agentenübersicht nennt den konkreten Grund.

**Ein geplanter Auftrag steht auf „blockiert“.**
Meist ist die gespeicherte Kombination aus Modell und Denkstufe nicht mehr verfügbar (z. B. nach einem Agenten-Update oder Kontowechsel). Am Mac in der Warteschlange „Modell/Stufe ersetzen“ wählen. Software Regisseur ersetzt sie nie selbst.

**Committet Software Regisseur in meine Repositories?**
Nicht in Ihren Default-Branch, außer bei der Übernahme, die Sie ausdrücklich mit „Integrieren“ auslösen. Request-, ADR- und Anweisungsdateien committen Sie selbst. Auf dem Job-Branch committet der Dienst nach Laufende nicht gesicherte Agentenänderungen, damit sie prüfbar sind. Gepusht wird nie.

**Was passiert mit meiner AGENTS.md?**
Software Regisseur verwaltet nur den markierten Block zwischen `<!-- SOFTWARE-REGISSEUR:BEGIN v2 -->` und `<!-- SOFTWARE-REGISSEUR:END -->` und schreibt ihn nur nach Ihrer Zustimmung. Ihr übriger Text bleibt byte-genau erhalten.

**Wo liegen die Worktrees, und wann verschwinden sie?**
Im App-Group-Container des Mac unter `SoftwareRegisseur/Worktrees/`. Entfernt werden sie nur mit „Worktree entfernen“; der Branch bleibt, bis Sie ihn löschen.

**Ich habe einen Projektordner verschoben.**
Das Projekt erscheint als „nicht erreichbar“, Daten bleiben erhalten. Mit „Neu verknüpfen“ wählen Sie den neuen Ort.

**Ich habe an zwei Geräten dieselbe Aufgabe offline geändert.**
Nicht überlappende Änderungen werden zusammengeführt; überlappende erscheinen als Konflikt, den Sie entscheiden. Nichts wird still überschrieben.

**Wie entferne ich alles?**
Export erstellen (empfohlen), dann auf jedem Gerät „Alle lokalen Daten löschen“, einmal „iCloud“ löschen, synchronisierte Schlüssel über „API-Schlüssel löschen“ entfernen, Hintergrunddienst deaktivieren und die Apps löschen. Ihre Git-Repositories bleiben unberührt.

**Kann ich Software Regisseur an andere weitergeben?**
Version 1.0 ist für den Eigengebrauch bestimmt. Ein Vertrieb an Dritte braucht einen neuen ADR mit Lizenzprüfung, insbesondere zur Nutzung von Claude-Code- und Codex-Logins ([ADR-0014](../adr/0014-eigengebrauch-in-version-1.md)).
