#!/bin/bash
# Build-Phase „Signierkonfiguration prüfen“ (ADR-0013).
# Bricht signierte Builds ab, solange Config/Local.xcconfig noch die Vorlagenwerte enthält.
# Unsignierte Prüf-Builds (CODE_SIGNING_ALLOWED=NO, siehe Scripts/build.sh) laufen weiter.
set -euo pipefail

if [ "${CODE_SIGNING_ALLOWED:-YES}" != "YES" ]; then
    exit 0
fi

team="${SR_DEVELOPMENT_TEAM:-}"
placeholder="${SR_TEMPLATE_TEAM_PLACEHOLDER:-XXXXXXXXXX}"

if [ -z "${team}" ] || [ "${team}" = "${placeholder}" ]; then
    echo "error: Config/Local.xcconfig enthält noch keine echte Apple-Team-ID (SR_DEVELOPMENT_TEAM = \"${team}\")."
    echo "error: Bitte die eigene Team-ID (developer.apple.com → Membership) sowie SR_BUNDLE_ID_PREFIX und SR_CLOUDKIT_CONTAINER in Config/Local.xcconfig eintragen (ADR-0013)."
    echo "error: Für unsignierte Prüf-Builds CODE_SIGNING_ALLOWED=NO setzen, z. B. mit Scripts/build.sh."
    exit 1
fi
