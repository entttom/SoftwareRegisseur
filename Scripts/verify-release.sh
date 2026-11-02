#!/bin/bash
# SC2015: ok/fail/note/expected geben immer 0 zurück, "A && ok || fail" ist hier eindeutig.
# SC2016: '$(' wird bewusst wörtlich gesucht (unaufgelöste Build-Variablen).
# shellcheck disable=SC2015,SC2016
# Prüft einen Mac-Release (App-Bundle oder DMG) gegen Pflichtenheft Q3 und ADR-0009/0017/0020:
# Signaturen, Gatekeeper, Notarisierungsticket, Hardened Runtime, Entitlements,
# eingebetteten Agent Service samt launchd-Plist, Platzhalter und Geheimnisse.
# Ausgabe: je Prüfung OK / ERWARTET / HINWEIS / FEHLER; Exit-Code 1 bei mindestens einem FEHLER.
set -euo pipefail
# shellcheck source=Scripts/lib/release-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/release-common.sh"

usage() {
    cat <<'EOF'
Verwendung: Scripts/verify-release.sh [Optionen] <SoftwareRegisseur.app | SoftwareRegisseur-X.Y.Z.dmg>

Prüft:
  - codesign --verify --deep --strict (App) bzw. --strict (DMG)
  - spctl -a -t exec (App) und spctl -a -t open --context context:primary-signature (DMG)
  - xcrun stapler validate (Notarisierungsticket)
  - Developer-ID-Signatur, Team, sicherer Zeitstempel und Hardened Runtime aller ausführbaren Teile
  - Entitlements von App und Agent Service (erwartete Schlüssel, kein get-task-allow, keine Sandbox)
  - Developer-ID-Provisioning-Profil im Agent Service
  - eingebetteter Agent Service und launchd-Plist (ADR-0020)
  - Sparkle-Framework-Version und Info.plist-Schlüssel (ADR-0017)
  - keine Vorlagen-Platzhalter, keine unaufgelösten $(…)-Variablen, keine Schlüssel-/Token-Muster

Optionen:
  --pre-notarization         Fehlende Notarisierung (spctl "Unnotarized Developer ID", kein Ticket)
                             als ERWARTET statt FEHLER werten
  --allow-disabled-updates   Sparkle-Platzhalter als HINWEIS statt FEHLER werten
  --expected-version <X.Y.Z> CFBundleShortVersionString muss passen
  --expected-build <n>       CFBundleVersion muss passen
  -h, --help                 Diese Hilfe
EOF
}

pre_notarization=0
allow_disabled_updates=0
expected_version=""
expected_build=""
target=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --pre-notarization) pre_notarization=1; shift ;;
        --allow-disabled-updates) allow_disabled_updates=1; shift ;;
        --expected-version) [ "$#" -ge 2 ] || sr_die "$1 braucht einen Wert."; expected_version="$2"; shift 2 ;;
        --expected-build) [ "$#" -ge 2 ] || sr_die "$1 braucht einen Wert."; expected_build="$2"; shift 2 ;;
        -*) sr_die "Unbekannte Option: $1 (siehe --help)" ;;
        *) [ -z "${target}" ] || sr_die "Nur ein Pfad erlaubt."; target="$1"; shift ;;
    esac
done
[ -n "${target}" ] || { usage >&2; exit 2; }
[ -e "${target}" ] || sr_die "${target} existiert nicht."
target="$(cd "$(dirname "${target}")" && pwd)/$(basename "${target}")"

ok_count=0
fail_count=0
expected_count=0
note_count=0
ok() { echo "  OK       $*"; ok_count=$((ok_count + 1)); }
fail() { echo "  FEHLER   $*"; fail_count=$((fail_count + 1)); }
note() { echo "  HINWEIS  $*"; note_count=$((note_count + 1)); }
expected() { echo "  ERWARTET $*"; expected_count=$((expected_count + 1)); }
# Fehlende Notarisierung ist vor dem Einreichen erwartet, danach ein Fehler.
notarization_issue() {
    if [ "${pre_notarization}" -eq 1 ]; then expected "$*"; else fail "$*"; fi
}
section() { echo; echo "== $*"; }

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/sr-verify.XXXXXX")"
mount_point=""
cleanup() {
    if [ -n "${mount_point}" ] && [ -d "${mount_point}" ]; then
        /usr/bin/hdiutil detach "${mount_point}" -quiet 2> /dev/null \
            || /usr/bin/hdiutil detach "${mount_point}" -force -quiet 2> /dev/null || true
    fi
    rm -rf "${work_dir}"
}
trap cleanup EXIT

# Wertet spctl aus: nur "source=Notarized Developer ID" gilt als notarisiert. Nicht notarisierte
# Developer-ID-Signaturen meldet spctl je nach Prüfart als "rejected … Unnotarized Developer ID"
# oder (ohne Quarantäne-Attribut) als "accepted … source=Developer ID".
check_spctl() {
    local label="$1"
    shift
    local result rc=0
    result="$(/usr/sbin/spctl "$@" 2>&1)" || rc=$?
    local verdict details summary
    verdict="$(printf '%s\n' "${result}" | /usr/bin/head -n 1 | /usr/bin/sed 's/.*: //')"
    details="$(printf '%s\n' "${result}" | /usr/bin/tail -n +2 | /usr/bin/tr '\n' ' ')"
    summary="${verdict} ${details% }"
    if [ "${rc}" -eq 0 ] && printf '%s' "${result}" | /usr/bin/grep -q "source=Notarized Developer ID"; then
        ok "${label}: ${summary}"
    elif printf '%s' "${result}" | /usr/bin/grep -Eq "source=(Unnotarized )?Developer ID"; then
        notarization_issue "${label}: ${summary} (nicht notarisiert)"
    else
        fail "${label}: ${summary}"
    fi
}

check_stapler() {
    local label="$1" path="$2" missing_is_note="${3:-0}"
    local result rc=0
    result="$(/usr/bin/xcrun stapler validate "${path}" 2>&1)" || rc=$?
    if [ "${rc}" -eq 0 ]; then
        ok "${label}: Notarisierungsticket angeheftet (stapler validate)"
    elif [ "${missing_is_note}" -eq 1 ]; then
        note "${label}: kein eigenes Ticket angeheftet – das Ticket hängt am DMG, Gatekeeper prüft die App online"
    else
        notarization_issue "${label}: $(printf '%s' "${result}" | /usr/bin/tail -n 1)"
    fi
}

# --- DMG: Container prüfen und einhängen -------------------------------------------------------
app=""
case "${target}" in
    *.dmg)
        section "DMG $(basename "${target}")"
        if /usr/bin/codesign --verify --strict --verbose=2 "${target}" > "${work_dir}/dmg-verify.txt" 2>&1; then
            ok "codesign --verify --strict"
        else
            fail "codesign --verify --strict: $(/usr/bin/tail -n 1 "${work_dir}/dmg-verify.txt")"
        fi
        dmg_info="$(/usr/bin/codesign -d --verbose=4 "${target}" 2>&1 || true)"
        if printf '%s\n' "${dmg_info}" | /usr/bin/grep -q '^Authority=Developer ID Application:'; then
            ok "DMG mit Developer ID Application signiert"
        else
            fail "DMG nicht mit Developer ID Application signiert"
        fi
        if printf '%s\n' "${dmg_info}" | /usr/bin/grep -q '^Timestamp='; then
            ok "DMG-Signatur mit sicherem Zeitstempel"
        else
            fail "DMG-Signatur ohne sicheren Zeitstempel"
        fi
        check_spctl "spctl -a -t open --context context:primary-signature" -a -t open --context context:primary-signature -vv "${target}"
        check_stapler "DMG" "${target}"

        mount_point="${work_dir}/mnt"
        mkdir -p "${mount_point}"
        if ! /usr/bin/hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "${mount_point}" "${target}" \
            > /dev/null 2> "${work_dir}/attach.err"; then
            cat "${work_dir}/attach.err" >&2
            sr_die "DMG konnte nicht eingehängt werden."
        fi
        app="${mount_point}/${SR_APP_NAME}.app"
        [ -d "${app}" ] || sr_die "DMG enthält keine ${SR_APP_NAME}.app."
        if [ -L "${mount_point}/Applications" ] && [ "$(readlink "${mount_point}/Applications")" = "/Applications" ]; then
            ok "Verknüpfung auf /Applications vorhanden"
        else
            note "keine Verknüpfung auf /Applications im DMG"
        fi
        app_in_dmg=1
        ;;
    *.app)
        app="${target}"
        app_in_dmg=0
        ;;
    *) sr_die "Erwartet wird eine .app oder .dmg." ;;
esac

info_plist="${app}/Contents/Info.plist"
plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2> /dev/null || true; }

# --- App-Signatur und Gatekeeper ---------------------------------------------------------------
section "App $(basename "${app}") $(plist_value "${info_plist}" CFBundleShortVersionString) ($(plist_value "${info_plist}" CFBundleVersion))"
if /usr/bin/codesign --verify --deep --strict --verbose=2 "${app}" > "${work_dir}/app-verify.txt" 2>&1; then
    ok "codesign --verify --deep --strict"
else
    fail "codesign --verify --deep --strict: $(/usr/bin/tail -n 1 "${work_dir}/app-verify.txt")"
fi
check_spctl "spctl -a -t exec" -a -t exec -vv "${app}"
check_stapler "App" "${app}" "${app_in_dmg}"

app_version="$(plist_value "${info_plist}" CFBundleShortVersionString)"
app_build="$(plist_value "${info_plist}" CFBundleVersion)"
if [ -n "${expected_version}" ]; then
    [ "${app_version}" = "${expected_version}" ] && ok "Version ${app_version}" || fail "Version ${app_version}, erwartet ${expected_version}"
fi
if [ -n "${expected_build}" ]; then
    [ "${app_build}" = "${expected_build}" ] && ok "Build ${app_build}" || fail "Build ${app_build}, erwartet ${expected_build}"
fi

# --- Alle ausführbaren Teile: Developer ID, Team, Zeitstempel, Hardened Runtime ----------------
section "Signaturen aller Mach-O-Dateien"
team=""
app_team="$(/usr/bin/codesign -d --verbose=4 "${app}" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p')"
if [[ "${app_team}" =~ ^[A-Z0-9]{10}$ ]] && [ "${app_team}" != "${SR_PLACEHOLDER_TEAM}" ]; then
    team="${app_team}"
    ok "Team-ID der App: ${team}"
else
    fail "Team-ID der App fehlt oder ist ungültig (\"${app_team}\")"
fi

macho_count=0
while IFS= read -r -d '' file; do
    file_type="$(/usr/bin/file -b "${file}")"
    case "${file_type}" in
        *Mach-O*) ;;
        *) continue ;;
    esac
    macho_count=$((macho_count + 1))
    rel="${file#"${app}/"}"
    sig="$(/usr/bin/codesign -d --verbose=4 "${file}" 2>&1 || true)"
    problems=()
    printf '%s\n' "${sig}" | /usr/bin/grep -q '^Authority=Developer ID Application:' || problems+=("keine Developer-ID-Signatur")
    file_team="$(printf '%s\n' "${sig}" | /usr/bin/sed -n 's/^TeamIdentifier=//p')"
    [ -n "${team}" ] && [ "${file_team}" = "${team}" ] || problems+=("Team \"${file_team}\" statt \"${team}\"")
    printf '%s\n' "${sig}" | /usr/bin/grep -q '^Timestamp=' || problems+=("kein sicherer Zeitstempel")
    is_executable=0
    case "${file_type}" in
        *executable*) is_executable=1 ;;
    esac
    has_runtime=0
    printf '%s\n' "${sig}" | /usr/bin/grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]*\([^)]*runtime' && has_runtime=1
    if [ "${is_executable}" -eq 1 ] && [ "${has_runtime}" -eq 0 ]; then
        problems+=("Hardened Runtime fehlt")
    fi
    if [ "${is_executable}" -eq 1 ]; then
        /usr/bin/codesign -d --entitlements - --xml "${file}" > "${work_dir}/ent.plist" 2> /dev/null || true
        if [ -s "${work_dir}/ent.plist" ] \
            && [ "$(plist_value "${work_dir}/ent.plist" com.apple.security.get-task-allow)" = "true" ]; then
            problems+=("com.apple.security.get-task-allow = true")
        fi
    fi
    kind="Bibliothek"
    [ "${is_executable}" -eq 1 ] && kind="Programm"
    runtime_label="ohne Hardened Runtime"
    [ "${has_runtime}" -eq 1 ] && runtime_label="Hardened Runtime"
    if [ "${#problems[@]}" -eq 0 ]; then
        ok "${rel} (${kind}, Developer ID, ${runtime_label}, Zeitstempel)"
    else
        fail "${rel}: $(IFS=';'; echo "${problems[*]}")"
    fi
done < <(/usr/bin/find "${app}" -type f -perm +111 -print0)
[ "${macho_count}" -gt 0 ] || fail "keine Mach-O-Dateien gefunden"

# --- Entitlements ------------------------------------------------------------------------------
dump_entitlements() {
    local label="$1" path="$2" out="$3"
    /usr/bin/codesign -d --entitlements - --xml "${path}" > "${out}" 2> /dev/null || true
    echo "  -- Entitlements ${label}:"
    if [ -s "${out}" ]; then
        /usr/bin/plutil -p "${out}" | /usr/bin/sed 's/^/     /'
    else
        echo "     (keine)"
    fi
}

expect_key() {
    local label="$1" plist="$2" key="$3" must_contain="${4:-}"
    local value
    value="$(plist_value "${plist}" "${key}")"
    if [ -z "${value}" ]; then
        fail "${label}: Entitlement ${key} fehlt"
    elif [[ "${value}" == *'$('* ]]; then
        fail "${label}: Entitlement ${key} enthält unaufgelöste Build-Variable"
    elif [ -n "${must_contain}" ] && [[ "${value}" != *"${must_contain}"* ]]; then
        fail "${label}: Entitlement ${key} enthält nicht \"${must_contain}\""
    else
        ok "${label}: ${key}"
    fi
}

expect_no_sandbox() {
    local label="$1" plist="$2"
    if [ "$(plist_value "${plist}" com.apple.security.app-sandbox)" = "true" ]; then
        note "${label}: App Sandbox aktiv – weicht von ADR-0020 ab (bewusst?)"
    else
        ok "${label}: ohne App Sandbox (ADR-0020)"
    fi
}

check_profile() {
    local label="$1" bundle="$2"
    local profile="${bundle}/Contents/embedded.provisionprofile"
    if [ ! -f "${profile}" ]; then
        fail "${label}: kein embedded.provisionprofile (CloudKit/Keychain-Group brauchen ein Developer-ID-Profil)"
        return
    fi
    local decoded="${work_dir}/profile-$$.plist"
    if ! /usr/bin/security cms -D -i "${profile}" > "${decoded}" 2> /dev/null; then
        fail "${label}: Provisioning-Profil nicht lesbar"
        return
    fi
    local all_devices profile_team expires expires_epoch
    all_devices="$(plist_value "${decoded}" ProvisionsAllDevices)"
    profile_team="$(plist_value "${decoded}" TeamIdentifier:0)"
    expires="$(plist_value "${decoded}" ExpirationDate)"
    if [ "${all_devices}" = "true" ]; then
        ok "${label}: Developer-ID-Provisioning-Profil (ProvisionsAllDevices)"
    else
        fail "${label}: Provisioning-Profil ist kein Developer-ID-Profil"
    fi
    [ "${profile_team}" = "${team}" ] && ok "${label}: Profil gehört zu Team ${team}" || fail "${label}: Profil-Team \"${profile_team}\""
    expires_epoch="$(/bin/date -j -f "%a %b %d %T %Z %Y" "${expires}" +%s 2> /dev/null || echo 0)"
    if [ "${expires_epoch}" -gt "$(/bin/date +%s)" ]; then
        ok "${label}: Profil gültig bis ${expires}"
    else
        fail "${label}: Profil abgelaufen oder Datum unlesbar (${expires})"
    fi
}

section "Entitlements und Provisioning"
app_ent="${work_dir}/app-entitlements.plist"
dump_entitlements "App" "${app}" "${app_ent}"
expect_no_sandbox "App" "${app_ent}"
expect_key "App" "${app_ent}" com.apple.security.application-groups "${team}."
expect_key "App" "${app_ent}" keychain-access-groups "${team}."
[ -f "${app}/Contents/embedded.provisionprofile" ] && check_profile "App" "${app}" \
    || note "App: kein eingebettetes Provisioning-Profil"

agent="${app}/Contents/Library/LoginItems/${SR_AGENT_NAME}.app"
agent_ent="${work_dir}/agent-entitlements.plist"
if [ -d "${agent}" ]; then
    dump_entitlements "Agent Service" "${agent}" "${agent_ent}"
    expect_no_sandbox "Agent Service" "${agent_ent}"
    expect_key "Agent Service" "${agent_ent}" com.apple.developer.icloud-services CloudKit
    expect_key "Agent Service" "${agent_ent}" com.apple.developer.icloud-container-identifiers "iCloud."
    expect_key "Agent Service" "${agent_ent}" com.apple.developer.aps-environment production
    expect_key "Agent Service" "${agent_ent}" com.apple.developer.icloud-container-environment Production
    expect_key "Agent Service" "${agent_ent}" com.apple.security.application-groups "${team}."
    expect_key "Agent Service" "${agent_ent}" keychain-access-groups "${team}."
    check_profile "Agent Service" "${agent}"
fi

# --- Agent Service und launchd-Plist (ADR-0020) -------------------------------------------------
section "Agent Service und launchd-Plist"
app_id="$(plist_value "${info_plist}" CFBundleIdentifier)"
agent_executable="${agent}/Contents/MacOS/${SR_AGENT_NAME}"
if [ -x "${agent_executable}" ]; then
    ok "eingebettet: ${agent_executable#"${app}/"}"
else
    fail "Agent Service fehlt: ${agent_executable#"${app}/"}"
fi
agent_id="$(plist_value "${agent}/Contents/Info.plist" CFBundleIdentifier)"
agent_version="$(plist_value "${agent}/Contents/Info.plist" CFBundleShortVersionString)"
agent_build="$(plist_value "${agent}/Contents/Info.plist" CFBundleVersion)"
if [ "${agent_version}" = "${app_version}" ] && [ "${agent_build}" = "${app_build}" ]; then
    ok "Agent Service hat dieselbe Version ${agent_version} (${agent_build}) wie die App"
else
    note "Agent Service meldet ${agent_version} (${agent_build}), App ${app_version} (${app_build}) – für den Update-Handshake (Spike S3) sollten beide gleich sein"
fi
plist_name="$(plist_value "${info_plist}" SRAgentLaunchdPlistName)"
launchd_plist="${app}/Contents/Library/LaunchAgents/${plist_name}"
if [ -n "${plist_name}" ] && [ -f "${launchd_plist}" ] && /usr/bin/plutil -lint "${launchd_plist}" > /dev/null 2>&1; then
    ok "launchd-Plist: ${launchd_plist#"${app}/"}"
    label="$(plist_value "${launchd_plist}" Label)"
    bundle_program="$(plist_value "${launchd_plist}" BundleProgram)"
    [ "${label}" = "${agent_id}" ] && ok "Label = ${label}" || fail "Label \"${label}\" ≠ Bundle-ID des Agent Service \"${agent_id}\""
    [ -x "${app}/${bundle_program}" ] && ok "BundleProgram ${bundle_program}" || fail "BundleProgram \"${bundle_program}\" ist nicht ausführbar"
    mach_service="$(/usr/bin/plutil -extract MachServices xml1 -o - "${launchd_plist}" 2> /dev/null \
        | /usr/bin/sed -n 's:.*<key>\(.*\)</key>.*:\1:p' | /usr/bin/head -n 1)"
    [[ "${mach_service}" == "${team}."* ]] && ok "Mach-Service ${mach_service} mit Team-Präfix" \
        || fail "Mach-Service \"${mach_service}\" ohne Team-/App-Group-Präfix"
    /usr/bin/grep -q "<string>${app_id}</string>" "${launchd_plist}" && ok "AssociatedBundleIdentifiers enthält ${app_id}" \
        || fail "AssociatedBundleIdentifiers enthält die App-ID nicht"
else
    fail "launchd-Plist fehlt oder ist ungültig (SRAgentLaunchdPlistName = \"${plist_name}\")"
fi

# --- Sparkle (ADR-0017) --------------------------------------------------------------------------
section "Sparkle"
sparkle_plist="${app}/Contents/Frameworks/Sparkle.framework/Resources/Info.plist"
pinned="$(sr_pinned_sparkle_version 2> /dev/null || true)"
if [ -f "${sparkle_plist}" ]; then
    sparkle_version="$(plist_value "${sparkle_plist}" CFBundleShortVersionString)"
    if [ -z "${pinned}" ] || [ "${sparkle_version}" = "${pinned}" ]; then
        ok "Sparkle.framework ${sparkle_version} eingebettet"
    else
        fail "Sparkle.framework ${sparkle_version}, gepinnt ist ${pinned}"
    fi
else
    fail "Sparkle.framework fehlt"
fi
feed="$(plist_value "${info_plist}" SUFeedURL)"
ed_key="$(plist_value "${info_plist}" SUPublicEDKey)"
[ "$(plist_value "${info_plist}" SURequireSignedFeed)" = "true" ] && ok "SURequireSignedFeed = YES" || fail "SURequireSignedFeed nicht YES"
[ "$(plist_value "${info_plist}" SUVerifyUpdateBeforeExtraction)" = "true" ] && ok "SUVerifyUpdateBeforeExtraction = YES" \
    || fail "SUVerifyUpdateBeforeExtraction nicht YES"
if sr_sparkle_config_is_real "${feed}" "${ed_key}"; then
    ok "SUFeedURL (HTTPS) und SUPublicEDKey (32 Byte) gesetzt: ${feed}"
elif [ "${allow_disabled_updates}" -eq 1 ]; then
    note "SUFeedURL/SUPublicEDKey sind Platzhalter – App zeigt \"Updates deaktiviert\" (--allow-disabled-updates)"
else
    fail "SUFeedURL/SUPublicEDKey sind Platzhalter oder ungültig (\"${feed}\")"
fi

# --- Platzhalter, unaufgelöste Variablen, Geheimnisse --------------------------------------------
section "Platzhalter und Geheimnisse"
scan() {
    # Gibt relative Pfade der Dateien aus, die das Muster enthalten. Treffer selbst werden nie ausgegeben.
    local mode="$1" pattern="$2"
    /usr/bin/grep -r -l -a "${mode}" -e "${pattern}" "${app}" 2> /dev/null | /usr/bin/sed "s#^${app}/##" || true
}
report_scan() {
    local severity="$1" label="$2" hits="$3"
    if [ -z "${hits}" ]; then
        ok "kein ${label}"
    else
        "${severity}" "${label} gefunden in: $(printf '%s' "${hits}" | /usr/bin/tr '\n' ' ')"
    fi
}
# Team-Platzhalter als Präfix einer Kennung ("XXXXXXXXXX.com…"); Sparkles mktemp-Vorlage "%@.XXXXXXXXXX" ist kein Treffer.
report_scan fail "Vorlagen-Team-ID ${SR_PLACEHOLDER_TEAM}" "$(scan -E "${SR_PLACEHOLDER_TEAM}\.[A-Za-z]")"
report_scan fail "Vorlagen-Präfix ${SR_PLACEHOLDER_PREFIX}.SoftwareRegisseur" "$(scan -F "${SR_PLACEHOLDER_PREFIX}.SoftwareRegisseur")"
report_scan fail "unaufgelöste Build-Variable \$(SR_…)" "$(scan -F '$(SR_')"
sparkle_severity=fail
[ "${allow_disabled_updates}" -eq 1 ] && sparkle_severity=note
# Sparkle-Platzhalter nur in Property Lists suchen: Das App-Binary enthält die Platzhalter
# absichtlich als Vergleichswerte (SoftwareUpdater.swift erkennt damit unkonfigurierte Builds).
scan_plists() {
    local needle="$1" plist
    while IFS= read -r -d '' plist; do
        if /usr/bin/plutil -convert xml1 -o - "${plist}" 2> /dev/null | /usr/bin/grep -q -F -e "${needle}"; then
            printf '%s\n' "${plist#"${app}/"}"
        fi
    done < <(/usr/bin/find "${app}" -type f -name '*.plist' -print0)
}
report_scan "${sparkle_severity}" "Sparkle-Platzhalter ${SR_PLACEHOLDER_FEED_MARKER}" "$(scan_plists "${SR_PLACEHOLDER_FEED_MARKER}")"
report_scan "${sparkle_severity}" "Sparkle-Platzhalter ${SR_PLACEHOLDER_ED_KEY}" "$(scan_plists "${SR_PLACEHOLDER_ED_KEY}")"

secret_patterns=(
    "OpenAI-API-Schlüssel|sk-(proj-)?[A-Za-z0-9_-]{32,}"
    "Anthropic-API-Schlüssel|sk-ant-[A-Za-z0-9_-]{20,}"
    "GitHub-Token|(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}"
    "GitHub-Fine-grained-Token|github_pat_[A-Za-z0-9_]{50,}"
    "AWS-Zugangsschlüssel|AKIA[0-9A-Z]{16}"
    "Google-API-Schlüssel|AIza[0-9A-Za-z_-]{35}"
    "Slack-Token|xox[abprs]-[A-Za-z0-9-]{10,}"
    "privater Schlüssel (PEM)|-----BEGIN ([A-Z]+ )?PRIVATE KEY-----"
)
for entry in "${secret_patterns[@]}"; do
    report_scan fail "${entry%%|*}" "$(scan -E "${entry#*|}")"
done
secret_files="$(/usr/bin/find "${app}" -type f \( -name '*.p12' -o -name '*.p8' -o -name '*.pem' -o -name '*.key' \
    -o -name '*.xcconfig' -o -name '.env' -o -name '*.mobileprovision' -o -name 'appcast.xml' \) 2> /dev/null \
    | /usr/bin/sed "s#^${app}/##" || true)"
report_scan fail "Schlüssel-/Konfigurationsdatei (p12/p8/pem/key/xcconfig/.env)" "${secret_files}"

echo
echo "Ergebnis: ${ok_count} OK, ${expected_count} ERWARTET, ${note_count} HINWEIS, ${fail_count} FEHLER"
if [ "${fail_count}" -gt 0 ]; then
    exit 1
fi
if [ "${expected_count}" -gt 0 ]; then
    echo "Noch nicht notarisiert – weiter mit Scripts/sign-and-notarize.sh."
fi
