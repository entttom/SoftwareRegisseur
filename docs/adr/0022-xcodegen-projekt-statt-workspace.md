---
adr: 0022
title: "Xcode-Projekt aus XcodeGen-Spezifikation mit lokalen Swift Packages"
status: accepted
date: 2026-10-30
---

# ADR-0022: Xcode-Projekt aus XcodeGen-Spezifikation mit lokalen Swift Packages

**Status:** Accepted  
**Datum:** 2026-10-30  
**Entscheidungsträger:** Implementierung.

## Kontext

Pflichtenheft T schlägt `SoftwareRegisseur.xcworkspace` vor und erlaubt begründete Abweichungen, wenn sie per ADR/README dokumentiert werden. Handgepflegte `.pbxproj`-Dateien erzeugen bei parallel arbeitenden Agenten und Menschen schwer lösbare Merge-Konflikte.

## Entscheidung

- Das Xcode-Projekt wird aus `project.yml` mit XcodeGen erzeugt (`xcodegen generate`); `SoftwareRegisseur.xcodeproj` ist nicht eingecheckt.
- Gemeinsamer Code liegt in eigenständigen lokalen Swift Packages unter `Packages/`, jedes einzeln mit `swift test` testbar; die App-Targets binden sie als lokale Packages ein.
- Targets: `SoftwareRegisseur-iOS`, `SoftwareRegisseur-macOS`, `SoftwareRegisseurAgentService` (eingebettet unter `Contents/Library/LoginItems`, launchd-Plist unter `Contents/Library/LaunchAgents`), Testtargets.
- Build-Variablen kommen aus `Config/*.xcconfig` und der lokalen `Config/Local.xcconfig` (ADR-0013).

## Erwogene Alternativen

Eingechecktes `.xcworkspace`/`.xcodeproj` (Merge-Konflikte); Tuist (zusätzliche Toolchain, nicht installiert).

## Konsequenzen

Entwickler brauchen XcodeGen (`brew install xcodegen`); `Scripts/build.sh` erzeugt das Projekt automatisch. Projektänderungen erfolgen ausschließlich in `project.yml`.

## Verifikation / Akzeptanz

`Scripts/build.sh` erzeugt das Projekt und baut beide Apps unsigniert; Bundle-Layout-Prüfung im Skript. A01, A28.

## Verweise

- [Pflichtenheft](../../Software_Regisseur_1.0_Codex_Entwicklungsauftrag.md), Abschnitt T
- [ADR-0013](0013-mindestversionen-und-lokale-signierkonfiguration.md), [ADR-0020](0020-agent-service-unsandboxed-xpc.md)
- [ADR-Index](README.md)
