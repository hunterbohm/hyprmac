#!/bin/bash
# Sign HyprMac.app with HyprMac's own local certificate. usage: app/sign.sh APP IDENTIFIER
# macOS ties the Accessibility switch to the app's designated requirement. An ad-hoc signature's requirement
# is its cdhash, which changes on every build, so every rebuild turned the switch off; a fixed certificate's
# requirement stays the same across builds. The certificate is made once and kept in ~/.config/hyprmac/signing
# (`./uninstall.sh --purge` deletes it, and the next build makes a new one, which needs the switch once more).
set -euo pipefail
umask 077
# macOS's own LibreSSL (/usr/bin/openssl): Homebrew's OpenSSL 3 writes .p12 files that `security import` rejects.
target="$1"
identifier="$2"
signing_dir="${HYPRMAC_SIGNING_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/hyprmac/signing}"
identity_name="HyprMac Local Signing"

if [[ ! -f "$signing_dir/identity.p12" ]]; then
    mkdir -p "$signing_dir"; chmod 700 "$signing_dir"
    scratch="$(mktemp -d)"
    trap 'rm -rf "$scratch"' EXIT
    printf '%s' "$(/usr/bin/openssl rand -hex 24)" > "$scratch/pass"
    cat > "$scratch/cert.cnf" <<EOF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$identity_name
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
    /usr/bin/openssl req -x509 -newkey rsa:3072 -nodes -days 7300 -config "$scratch/cert.cnf" -keyout "$scratch/key.pem" -out "$scratch/cert.pem" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$scratch/key.pem" -in "$scratch/cert.pem" -name "$identity_name" -passout "file:$scratch/pass" -out "$scratch/identity.p12"
    mv "$scratch/pass" "$signing_dir/identity.pass"
    mv "$scratch/identity.p12" "$signing_dir/identity.p12"
    rm -rf "$scratch"; trap - EXIT
fi

# codesign finds identities only in the keychain search list, so import the certificate into a throwaway
# keychain, add it to the list for this one signature, and put the list back afterwards.
searchlist=()
while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"; line="${line#\"}"; line="${line%\"}"
    [[ -n "$line" ]] && searchlist+=("$line")
done < <(security list-keychains -d user)
if [[ ${#searchlist[@]} -eq 0 ]]; then
    printf 'Could not read the keychain search list.\n' >&2
    exit 1
fi
keychain_dir="$(mktemp -d)"
keychain="$keychain_dir/hyprmac-signing.keychain-db"
keychain_pass="$(/usr/bin/openssl rand -hex 16)"
cleanup() {
    security delete-keychain "$keychain" 2>/dev/null || true
    security list-keychains -d user -s "${searchlist[@]}"
    rm -rf "$keychain_dir"
}
trap cleanup EXIT
security create-keychain -p "$keychain_pass" "$keychain"
security list-keychains -d user -s "${searchlist[@]}" "$keychain"
security unlock-keychain -p "$keychain_pass" "$keychain"
security set-keychain-settings "$keychain"
security import "$signing_dir/identity.p12" -k "$keychain" -P "$(cat "$signing_dir/identity.pass")" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_pass" "$keychain" >/dev/null
identity="$(security find-identity -p codesigning "$keychain" | awk -v name="\"$identity_name\"" 'index($0, name) { print $2; exit }')"
codesign --force --keychain "$keychain" --sign "$identity" --identifier "$identifier" "$target"
