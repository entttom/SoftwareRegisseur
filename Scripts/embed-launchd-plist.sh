#!/bin/bash
# Build-Phase „launchd-Plist einbetten“ (ADR-0020).
# Schreibt die Plist für SMAppService.agent(plistName:) nach Contents/Library/LaunchAgents.
# Die Werte kommen aus Build-Variablen (Config/Base.xcconfig + Config/Local.xcconfig, ADR-0013).
set -euo pipefail

: "${SCRIPT_OUTPUT_FILE_0:?Ausgabedatei der Build-Phase fehlt}"
: "${SR_AGENT_BUNDLE_ID:?}"
: "${SR_AGENT_PRODUCT_NAME:?}"
: "${SR_AGENT_MACH_SERVICE:?}"
: "${PRODUCT_BUNDLE_IDENTIFIER:?}"

# Nur Zeichen zulassen, die in Bundle-IDs und Mach-Service-Namen gültig sind; verhindert kaputtes XML.
for value in "${SR_AGENT_BUNDLE_ID}" "${SR_AGENT_PRODUCT_NAME}" "${SR_AGENT_MACH_SERVICE}" "${PRODUCT_BUNDLE_IDENTIFIER}"; do
    if [[ ! "${value}" =~ ^[A-Za-z0-9.-]+$ ]]; then
        echo "error: Ungültiger Wert für die launchd-Plist: \"${value}\". Config/Local.xcconfig prüfen."
        exit 1
    fi
done

plist="${SCRIPT_OUTPUT_FILE_0}"
program="Contents/Library/LoginItems/${SR_AGENT_PRODUCT_NAME}.app/Contents/MacOS/${SR_AGENT_PRODUCT_NAME}"

mkdir -p "$(dirname "${plist}")"
cat > "${plist}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${SR_AGENT_BUNDLE_ID}</string>
	<key>BundleProgram</key>
	<string>${program}</string>
	<key>MachServices</key>
	<dict>
		<key>${SR_AGENT_MACH_SERVICE}</key>
		<true/>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>ProcessType</key>
	<string>Adaptive</string>
	<key>AssociatedBundleIdentifiers</key>
	<array>
		<string>${PRODUCT_BUNDLE_IDENTIFIER}</string>
	</array>
</dict>
</plist>
PLIST

/usr/bin/plutil -lint "${plist}" > /dev/null
