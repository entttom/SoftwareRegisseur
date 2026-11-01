# GitHub-Konfiguration

## `workflows/ci.yml` – Continuous Integration (Pflichtenheft T, M1)

Läuft bei Push auf `main`, bei Pull Requests und manuell (`workflow_dispatch`). Benötigt **keine Secrets**.

| Job | Runner | Inhalt |
|-----|--------|--------|
| `discover-packages` | `ubuntu-latest` | Listet alle `Packages/*/Package.swift` als Matrix auf. |
| `package-tests` | `xcode-27` | `swift test` je Paket (Matrix, `fail-fast: false`); `.build` je Paket gecacht, Schlüssel: Paket, Xcode-Version, `Package.resolved`/`Package.swift`. |
| `apps` | `xcode-27` | XcodeGen per Homebrew, `Config/Local.xcconfig` aus der Vorlage, `Scripts/build.sh` (macOS-App inkl. Agent Service und iOS-Simulator-App, unsigniert, Bundle-Layout-Prüfung), danach `xcodebuild test` für `SoftwareRegisseur-macOS`. Bei Fehlern wird das `.xcresult` hochgeladen. |

### Runner und Xcode

- Label `xcode-27`: GitHub-Image „macOS 27 mit Xcode 27“ (Status *Preview*, siehe
  [actions/runner-images#14404](https://github.com/actions/runner-images/issues/14404) und
  [xcode-27-arm64-Readme](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)).
  Das GA-Image `macos-26` enthält nur Xcode 26.x und reicht nicht (`xcodeVersion: "27.0"`, Swift 6.4).
- Xcode wird über `DEVELOPER_DIR=/Applications/Xcode_27.0.app/Contents/Developer` fest auf 27.0 (27A266a)
  gesetzt – die Version der lokalen Entwicklungsumgebung (ADR-0013). Das Image-Standard-Xcode kann sich
  ändern; Anhebung bewusst über `XCODE_VERSION`/`DEVELOPER_DIR` in `ci.yml`.
- Fällt das Preview-Label weg oder wird umbenannt: auf das GA-Label wechseln, das Xcode 27 enthält, und
  `DEVELOPER_DIR` auf den dort dokumentierten Pfad setzen (alternativ `sudo xcode-select -s …`).

### Signierung in der CI (ADR-0013)

`Config/Local.xcconfig` wird aus `Config/Local.xcconfig.template` kopiert; das Platzhalter-Team
`XXXXXXXXXX` bleibt bewusst stehen. `Config/Base.xcconfig` stellt dafür auf Ad-hoc-Signatur und leere
Entitlements um, und `Scripts/check-signing-config.sh` endet bei `CODE_SIGNING_ALLOWED=NO` erfolgreich.
Echte Team-ID, Bundle-ID-Präfix, CloudKit-Container oder Schlüssel gelangen nie in die CI.

### Actions-Pinning

Drittanbieter-Actions sind auf volle Commit-SHAs gepinnt, die Version steht im Kommentar
(`actions/checkout` v7.0.1, `actions/cache` v6.1.0, `actions/upload-artifact` v7.0.2).
`dependabot.yml` schlägt Aktualisierungen wöchentlich vor.

## Warum es keinen Release-Workflow gibt

Releases werden **lokal auf dem Release-Mac** erzeugt (`Scripts/release.sh`, `Scripts/sign-and-notarize.sh`,
`Scripts/make-appcast.sh`, `Scripts/verify-release.sh`):

- **ADR-0017:** Der private EdDSA-Schlüssel für Sparkle liegt ausschließlich im Schlüsselbund des
  Release-Macs, nie im Repository oder in CI-Logs. Ohne ihn lassen sich Appcast und Update-Archive nicht
  signieren (`SURequireSignedFeed`), ein CI-Release wäre also unvollständig.
- **ADR-0009:** Developer-ID-Zertifikat und Notarisierungs-Zugangsdaten müssten sonst als GitHub-Secrets
  hinterlegt werden; das ist für v1 nicht vorgesehen (AGENTS.md: keine Geheimnisse in Git, CloudKit oder Logs).
- Das öffentliche Release-Repository für Appcast und DMG existiert noch nicht (ADR-0017, Stand 2026-10-30).

Ein späterer CI-Release erfordert einen neuen ADR (Umgang mit Zertifikat, Notarisierung und EdDSA-Schlüssel).
