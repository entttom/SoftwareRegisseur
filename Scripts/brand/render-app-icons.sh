#!/bin/bash
# Erzeugt die App-Icon-PNGs für iOS und macOS aus den Vorlagen in docs/brand/.
# Nach jeder Änderung an docs/brand/app-icon-*.svg erneut ausführen; das Menüleisten-Symbol ist Vektor und braucht das nicht.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BRAND="${ROOT}/docs/brand"
IOS_SET="${ROOT}/Apps/SoftwareRegisseur-iOS/Resources/Assets.xcassets/AppIcon.appiconset"
MAC_SET="${ROOT}/Apps/SoftwareRegisseur-macOS/Resources/Assets.xcassets/AppIcon.appiconset"

RENDERER="$(mktemp -d)/render-svg"
trap 'rm -rf "$(dirname "${RENDERER}")"' EXIT
xcrun swiftc -O "${ROOT}/Scripts/brand/render-svg.swift" -o "${RENDERER}"

"${RENDERER}" "${BRAND}/app-icon-ios.svg" "${IOS_SET}/AppIcon-1024.png" 1024 --opaque

for size in 16 32 128 256 512; do
    "${RENDERER}" "${BRAND}/app-icon-macos.svg" "${MAC_SET}/AppIcon-${size}.png" "${size}"
    "${RENDERER}" "${BRAND}/app-icon-macos.svg" "${MAC_SET}/AppIcon-${size}@2x.png" "$((size * 2))"
done

echo "App-Icons erzeugt."
