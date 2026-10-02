#!/bin/zsh
# A project-local signing identity keeps the designated requirement stable as
# the executable changes. No certificate is added to a system trust store.
set -euo pipefail
cd "${0:A:h:h}"
signing_dir="$PWD/.signing"
signing_keychain="$signing_dir/ForceClick.keychain-db"
password_file="$signing_dir/keychain-password"
certificate_file="$signing_dir/certificate.pem"
identity_file="$signing_dir/identity-sha1"
mkdir -p "$signing_dir"
chmod 700 "$signing_dir"
umask 077

if [[ ! -f "$signing_keychain" || ! -f "$identity_file" ]]; then
    [[ ! -e "$signing_keychain" ]] || { echo "Incomplete local signing identity; preserve .signing and inspect it before rebuilding." >&2; exit 1; }
    /usr/bin/openssl rand -base64 32 > "$password_file"
    signing_password=$(< "$password_file")
    signing_temp=$(mktemp -d "$signing_dir/setup.XXXXXX")
    trap 'rm -rf "$signing_temp"' EXIT
    cat > "$signing_temp/certificate.cnf" <<'CONFIG'
[req]
distinguished_name = subject
x509_extensions = signing
prompt = no
[subject]
CN = ForceClick Local Development
[signing]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONFIG
    /usr/bin/openssl req -new -x509 -newkey rsa:3072 -sha256 -nodes -days 3650 \
        -config "$signing_temp/certificate.cnf" -keyout "$signing_temp/private-key.pem" \
        -out "$certificate_file" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$signing_temp/private-key.pem" -in "$certificate_file" \
        -out "$signing_temp/identity.p12" -name "ForceClick Local Development" \
        -passout "file:$password_file"
    # security create-keychain updates the search list. Restore it immediately;
    # codesign below explicitly selects this isolated keychain instead.
    /usr/bin/security list-keychains -d user > "$signing_temp/original-search-list"
    /usr/bin/security create-keychain -p "$signing_password" "$signing_keychain"
    python3 - "$signing_temp/original-search-list" <<'PY'
import shlex, subprocess, sys
paths = shlex.split(open(sys.argv[1]).read())
subprocess.run(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *paths], check=True)
PY
    /usr/bin/security unlock-keychain -p "$signing_password" "$signing_keychain"
    /usr/bin/security import "$signing_temp/identity.p12" -k "$signing_keychain" \
        -P "$signing_password" -T /usr/bin/codesign >/dev/null
    /usr/bin/security set-key-partition-list -S apple-tool:,codesign: -s -k "$signing_password" \
        "$signing_keychain" >/dev/null
    /usr/bin/openssl x509 -in "$certificate_file" -noout -fingerprint -sha1 \
        | /usr/bin/awk -F= '{gsub(":", "", $2); print $2}' > "$identity_file"
    echo "Created persistent ForceClick signing identity in .signing."
fi

signing_password=$(< "$password_file")
/usr/bin/security unlock-keychain -p "$signing_password" "$signing_keychain"
if [[ "${1:-}" == "--sign" ]]; then
    identity=$(< "$identity_file")
    /usr/bin/codesign --force --sign "$identity" --keychain "$signing_keychain" \
        --timestamp=none --identifier dev.local.forceclick "$2"
fi
