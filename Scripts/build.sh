#!/bin/bash
# Erzeugt SoftwareRegisseur.xcodeproj und baut beide Apps unsigniert (CI / lokale Prüfung).
# Signierte Builds laufen über Xcode bzw. die Release-Skripte mit echter Config/Local.xcconfig (ADR-0013).
#
# Umgebungsvariablen: CONFIGURATION (Debug|Release, Standard Debug), DERIVED_DATA_PATH.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

configuration="${CONFIGURATION:-Debug}"
derived_data="${DERIVED_DATA_PATH:-${repo_root}/DerivedData}"

if [ ! -f "Config/Local.xcconfig" ]; then
    echo "Fehler: Config/Local.xcconfig fehlt (ADR-0013)." >&2
    echo "Abhilfe: cp Config/Local.xcconfig.template Config/Local.xcconfig und Werte eintragen." >&2
    exit 1
fi
if ! command -v xcodegen > /dev/null 2>&1; then
    echo "Fehler: xcodegen nicht gefunden (brew install xcodegen)." >&2
    exit 1
fi

xcodegen generate

echo "==> macOS-App inkl. Agent Service (${configuration}, unsigniert)"
xcodebuild \
    -project "SoftwareRegisseur.xcodeproj" \
    -scheme "SoftwareRegisseur-macOS" \
    -configuration "${configuration}" \
    -destination "platform=macOS" \
    -derivedDataPath "${derived_data}" \
    build CODE_SIGNING_ALLOWED=NO

echo "==> iOS-App für den Simulator (${configuration}, unsigniert)"
xcodebuild \
    -project "SoftwareRegisseur.xcodeproj" \
    -scheme "SoftwareRegisseur-iOS" \
    -configuration "${configuration}" \
    -destination "generic/platform=iOS Simulator" \
    -derivedDataPath "${derived_data}" \
    build CODE_SIGNING_ALLOWED=NO

echo "==> Bundle-Struktur der macOS-App prüfen (ADR-0020)"
app="${derived_data}/Build/Products/${configuration}/SoftwareRegisseur.app"
agent="${app}/Contents/Library/LoginItems/SoftwareRegisseurAgentService.app"
agent_executable="${agent}/Contents/MacOS/SoftwareRegisseurAgentService"
plist_name="$(/usr/libexec/PlistBuddy -c "Print :SRAgentLaunchdPlistName" "${app}/Contents/Info.plist")"
launchd_plist="${app}/Contents/Library/LaunchAgents/${plist_name}"

for path in "${agent_executable}" "${launchd_plist}"; do
    if [ ! -e "${path}" ]; then
        echo "Fehler: ${path} fehlt im App-Bundle." >&2
        exit 1
    fi
done
bundle_program="$(/usr/libexec/PlistBuddy -c "Print :BundleProgram" "${launchd_plist}")"
if [ ! -x "${app}/${bundle_program}" ]; then
    echo "Fehler: BundleProgram ${bundle_program} zeigt auf keine ausführbare Datei." >&2
    exit 1
fi
echo "OK: ${agent_executable#"${app}/"}"
echo "OK: ${launchd_plist#"${app}/"} (BundleProgram ${bundle_program})"
