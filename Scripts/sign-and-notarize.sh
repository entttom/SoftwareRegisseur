#!/bin/bash
# Notarisiert ein von Scripts/release.sh erzeugtes, Developer-ID-signiertes DMG und heftet das
# Ticket an (Pflichtenheft Q3, ADR-0009). Zugangsdaten kommen ausschließlich aus einem
# Schlüsselbund-Profil von notarytool – dieses Skript nimmt keine Passwörter oder Schlüssel an.
set -euo pipefail

# shellcheck source=Scripts/lib/release-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/release-common.sh"

usage() {
    cat <<'EOF'
Verwendung: Scripts/sign-and-notarize.sh <SoftwareRegisseur-X.Y.Z.dmg> --keychain-profile <profil> [Optionen]

Ablauf:
  1. Scripts/verify-release.sh --pre-notarization <dmg>   (Signaturen, Entitlements, Bundle)
  2. xcrun notarytool submit <dmg> --keychain-profile <profil> --wait
  3. xcrun notarytool log <id> (Protokoll wird immer gespeichert, auch bei Erfolg)
  4. xcrun stapler staple <dmg> und xcrun stapler validate <dmg>
  5. Scripts/verify-release.sh <dmg>                       (jetzt inkl. Gatekeeper "Notarized")

Optionen:
  --keychain-profile <profil>  Name des notarytool-Profils (Pflicht). Einmalig anlegen mit:
                                 xcrun notarytool store-credentials "<profil>"
                               notarytool fragt Apple-ID, Team-ID und app-spezifisches Passwort
                               (oder App-Store-Connect-API-Schlüssel) interaktiv ab und speichert
                               sie im Schlüsselbund. Siehe docs/release/README.md.
  --dry-run                    Nur die Befehle ausgeben, nichts einreichen oder verändern
  --allow-disabled-updates     An verify-release.sh durchreichen (Sparkle-Platzhalter erlauben)
  -h, --help                   Diese Hilfe

Passwörter, Apple-ID oder API-Schlüssel werden bewusst NICHT als Argumente angenommen.
EOF
}

dmg=""
profile=""
dry_run=0
allow_disabled_updates=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --keychain-profile) [ "$#" -ge 2 ] || sr_die "$1 braucht einen Profilnamen."; profile="$2"; shift 2 ;;
        --dry-run) dry_run=1; shift ;;
        --allow-disabled-updates) allow_disabled_updates=1; shift ;;
        --password | --apple-id | --key | --key-id | --issuer | -p)
            sr_die "$1 wird nicht unterstützt: Zugangsdaten nur über ein Schlüsselbund-Profil (xcrun notarytool store-credentials)." ;;
        -*) sr_die "Unbekannte Option: $1 (siehe --help)" ;;
        *) [ -z "${dmg}" ] || sr_die "Nur ein DMG erlaubt."; dmg="$1"; shift ;;
    esac
done

[ -n "${dmg}" ] || { usage >&2; exit 2; }
[ -n "${profile}" ] || sr_die "--keychain-profile <profil> fehlt (siehe --help)."
[[ "${profile}" =~ ^[A-Za-z0-9._-]+$ ]] || sr_die "Profilname darf nur Buchstaben, Ziffern, Punkt, Bindestrich und Unterstrich enthalten."
case "${dmg}" in
    *.dmg) ;;
    *) sr_die "Erwartet wird ein DMG aus Scripts/release.sh." ;;
esac
[ -f "${dmg}" ] || sr_die "${dmg} existiert nicht."
dmg="$(cd "$(dirname "${dmg}")" && pwd)/$(basename "${dmg}")"
out_dir="$(dirname "${dmg}")"
base="$(basename "${dmg}" .dmg)"
submit_json="${out_dir}/${base}.notarytool-submit.json"
log_json="${out_dir}/${base}.notarytool-log.json"

verify_args=()
if [ "${allow_disabled_updates}" -eq 1 ]; then
    verify_args+=(--allow-disabled-updates)
fi
verify="${SR_REPO_ROOT}/Scripts/verify-release.sh"

if [ "${dry_run}" -eq 1 ]; then
    q() { printf '%q ' "$@"; echo; }
    echo "Trockenlauf – folgende Befehle würden ausgeführt (nichts wird eingereicht):"
    q "${verify}" ${verify_args[@]+"${verify_args[@]}"} --pre-notarization "${dmg}"
    q xcrun notarytool submit "${dmg}" --keychain-profile "${profile}" --wait --output-format json
    echo "  → Ausgabe nach $(printf '%q' "${submit_json}"); Status muss \"Accepted\" sein"
    q xcrun notarytool log "<submission-id>" --keychain-profile "${profile}" "${log_json}"
    q xcrun stapler staple "${dmg}"
    q xcrun stapler validate "${dmg}"
    q "${verify}" ${verify_args[@]+"${verify_args[@]}"} "${dmg}"
    exit 0
fi

sr_step "Vorprüfung"
"${verify}" ${verify_args[@]+"${verify_args[@]}"} --pre-notarization "${dmg}"

if /usr/bin/xcrun stapler validate "${dmg}" > /dev/null 2>&1; then
    sr_die "${dmg} hat bereits ein Notarisierungsticket. Für einen neuen Build Scripts/release.sh verwenden."
fi

sr_step "Bei Apple einreichen (notarytool, Profil \"${profile}\") – das kann einige Minuten dauern"
submit_rc=0
/usr/bin/xcrun notarytool submit "${dmg}" --keychain-profile "${profile}" --wait --output-format json \
    > "${submit_json}" || submit_rc=$?
submission_id="$(/usr/bin/plutil -extract id raw -o - "${submit_json}" 2> /dev/null || true)"
status="$(/usr/bin/plutil -extract status raw -o - "${submit_json}" 2> /dev/null || true)"
echo "Einreichung ${submission_id:-unbekannt}: Status ${status:-unbekannt}"

if [ -n "${submission_id}" ]; then
    if /usr/bin/xcrun notarytool log "${submission_id}" --keychain-profile "${profile}" "${log_json}" > /dev/null 2>&1; then
        echo "Protokoll: ${log_json}"
    else
        sr_warn "Notarisierungsprotokoll konnte nicht geladen werden."
    fi
fi

if [ "${submit_rc}" -ne 0 ] || [ "${status}" != "Accepted" ]; then
    if [ -f "${log_json}" ]; then
        echo "--- Probleme laut Protokoll ---" >&2
        /usr/bin/plutil -extract issues json -o - "${log_json}" 2> /dev/null >&2 || true
        echo >&2
    fi
    sr_die "Notarisierung nicht akzeptiert (Status \"${status:-unbekannt}\", Exit ${submit_rc}). Profil prüfen: xcrun notarytool history --keychain-profile \"${profile}\"."
fi

sr_step "Ticket anheften"
/usr/bin/xcrun stapler staple "${dmg}"
/usr/bin/xcrun stapler validate "${dmg}"
(cd "${out_dir}" && /usr/bin/shasum -a 256 "$(basename "${dmg}")" > "$(basename "${dmg}").sha256")
if [ -f "${out_dir}/release-info.txt" ]; then
    {
        echo "Notarisiert: ja (Einreichung ${submission_id}, $(date -u +"%Y-%m-%dT%H:%M:%SZ"))"
        echo "DMG SHA-256 nach Stapling: $(cut -d ' ' -f 1 "${dmg}.sha256")"
    } >> "${out_dir}/release-info.txt"
fi

sr_step "Abschlussprüfung"
"${verify}" ${verify_args[@]+"${verify_args[@]}"} "${dmg}"

echo
echo "Notarisiert und angeheftet: ${dmg}"
echo "Nächster Schritt: Scripts/make-appcast.sh --archives <release-ordner> --tag v<version>"
