# Handbuch – Software Regisseur 1.0

Dieses Handbuch beschreibt, was in Version 1.0 implementiert ist. Teile, die noch nicht auf echter Hardware oder mit echten Agentenläufen nachgewiesen sind, sind so gekennzeichnet:

> **Nicht verifiziert:** … (mit Verweis auf den offenen Test oder ADR)

Maßgeblich bleiben das Pflichtenheft und die [ADRs](../adr/README.md). Der Prüfstand aller Abnahmekriterien steht in der [Abnahmematrix](../acceptance/abnahmematrix.md).

| Kapitel | Inhalt |
|---|---|
| [1. Installation](01-installation.md) | Mac-App, Hintergrunddienst (Login-Agent, Anmeldeobjekte), iOS-App über Xcode oder TestFlight |
| [2. Erste Einrichtung](02-erste-einrichtung.md) | Stammordner, Projekte verknüpfen (Mac und iPhone), Ordnerstruktur, `AGENTS.md`-Block, `CLAUDE.md`-Import |
| [3. KI und API-Schlüssel](03-ki-und-schluessel.md) | Eigene Schlüssel je Gerät, Transkription und Textausarbeitung, iCloud-Schlüsselbund, Kosten, Datenflüsse, Ausarbeitung mit Repo-Kontext am Mac |
| [4. Coding-Agenten](04-agenten.md) | Codex und Claude Code: Erkennung, Anmeldung, Modell und Denkstufe, Planung, Kontingent, Freigaben, Review, Worktrees, Grenzen der Agenten, Remote-Control-Anforderungen |
| [5. Synchronisierung](05-synchronisierung.md) | iCloud ohne Push-Benachrichtigungen, Zeitpunkte, Konflikte, iCloud-Daten löschen und neu beginnen |
| [6. Datenschutz](06-datenschutz.md) | Datenexport, Löschen, was nie synchronisiert oder exportiert wird |
| [7. Grenzen und FAQ](07-grenzen-und-faq.md) | Bekannte Einschränkungen und häufige Fragen |

Die Oberfläche ist in Version 1.0 nur auf Deutsch (Österreich) verfügbar. Bezeichnungen von Schaltflächen und Menüs sind hier so geschrieben, wie sie in der App erscheinen.
