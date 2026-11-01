#!/bin/bash
# Erzeugt bzw. aktualisiert den Sparkle-Appcast für GitHub Releases (ADR-0017).
# Signiert Update-Pakete und – wegen SURequireSignedFeed – den Appcast selbst mit dem
# privaten EdDSA-Schlüssel aus dem Schlüsselbund dieses Macs (Sparkle-Standard).
# Lädt nichts hoch; die Upload-Befehle werden nur ausgegeben.
set -euo pipefail

# shellcheck source=Scripts/lib/release-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/release-common.sh"

usage() {
    cat <<'EOF'
Verwendung: Scripts/make-appcast.sh --archives <ordner> --tag <tag> [Optionen]

Ruft Sparkles generate_appcast (aus den aufgelösten Swift-Package-Artefakten, Version laut
project.yml) für einen Ordner mit notarisierten DMGs auf. Ergebnis: <ordner>/appcast.xml.

Der Ordner sollte enthalten:
  - das neue, notarisierte und gestapelte DMG (Scripts/sign-and-notarize.sh)
  - den bisherigen appcast.xml aus dem letzten GitHub-Release (sonst beginnt die Historie neu),
    z. B.: gh release download --repo OWNER/REPO --pattern appcast.xml --dir <ordner>
  - optional ältere DMGs (für Delta-Updates) und Release Notes <dmg-name>.md/.html

Download-URLs neuer Einträge: https://github.com/<owner>/<repo>/releases/download/<tag>/<datei>
Feed-URL (SR_SPARKLE_FEED_URL): https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml
→ appcast.xml muss deshalb an jedes neue Release angehängt werden.

Optionen:
  --archives <ordner>      Ordner mit DMGs (Pflicht)
  --tag <tag>              Git-Tag des GitHub-Releases, z. B. v1.0.0 (Pflicht)
  --repo <owner/repo>      Öffentliches Release-Repository; Standard: aus SR_SPARKLE_FEED_URL
  --account <name>         Schlüsselbund-Account des EdDSA-Schlüssels (Standard: ed25519)
  --allow-unnotarized      Auch DMGs ohne Notarisierungsticket zulassen (nur lokale Tests)
  --dry-run                Nur prüfen und Befehle ausgeben
  -h, --help               Diese Hilfe

Der private Schlüssel wird nie gelesen, ausgegeben oder als Datei angenommen; generate_appcast
holt ihn selbst aus dem Schlüsselbund (macOS fragt ggf. nach Zugriff).
EOF
}

archives=""
tag=""
repo=""
account="ed25519"
allow_unnotarized=0
dry_run=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --archives) [ "$#" -ge 2 ] || sr_die "$1 braucht einen Ordner."; archives="$2"; shift 2 ;;
        --tag) [ "$#" -ge 2 ] || sr_die "$1 braucht einen Wert."; tag="$2"; shift 2 ;;
        --repo) [ "$#" -ge 2 ] || sr_die "$1 braucht einen Wert."; repo="$2"; shift 2 ;;
        --account) [ "$#" -ge 2 ] || sr_die "$1 braucht einen Wert."; account="$2"; shift 2 ;;
        --allow-unnotarized) allow_unnotarized=1; shift ;;
        --dry-run) dry_run=1; shift ;;
        --ed-key-file | -s)
            sr_die "$1 wird nicht unterstützt: Der private EdDSA-Schlüssel bleibt im Schlüsselbund (ADR-0017)." ;;
        *) sr_die "Unbekanntes Argument: $1 (siehe --help)" ;;
    esac
done

[ -n "${archives}" ] || sr_die "--archives <ordner> fehlt (siehe --help)."
[ -n "${tag}" ] || sr_die "--tag <tag> fehlt (siehe --help)."
[ -d "${archives}" ] || sr_die "Ordner ${archives} existiert nicht."
archives="$(cd "${archives}" && pwd)"
[[ "${tag}" =~ ^[A-Za-z0-9._-]+$ ]] || sr_die "Tag \"${tag}\" enthält unzulässige Zeichen."
[[ "${account}" =~ ^[A-Za-z0-9._-]+$ ]] || sr_die "Account \"${account}\" enthält unzulässige Zeichen."

if [ -z "${repo}" ]; then
    sr_require_local_config
    feed_url="$(sr_local_config_value SR_SPARKLE_FEED_URL)"
    if [[ "${feed_url}" =~ ^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/releases/latest/download/appcast\.xml$ ]]; then
        repo="${BASH_REMATCH[1]}"
    else
        sr_die "SR_SPARKLE_FEED_URL (\"${feed_url}\") hat nicht die GitHub-Releases-Form aus ADR-0017. --repo <owner/repo> angeben."
    fi
fi
[[ "${repo}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || sr_die "Repository \"${repo}\" hat nicht die Form owner/repo."
case "${repo}" in
    OWNER/REPO) sr_die "SR_SPARKLE_FEED_URL enthält noch den Platzhalter OWNER/REPO (Config/Local.xcconfig)." ;;
esac
download_prefix="https://github.com/${repo}/releases/download/${tag}/"

dmgs=()
while IFS= read -r -d '' file; do
    dmgs+=("${file}")
done < <(/usr/bin/find "${archives}" -maxdepth 1 -type f -name '*.dmg' -print0)
[ "${#dmgs[@]}" -gt 0 ] || sr_die "Keine DMGs in ${archives}."

sr_step "Archive prüfen"
for dmg in "${dmgs[@]}"; do
    if /usr/bin/xcrun stapler validate "${dmg}" > /dev/null 2>&1; then
        echo "OK: $(basename "${dmg}") – notarisiert und gestapelt"
    elif [ "${allow_unnotarized}" -eq 1 ]; then
        sr_warn "$(basename "${dmg}") ist nicht notarisiert (--allow-unnotarized) – nicht veröffentlichen."
    else
        sr_die "$(basename "${dmg}") hat kein Notarisierungsticket. Erst Scripts/sign-and-notarize.sh ausführen."
    fi
    /usr/bin/codesign --verify --strict "${dmg}" 2> /dev/null || sr_die "$(basename "${dmg}"): Developer-ID-Signatur ungültig."
done
if [ -f "${archives}/appcast.xml" ]; then
    echo "Bestehender Appcast wird fortgeschrieben: ${archives}/appcast.xml"
else
    sr_warn "Kein bisheriger appcast.xml im Ordner – es entsteht ein neuer Appcast nur mit den vorhandenen DMGs."
fi

sparkle_bin="$(sr_find_sparkle_bin)"
generate=("${sparkle_bin}/generate_appcast" --account "${account}" --download-url-prefix "${download_prefix}" "${archives}")

if [ "${dry_run}" -eq 1 ]; then
    echo "Trockenlauf – folgender Befehl würde ausgeführt:"
    printf '%q ' "${generate[@]}"
    echo
    exit 0
fi

sr_step "Appcast erzeugen und signieren (generate_appcast, Schlüssel aus dem Schlüsselbund)"
"${generate[@]}"

appcast="${archives}/appcast.xml"
[ -f "${appcast}" ] || sr_die "generate_appcast hat keinen appcast.xml erzeugt."
/usr/bin/xmllint --noout "${appcast}" 2> /dev/null || sr_die "appcast.xml ist kein gültiges XML."
/usr/bin/grep -q 'sparkle:edSignature=' "${appcast}" || sr_die "appcast.xml enthält keine EdDSA-Signaturen der Pakete."
/usr/bin/grep -q 'sparkle-signatures:' "${appcast}" \
    || sr_die "appcast.xml ist nicht als Ganzes signiert, die App verlangt das aber (SURequireSignedFeed)."
echo "OK: ${appcast} (Pakete und Feed signiert)"

echo
echo "Veröffentlichen (wird NICHT automatisch ausgeführt) – öffentliches Repository ${repo}:"
# Nur Dateien hochladen, die der Appcast unter diesem Tag referenziert (neues DMG, ggf. Deltas).
upload=()
while IFS= read -r name; do
    [ -n "${name}" ] || continue
    [ -f "${archives}/${name}" ] || sr_die "Appcast verweist auf ${name}, die Datei fehlt in ${archives}."
    upload+=("$(printf '%q' "${archives}/${name}")")
done < <(/usr/bin/grep -o "${download_prefix}[^\"]*" "${appcast}" | /usr/bin/sed "s#^${download_prefix}##" | /usr/bin/sort -u)
[ "${#upload[@]}" -gt 0 ] || sr_die "Appcast enthält keinen Eintrag mit ${download_prefix} – stimmt --tag?"
echo "  gh release create ${tag} --repo ${repo} --title \"Software Regisseur ${tag#v}\" --notes-file <notizen.md> ${upload[*]} $(printf '%q' "${appcast}")"
echo "Danach prüfen: curl -fsSL https://github.com/${repo}/releases/latest/download/appcast.xml | head"
