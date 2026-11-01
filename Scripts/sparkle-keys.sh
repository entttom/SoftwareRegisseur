#!/bin/bash
# Erzeugt (einmalig) den EdDSA-Schlüssel für Sparkle-Updates bzw. zeigt den vorhandenen an (ADR-0017).
# Der private Schlüssel bleibt im Schlüsselbund dieses Macs; ausgegeben wird nur der öffentliche.
set -euo pipefail

# shellcheck source=Scripts/lib/release-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/release-common.sh"

usage() {
    cat <<'EOF'
Verwendung: Scripts/sparkle-keys.sh [Optionen]

Ohne Optionen: ruft Sparkles generate_keys auf. Existiert im Schlüsselbund noch kein Schlüssel
("Private key for signing Sparkle updates"), wird einer erzeugt; ein vorhandener wird nie
überschrieben. Danach wird nur der ÖFFENTLICHE Schlüssel ausgegeben.

Optionen:
  --print-only       Nur den öffentlichen Schlüssel eines vorhandenen Schlüssels anzeigen
                     (generate_keys -p), nichts erzeugen
  --account <name>   Schlüsselbund-Account (Standard: ed25519, wie generate_appcast)
  -h, --help         Diese Hilfe

Danach den ausgegebenen Wert in Config/Local.xcconfig eintragen:
  SR_SPARKLE_PUBLIC_ED_KEY = <öffentlicher Schlüssel>

Sicherung: Den privaten Schlüssel einmalig verschlüsselt sichern (siehe docs/release/README.md).
Ohne ihn können installierte Versionen keine Updates mehr annehmen.
EOF
}

print_only=0
account="ed25519"

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --print-only) print_only=1; shift ;;
        --account) [ "$#" -ge 2 ] || sr_die "$1 braucht einen Wert."; account="$2"; shift 2 ;;
        -x | -f | --export | --import)
            sr_die "$1 wird von diesem Skript nicht angeboten. Export/Import des privaten Schlüssels bitte bewusst von Hand (docs/release/README.md)." ;;
        *) sr_die "Unbekanntes Argument: $1 (siehe --help)" ;;
    esac
done
[[ "${account}" =~ ^[A-Za-z0-9._-]+$ ]] || sr_die "Account \"${account}\" enthält unzulässige Zeichen."

sparkle_bin="$(sr_find_sparkle_bin)"
generate_keys="${sparkle_bin}/generate_keys"

if [ "${print_only}" -eq 0 ]; then
    sr_step "Schlüssel im Schlüsselbund anlegen bzw. vorhandenen verwenden (Account \"${account}\")"
    # Ausgabe verwerfen: generate_keys gibt nur den öffentlichen Schlüssel aus, er wird unten
    # einheitlich angezeigt. Bei Fehlern die Meldung zeigen.
    if ! creation_output="$("${generate_keys}" --account "${account}" 2>&1)"; then
        echo "${creation_output}" >&2
        sr_die "generate_keys ist fehlgeschlagen (Schlüsselbund-Zugriff erlaubt?)."
    fi
fi

if ! public_key="$("${generate_keys}" --account "${account}" -p 2> /dev/null)"; then
    sr_die "Kein Sparkle-Schlüssel für Account \"${account}\" im Schlüsselbund. Ohne --print-only ausführen, um einen zu erzeugen."
fi
public_key="$(printf '%s' "${public_key}" | /usr/bin/tr -d '[:space:]')"
sr_is_valid_ed_public_key "${public_key}" || sr_die "generate_keys lieferte keinen gültigen öffentlichen Schlüssel."

echo
echo "Öffentlicher EdDSA-Schlüssel (darf veröffentlicht werden):"
echo "  ${public_key}"
echo
echo "In Config/Local.xcconfig eintragen:"
echo "  SR_SPARKLE_PUBLIC_ED_KEY = ${public_key}"
current="$(sr_local_config_value SR_SPARKLE_PUBLIC_ED_KEY 2> /dev/null || true)"
if [ "${current}" = "${public_key}" ]; then
    echo "Config/Local.xcconfig enthält diesen Schlüssel bereits."
fi
echo
echo "Der private Schlüssel bleibt im Schlüsselbund (\"Private key for signing Sparkle updates\")."
echo "Bitte einmalig sichern – Anleitung: docs/release/README.md, Abschnitt \"Schlüssel sichern\"."
