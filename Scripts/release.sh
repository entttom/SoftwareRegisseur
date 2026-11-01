#!/bin/bash
# Reproduzierbarer macOS-Release-Build (Pflichtenheft Q3, ADR-0009, ADR-0017).
# Archiviert die Mac-App (inkl. Agent Service und Sparkle), exportiert sie mit Developer ID,
# erzeugt ein signiertes DMG und prüft das Ergebnis. Notarisierung: Scripts/sign-and-notarize.sh.
set -euo pipefail

# shellcheck source=Scripts/lib/release-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/release-common.sh"

usage() {
    cat <<'EOF'
Verwendung: Scripts/release.sh [Optionen] <version> <build>

Erzeugt einen Developer-ID-signierten Release der Mac-App:
  1. xcodegen generate
  2. xcodebuild archive (Release, MARKETING_VERSION=<version>, CURRENT_PROJECT_VERSION=<build>)
  3. Export mit method "developer-id" (Xcode signiert App, Agent Service und Sparkle
     mit "Developer ID Application", Hardened Runtime und sicherem Zeitstempel)
  4. DMG mit Verknüpfung auf /Applications, mit Developer ID signiert
  5. Scripts/verify-release.sh --pre-notarization auf das DMG

Argumente:
  <version>   Marketing-Version, Format X.Y.Z (z. B. 1.0.0)
  <build>     Build-Nummer, positive Ganzzahl; muss je Release steigen (Sparkle vergleicht sie)

Optionen:
  -o, --output <ordner>        Ausgabeordner (Standard: DerivedData/Releases/<version>-<build>)
      --allow-disabled-updates Release trotz Sparkle-Platzhaltern bauen; die App zeigt dann
                               "Updates deaktiviert" (nur für lokale Tests)
      --export-options <plist> Eigene ExportOptions.plist (z. B. manuelle Provisioning-Profile)
      --no-provisioning-updates
                               xcodebuild ohne -allowProvisioningUpdates aufrufen (dann müssen
                               passende Developer-ID-Profile bereits installiert sein)
  -h, --help                   Diese Hilfe

Voraussetzungen: Config/Local.xcconfig mit echten Werten (ADR-0013), Identität
"Developer ID Application: … (<Team-ID>)" im Schlüsselbund, in Xcode angemeldeter Account
des Teams (für Developer-ID-Provisioning-Profile von Agent Service/App).
Es wird nichts hochgeladen und nichts an Apple zur Notarisierung gesendet.
EOF
}

output=""
allow_disabled_updates=0
export_options_override=""
provisioning_flag=(-allowProvisioningUpdates)
positional=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        -o | --output) [ "$#" -ge 2 ] || sr_die "$1 braucht einen Ordner."; output="$2"; shift 2 ;;
        --allow-disabled-updates) allow_disabled_updates=1; shift ;;
        --export-options) [ "$#" -ge 2 ] || sr_die "$1 braucht eine Datei."; export_options_override="$2"; shift 2 ;;
        --no-provisioning-updates) provisioning_flag=(); shift ;;
        --) shift; positional+=("$@"); break ;;
        -*) sr_die "Unbekannte Option: $1 (siehe --help)" ;;
        *) positional+=("$1"); shift ;;
    esac
done

[ "${#positional[@]}" -eq 2 ] || { usage >&2; exit 2; }
version="${positional[0]}"
build="${positional[1]}"

[[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || sr_die "Version \"${version}\" hat nicht das Format X.Y.Z."
[[ "${build}" =~ ^[1-9][0-9]*$ ]] || sr_die "Build-Nummer \"${build}\" ist keine positive Ganzzahl."

cd "${SR_REPO_ROOT}"

for tool in xcodegen xcodebuild hdiutil codesign; do
    command -v "${tool}" > /dev/null 2>&1 || sr_die "${tool} nicht gefunden."
done

sr_step "Konfiguration prüfen (Config/Local.xcconfig, ADR-0013)"
sr_require_local_config
team="$(sr_local_config_value SR_DEVELOPMENT_TEAM)"
prefix="$(sr_local_config_value SR_BUNDLE_ID_PREFIX)"
container="$(sr_local_config_value SR_CLOUDKIT_CONTAINER)"
feed_url="$(sr_local_config_value SR_SPARKLE_FEED_URL)"
ed_key="$(sr_local_config_value SR_SPARKLE_PUBLIC_ED_KEY)"

[[ "${team}" =~ ^[A-Z0-9]{10}$ ]] && [ "${team}" != "${SR_PLACEHOLDER_TEAM}" ] \
    || sr_die "SR_DEVELOPMENT_TEAM ist kein echter 10-stelliger Team-Identifier (Vorlagenwert?)."
[ -n "${prefix}" ] && [ "${prefix}" != "${SR_PLACEHOLDER_PREFIX}" ] && [[ "${prefix}" =~ ^[A-Za-z0-9.-]+$ ]] \
    || sr_die "SR_BUNDLE_ID_PREFIX ist leer, ungültig oder noch der Vorlagenwert \"${SR_PLACEHOLDER_PREFIX}\"."
case "${container}" in
    iCloud.*) ;;
    *) sr_die "SR_CLOUDKIT_CONTAINER muss mit \"iCloud.\" beginnen." ;;
esac
case "${container}" in
    *"${SR_PLACEHOLDER_PREFIX}"*) sr_die "SR_CLOUDKIT_CONTAINER enthält noch den Vorlagenwert \"${SR_PLACEHOLDER_PREFIX}\"." ;;
esac
echo "Team ${team}, Bundle-ID-Präfix ${prefix}"

if sr_sparkle_config_is_real "${feed_url}" "${ed_key}"; then
    echo "Sparkle: Feed ${feed_url}, öffentlicher Schlüssel gesetzt"
elif [ "${allow_disabled_updates}" -eq 1 ]; then
    sr_warn "SR_SPARKLE_FEED_URL/SR_SPARKLE_PUBLIC_ED_KEY sind Platzhalter oder ungültig. Die App wird mit DEAKTIVIERTEN Updates gebaut (--allow-disabled-updates). Nicht verteilen."
else
    sr_die "SR_SPARKLE_FEED_URL/SR_SPARKLE_PUBLIC_ED_KEY sind noch Platzhalter oder ungültig (ADR-0017). Einrichtung: docs/release/README.md. Für reine Signatur-Tests: --allow-disabled-updates."
fi

identity_hash="$(sr_developer_id_identity_hash "${team}")"
echo "Signieridentität \"Developer ID Application\" für Team ${team} vorhanden"

sr_step "Git-Stand"
git_commit="keine Commits"
git_dirty="unbekannt"
if git -C "${SR_REPO_ROOT}" rev-parse --verify --quiet HEAD > /dev/null 2>&1; then
    git_commit="$(git -C "${SR_REPO_ROOT}" rev-parse HEAD)"
    if [ -n "$(git -C "${SR_REPO_ROOT}" status --porcelain)" ]; then
        git_dirty="ja"
        sr_warn "Arbeitsbaum enthält nicht committete Änderungen – der Release ist nicht aus einem Commit reproduzierbar."
    else
        git_dirty="nein"
    fi
    echo "Commit ${git_commit} (nicht committete Änderungen: ${git_dirty})"
else
    sr_warn "Repository hat noch keine Commits – der Release ist keinem Commit zuordenbar."
fi

if [ -z "${output}" ]; then
    output="${SR_REPO_ROOT}/DerivedData/Releases/${version}-${build}"
fi
if [ -e "${output}" ] && [ -n "$(ls -A "${output}" 2> /dev/null)" ]; then
    sr_die "Ausgabeordner ${output} existiert und ist nicht leer. Anderen Ordner wählen oder ihn selbst entfernen."
fi
mkdir -p "${output}"
output="$(cd "${output}" && pwd)"
archive="${output}/${SR_APP_NAME}.xcarchive"
export_dir="${output}/export"
derived_data="${output}/DerivedData"
logs="${output}/logs"
mkdir -p "${logs}"

run_logged() {
    local log="$1"
    shift
    if ! "$@" > "${log}" 2>&1; then
        echo "--- letzte Zeilen aus ${log} ---" >&2
        tail -n 40 "${log}" >&2
        sr_die "Schritt fehlgeschlagen, vollständiges Protokoll: ${log}"
    fi
}

sr_step "Xcode-Projekt erzeugen (xcodegen)"
run_logged "${logs}/xcodegen.log" xcodegen generate

sr_step "Archivieren (Release ${version} / ${build})"
run_logged "${logs}/archive.log" xcodebuild archive \
    -project "${SR_PROJECT}" \
    -scheme "${SR_MAC_SCHEME}" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "${archive}" \
    -derivedDataPath "${derived_data}" \
    ${provisioning_flag[@]+"${provisioning_flag[@]}"} \
    MARKETING_VERSION="${version}" \
    CURRENT_PROJECT_VERSION="${build}"
echo "Archiv: ${archive}"

if [ -n "${export_options_override}" ]; then
    [ -f "${export_options_override}" ] || sr_die "ExportOptions-Datei ${export_options_override} nicht gefunden."
    export_options="${export_options_override}"
else
    export_options="${output}/ExportOptions.plist"
    cat > "${export_options}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>${team}</string>
	<key>destination</key>
	<string>export</string>
</dict>
</plist>
PLIST
    /usr/bin/plutil -lint "${export_options}" > /dev/null
fi

sr_step "Exportieren mit Developer ID"
run_logged "${logs}/export.log" xcodebuild -exportArchive \
    -archivePath "${archive}" \
    -exportPath "${export_dir}" \
    -exportOptionsPlist "${export_options}" \
    ${provisioning_flag[@]+"${provisioning_flag[@]}"}
app="${export_dir}/${SR_APP_NAME}.app"
[ -d "${app}" ] || sr_die "Export enthält keine ${SR_APP_NAME}.app (siehe ${logs}/export.log)."

built_version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${app}/Contents/Info.plist")"
built_build="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${app}/Contents/Info.plist")"
[ "${built_version}" = "${version}" ] && [ "${built_build}" = "${build}" ] \
    || sr_die "App meldet Version ${built_version} (${built_build}) statt ${version} (${build})."
/usr/bin/codesign --verify --deep --strict "${app}" || sr_die "Signatur der exportierten App ist ungültig."
echo "App: ${app}"

sr_step "DMG erstellen"
dmg="${output}/${SR_APP_NAME}-${version}.dmg"
staging="${output}/dmg-staging"
mkdir -p "${staging}"
/usr/bin/ditto "${app}" "${staging}/${SR_APP_NAME}.app"
ln -s /Applications "${staging}/Applications"
run_logged "${logs}/hdiutil.log" /usr/bin/hdiutil create \
    -volname "Software Regisseur ${version}" \
    -srcfolder "${staging}" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "${dmg}"
rm -rf "${staging}"

sr_step "DMG mit Developer ID signieren"
run_logged "${logs}/codesign-dmg.log" /usr/bin/codesign --sign "${identity_hash}" --timestamp "${dmg}"
/usr/bin/codesign --verify --strict "${dmg}" || sr_die "Signatur des DMG ist ungültig."

(cd "${output}" && /usr/bin/shasum -a 256 "$(basename "${dmg}")" > "$(basename "${dmg}").sha256")

sparkle_version="$(sr_pinned_sparkle_version)"
cat > "${output}/release-info.txt" <<INFO
Software Regisseur ${version} (Build ${build})
Erstellt: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
Team: ${team}
Bundle-ID: ${prefix}.SoftwareRegisseur.Mac
Git-Commit: ${git_commit}
Nicht committete Änderungen: ${git_dirty}
Xcode: $(xcodebuild -version | tr '\n' ' ')
Sparkle: ${sparkle_version}
Sparkle-Updates aktiv: $(sr_sparkle_config_is_real "${feed_url}" "${ed_key}" && echo ja || echo "nein (Platzhalter)")
DMG SHA-256: $(cut -d ' ' -f 1 "${dmg}.sha256")
Notarisiert: nein (Scripts/sign-and-notarize.sh)
INFO

sr_step "Release prüfen (vor Notarisierung)"
verify_args=(--pre-notarization --expected-version "${version}" --expected-build "${build}")
if [ "${allow_disabled_updates}" -eq 1 ]; then
    verify_args+=(--allow-disabled-updates)
fi
"${SR_REPO_ROOT}/Scripts/verify-release.sh" "${verify_args[@]}" "${dmg}"

echo
echo "Fertig: ${dmg}"
echo "Nächste Schritte:"
echo "  1. Scripts/sign-and-notarize.sh \"${dmg}\" --keychain-profile <profil>"
echo "  2. Scripts/make-appcast.sh --archives <release-ordner> --tag v${version}"
echo "  Details: docs/release/README.md"
