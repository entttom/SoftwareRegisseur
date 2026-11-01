#!/bin/bash
# Überträgt alle im Code verwendeten UI-Strings in die String Catalogs der Apps (Pflichtenheft P).
# Xcode macht das in der IDE beim Bauen automatisch; dieses Skript leistet dasselbe für xcodebuild/CI.
#
# Verwendung: Scripts/sync-string-catalogs.sh [DerivedData-Pfad]
# Ohne Argument wird unsigniert in ein temporäres DerivedData gebaut.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

derived_data="${1:-}"
cleanup=""
if [ -z "${derived_data}" ]; then
    derived_data="$(mktemp -d "${TMPDIR:-/tmp}/sr-strings.XXXXXX")"
    cleanup="${derived_data}"
    xcodegen generate --quiet
    xcodebuild -quiet -project "SoftwareRegisseur.xcodeproj" -scheme "SoftwareRegisseur-macOS" \
        -configuration Debug -derivedDataPath "${derived_data}" build CODE_SIGNING_ALLOWED=NO
    xcodebuild -quiet -project "SoftwareRegisseur.xcodeproj" -scheme "SoftwareRegisseur-iOS" \
        -configuration Debug -destination "generic/platform=iOS Simulator" \
        -derivedDataPath "${derived_data}" build CODE_SIGNING_ALLOWED=NO
fi

intermediates="${derived_data}/Build/Intermediates.noindex/SoftwareRegisseur.build"

sync_catalog() {
    local catalog="$1"
    local target_dir="$2"
    local files=()
    while IFS= read -r -d '' file; do
        files+=("--stringsdata" "${file}")
    done < <(find "${intermediates}" -path "*/${target_dir}/Objects-normal/arm64/*.stringsdata" \
        ! -name "ExtractedAppShortcutsMetadata.stringsdata" -print0)
    if [ "${#files[@]}" -eq 0 ]; then
        echo "error: Keine .stringsdata für ${target_dir} unter ${intermediates} gefunden." >&2
        exit 1
    fi
    xcrun xcstringstool sync "${catalog}" "${files[@]}"
    echo "Aktualisiert: ${catalog}"
}

sync_catalog "Apps/SoftwareRegisseur-macOS/Resources/Localizable.xcstrings" "SoftwareRegisseur-macOS.build"
sync_catalog "Apps/SoftwareRegisseur-iOS/Resources/Localizable.xcstrings" "SoftwareRegisseur-iOS.build"

if [ -n "${cleanup}" ]; then
    rm -rf "${cleanup}"
fi
