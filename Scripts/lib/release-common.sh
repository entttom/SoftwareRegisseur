#!/bin/bash
# SC2034: Konstanten werden von den einbindenden Skripten verwendet.
# SC2016: '$(' wird bewusst wörtlich gesucht (unaufgelöste Build-Variablen).
# shellcheck disable=SC2034,SC2016
# Gemeinsame Hilfsfunktionen der Release-Skripte (ADR-0009, ADR-0013, ADR-0017).
# Wird per `source` eingebunden, nicht direkt ausgeführt. Gibt nie Geheimnisse aus.

if [ -z "${BASH_VERSION:-}" ]; then
    echo "Fehler: release-common.sh muss aus bash eingebunden werden." >&2
    exit 1
fi

SR_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SR_PROJECT="SoftwareRegisseur.xcodeproj"
SR_MAC_SCHEME="SoftwareRegisseur-macOS"
SR_APP_NAME="SoftwareRegisseur"
SR_AGENT_NAME="SoftwareRegisseurAgentService"

# Platzhalter aus Config/Local.xcconfig.template – dürfen in keinem Release landen.
SR_PLACEHOLDER_TEAM="XXXXXXXXXX"
SR_PLACEHOLDER_PREFIX="com.example"
SR_PLACEHOLDER_FEED_MARKER="github.com/OWNER/REPO"
SR_PLACEHOLDER_ED_KEY="PUBLIC_KEY_BASE64"

sr_die() {
    echo "Fehler: $*" >&2
    exit 1
}

sr_warn() {
    echo "Warnung: $*" >&2
}

sr_step() {
    echo "==> $*"
}

# Liest einen Wert aus Config/Local.xcconfig (letzte Zuweisung gewinnt).
# "/$()/" ist die xcconfig-Schreibweise für "//" und wird zurückübersetzt.
sr_local_config_value() {
    local key="$1"
    local file="${SR_REPO_ROOT}/Config/Local.xcconfig"
    [ -f "${file}" ] || return 1
    local line value=""
    while IFS= read -r line || [ -n "${line}" ]; do
        case "${line}" in
            *"${key}"*=*) ;;
            *) continue ;;
        esac
        if [[ "${line}" =~ ^[[:space:]]*${key}[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            value="${BASH_REMATCH[1]}"
        fi
    done < "${file}"
    value="$(printf '%s' "${value}" | /usr/bin/sed 's#/\$()/#//#g')"
    # Nachgestellte Leerzeichen entfernen
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "${value}"
}

sr_require_local_config() {
    if [ ! -f "${SR_REPO_ROOT}/Config/Local.xcconfig" ]; then
        echo "Fehler: Config/Local.xcconfig fehlt (ADR-0013)." >&2
        echo "Abhilfe: cp Config/Local.xcconfig.template Config/Local.xcconfig und Werte eintragen." >&2
        exit 1
    fi
}

# Prüft, ob ein EdDSA-Public-Key gültiges Base64 von genau 32 Byte ist.
sr_is_valid_ed_public_key() {
    local key="$1"
    [ -n "${key}" ] || return 1
    [ "${key}" != "${SR_PLACEHOLDER_ED_KEY}" ] || return 1
    [[ "${key}" =~ ^[A-Za-z0-9+/]+=*$ ]] || return 1
    local length
    length="$(printf '%s' "${key}" | /usr/bin/base64 -D 2> /dev/null | /usr/bin/wc -c | /usr/bin/tr -d ' ')"
    [ "${length}" = "32" ]
}

# Liefert 0, wenn die Sparkle-Werte echt (keine Vorlagenwerte) und formal gültig sind.
sr_sparkle_config_is_real() {
    local feed="$1" key="$2"
    case "${feed}" in
        "" | *"${SR_PLACEHOLDER_FEED_MARKER}"* | *'$('*) return 1 ;;
        https://*) ;;
        *) return 1 ;;
    esac
    sr_is_valid_ed_public_key "${key}"
}

# Gepinnte Sparkle-Version aus project.yml (einzige Quelle).
sr_pinned_sparkle_version() {
    /usr/bin/awk '
        /^  Sparkle:/ { in_block = 1; next }
        in_block && /^  [^ ]/ { in_block = 0 }
        in_block && /exactVersion:/ { sub(/.*exactVersion:[[:space:]]*/, ""); gsub(/"/, ""); print; exit }
    ' "${SR_REPO_ROOT}/project.yml"
}

# Version eines aufgelösten Sparkle-Artefakts (Verzeichnis, das bin/ und Sparkle.xcframework enthält).
sr_sparkle_artifact_version() {
    local artifact_dir="$1" plist
    for plist in "${artifact_dir}"/Sparkle.xcframework/macos-*/Sparkle.framework/Resources/Info.plist; do
        if [ -f "${plist}" ]; then
            /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${plist}" 2> /dev/null
            return 0
        fi
    done
    return 1
}

# Findet Sparkles bin/-Ordner (generate_appcast, generate_keys, sign_update) aus den
# aufgelösten Swift-Package-Artefakten mit der in project.yml gepinnten Version.
# Löst die Pakete bei Bedarf in DerivedData/ auf. Ausgabe: Pfad zu bin/.
sr_find_sparkle_bin() {
    local pinned
    pinned="$(sr_pinned_sparkle_version)"
    [ -n "${pinned}" ] || sr_die "Sparkle-Version in project.yml (packages → Sparkle → exactVersion) nicht gefunden."

    local candidates=()
    if [ -n "${SPARKLE_BIN:-}" ]; then
        candidates+=("$(cd "${SPARKLE_BIN}/.." 2> /dev/null && pwd)")
    fi
    candidates+=("${DERIVED_DATA_PATH:-${SR_REPO_ROOT}/DerivedData}/SourcePackages/artifacts/sparkle/Sparkle")
    local dir
    for dir in "${HOME}"/Library/Developer/Xcode/DerivedData/SoftwareRegisseur-*/SourcePackages/artifacts/sparkle/Sparkle; do
        [ -d "${dir}" ] && candidates+=("${dir}")
    done

    local candidate version
    for candidate in "${candidates[@]}"; do
        [ -n "${candidate}" ] && [ -x "${candidate}/bin/generate_appcast" ] || continue
        version="$(sr_sparkle_artifact_version "${candidate}" || true)"
        if [ "${version}" = "${pinned}" ]; then
            printf '%s\n' "${candidate}/bin"
            return 0
        fi
    done

    sr_step "Sparkle ${pinned} nicht lokal aufgelöst – Swift Packages werden aufgelöst" >&2
    command -v xcodegen > /dev/null 2>&1 || sr_die "xcodegen nicht gefunden (brew install xcodegen)."
    (
        cd "${SR_REPO_ROOT}"
        xcodegen generate --quiet
        xcodebuild -resolvePackageDependencies -project "${SR_PROJECT}" -scheme "${SR_MAC_SCHEME}" \
            -derivedDataPath "${DERIVED_DATA_PATH:-${SR_REPO_ROOT}/DerivedData}" > /dev/null
    ) >&2 || sr_die "Swift Packages konnten nicht aufgelöst werden."
    candidate="${DERIVED_DATA_PATH:-${SR_REPO_ROOT}/DerivedData}/SourcePackages/artifacts/sparkle/Sparkle"
    version="$(sr_sparkle_artifact_version "${candidate}" || true)"
    if [ -x "${candidate}/bin/generate_appcast" ] && [ "${version}" = "${pinned}" ]; then
        printf '%s\n' "${candidate}/bin"
        return 0
    fi
    sr_die "Sparkle-Werkzeuge in Version ${pinned} nicht gefunden (gefunden: ${version:-keine}). SPARKLE_BIN=<…/Sparkle/bin> setzen."
}

# SHA-1 der Signieridentität "Developer ID Application: … (TEAM)" im Schlüsselbund.
# Gibt nur den Hash aus (kein Geheimnis); bricht ab, wenn keine oder mehrere passen.
sr_developer_id_identity_hash() {
    local team="$1" matches count
    matches="$(/usr/bin/security find-identity -v -p codesigning 2> /dev/null \
        | /usr/bin/grep -E "\"Developer ID Application: .*\(${team}\)\"" || true)"
    count="$(printf '%s' "${matches}" | /usr/bin/grep -c . || true)"
    if [ "${count}" = "0" ]; then
        sr_die "Keine gültige Signieridentität \"Developer ID Application: … (${team})\" im Schlüsselbund. In Xcode → Settings → Accounts → Manage Certificates anlegen."
    fi
    if [ "${count}" != "1" ]; then
        sr_die "Mehrere \"Developer ID Application\"-Identitäten für Team ${team} gefunden. Bitte abgelaufene/überzählige Zertifikate im Schlüsselbund bereinigen."
    fi
    printf '%s' "${matches}" | /usr/bin/awk '{ print $2 }'
}
