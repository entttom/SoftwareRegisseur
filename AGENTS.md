# Arbeitsanweisungen für Coding-Agenten – Software Regisseur

## Verbindlicher Auftrag

1. Lies **vollständig** `Software_Regisseur_1.0_Codex_Entwicklungsauftrag.md`. Die Datei liegt nur lokal beim Eigentümer und ist nicht im Repository; fehlt sie, gelten ADRs und Abnahmematrix als maßgebliche Grundlage, und offene Punkte werden beim Eigentümer erfragt.
2. Lies den ADR-Index `docs/adr/README.md` und alle `accepted`-ADRs vor Architekturänderungen.
3. **Jede besprochene Funktion ist Bestandteil von Version 1.0.** Es gibt keinen funktionsreduzierten MVP. Meilensteine dienen nur der internen Umsetzung.
4. Achte besonders auf ADR-0006: pro Agent auswählbares **Modell und Reasoning-/Effort-Level** auf iOS und macOS, global/pro Projekt/pro Auftrag, dynamische Kompatibilitätsprüfung und keine stillen Fallbacks.
5. Die technischen Fähigkeiten der installierten Codex-/Claude-Code-Version zuerst gegen offizielle Dokumentation und reale Capability-Spikes verifizieren; keine undokumentierten Flags, Session-Deep-Links oder kosten-/kontingentbezogenen API-Angaben erfinden.
6. Unbelegte externe Integrationsrisiken transparent ausweisen und v1-taugliche echte Alternativen anbieten; keine Mockfunktionen als abgeschlossen melden.
7. Bestehende Dateien und AGENTS-/CLAUDE-Inhalte nicht destruktiv überschreiben, fremde Repository-Strukturen nur mit Zustimmung migrieren.
8. Ohne Zustimmung niemals Git push/force-reset, ungeschützte Shell-Kommandos ausführen oder Geheimnisse im Klartext in Git, CloudKit oder Logs speichern.
9. Für neue wesentliche Entscheidungen `docs/adr/TEMPLATE.md` benutzen. Bei Änderung von `accepted`-Entscheidungen neuen ADR anlegen und Vorgänger explizit als `superseded` referenzieren.
10. Tests und A01–A42-Abnahmematrix (`docs/acceptance/abnahmematrix.md`) fortlaufend pflegen. Ergebnisse nur mit konkretem Testbeleg als bestanden ausweisen.
11. Eigene Erklärbildschirme vor System-Berechtigungsabfragen gemäß Pflichtenheft Q4 gestalten (App Review 5.1.1(iv)): neutraler „Weiter“-Button, kein „Später“/Überspringen, Systemabfrage sofort auf jedem Pfad, nach Ablehnung Link zu den Einstellungen.
12. Team-ID, Bundle-ID-Präfix und CloudKit-Container nur in der nicht eingecheckten `Config/Local.xcconfig` (ADR-0013); niemals in Projektdateien oder Quellcode hart kodieren.

## Erste Implementierungsschritte

- Projektrepo untersuchen; falls noch leer: native Xcode-Workspace-/Targets und Swift Packages aufbauen.
- Reale Machbarkeitsprüfungen: Mac-Dienst, CloudKit, Modell/Effort-Capability in Codex/Claude, vollautomatischer Agentenstart mit offizieller mobiler Steuerbarkeit, Sandbox-/Notarisierung.
- `proposed`-ADR-0010 erst nach dokumentierten Versuchen entscheiden.
- Danach alle Funktionen gemäß dem Pflichtenheft mit lauffähigen Tests umsetzen. Nicht nach einem UI-Prototyp stehen bleiben.
