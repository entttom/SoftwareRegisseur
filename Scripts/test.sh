#!/bin/bash
# Führt alle Tests aus: zuerst `swift test` in jedem Swift Package unter Packages/ (nacheinander),
# danach die Xcode-Testtargets der Apps (unsigniert).
# Ein fehlschlagendes Paket bricht nicht sofort ab; der Exit-Code ist ≠ 0, wenn irgendein Lauf scheitert.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

derived_data="${DERIVED_DATA_PATH:-${repo_root}/DerivedData}"
failed=()

for package_dir in Packages/*/; do
    package_dir="${package_dir%/}"
    if [ ! -f "${package_dir}/Package.swift" ]; then
        continue
    fi
    echo "==> swift test: ${package_dir}"
    if ! (cd "${package_dir}" && swift test); then
        failed+=("${package_dir}")
    fi
done

if [ ! -f "Config/Local.xcconfig" ]; then
    echo "Fehler: Config/Local.xcconfig fehlt (ADR-0013)." >&2
    echo "Abhilfe: cp Config/Local.xcconfig.template Config/Local.xcconfig und Werte eintragen." >&2
    exit 1
fi

xcodegen generate

echo "==> xcodebuild test: SoftwareRegisseur-macOS"
if ! xcodebuild \
    -project "SoftwareRegisseur.xcodeproj" \
    -scheme "SoftwareRegisseur-macOS" \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "${derived_data}" \
    test CODE_SIGNING_ALLOWED=NO; then
    failed+=("xcodebuild test SoftwareRegisseur-macOS")
fi

if [ "${#failed[@]}" -gt 0 ]; then
    echo "Fehlgeschlagen:" >&2
    printf '  %s\n' "${failed[@]}" >&2
    exit 1
fi
echo "Alle Tests grün."
