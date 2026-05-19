#!/bin/bash
# Create a stable self-signed code-signing certificate for local dev builds.
#
# Why this exists:
#   Ad-hoc signing (codesign -s -) produces a Designated Requirement of the
#   form `cdhash H"..."`. macOS TCC keys grants (Screen Recording, Mic, etc.)
#   by that DR — so every rebuild = new CDHash = new TCC row, and the old
#   grant stays behind forever as a stale entry in System Settings.
#
#   A self-signed cert lets codesign emit a DR like
#       identifier "com.sutando.app" and certificate leaf[subject.CN] = "Sutando Dev"
#   which is stable across rebuilds. One TCC row, grants survive, no
#   ghost entries pile up.
#
# Usage:
#   bash app/dev-cert.sh              # create the cert if missing
#   bash app/dev-cert.sh --force      # delete + recreate (invalidates existing grants)
#   bash app/dev-cert.sh --print      # just print the identity name and exit
#
# After running, app/build-app.sh auto-picks the cert when SIGNING_IDENTITY
# is unset. To opt out for a single build:  SIGNING_IDENTITY=- bash app/rebuild.sh

set -euo pipefail

CERT_NAME="Sutando Dev"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

FORCE=0
PRINT=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        --print) PRINT=1 ;;
        -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
        *) echo "Unknown flag: $arg" >&2; exit 2 ;;
    esac
done

if [ "$PRINT" = "1" ]; then
    echo "$CERT_NAME"
    exit 0
fi

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null \
    | grep -q "\"$CERT_NAME\""; then
    if [ "$FORCE" != "1" ]; then
        echo "✓ Cert '$CERT_NAME' already exists. Use --force to recreate."
        exit 0
    fi
    echo "→ Removing existing '$CERT_NAME'..."
    # `-t` deletes by type; matching by common name is the most reliable way
    # to wipe both the cert and its private key. May leave orphaned keys —
    # acceptable for a dev cert.
    security delete-certificate -c "$CERT_NAME" "$KEYCHAIN" 2>/dev/null || true
fi

echo "→ Creating self-signed code-signing cert '$CERT_NAME' in login keychain..."

# certtool / openssl can't create a cert that macOS will trust for
# codesigning without manual trust-settings flips. The supported path
# is `security create-keypair` style via a temporary config — but that
# requires interactive Keychain Access steps. Instead we shell out to
# the documented Apple recipe: an inline OpenSSL self-signed cert,
# imported into the keychain, then marked as trusted for codesigning.
#
# This mirrors the steps in Apple Tech Note TN2206 "macOS Code Signing
# In Depth" → "Creating a Self-Signed Code Signing Certificate".

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<'EOF'
[ req ]
distinguished_name = req_dn
prompt = no
x509_extensions = v3_codesign

[ req_dn ]
CN = Sutando Dev

[ v3_codesign ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -new -x509 -nodes -days 3650 \
    -newkey rsa:2048 \
    -keyout "$TMP/key.pem" \
    -out    "$TMP/cert.pem" \
    -config "$TMP/cert.cnf" >/dev/null 2>&1

openssl pkcs12 -export \
    -inkey "$TMP/key.pem" \
    -in    "$TMP/cert.pem" \
    -name  "$CERT_NAME" \
    -out   "$TMP/cert.p12" \
    -passout pass: >/dev/null

# -A allows all apps to use the key without prompting. Acceptable for a
# scoped dev cert; never do this with a Developer ID key.
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "" -A \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null

# Trust this cert for code signing in user trust settings only — does not
# require sudo, scoped to this user. `-p codeSign` is the policy bit
# `security find-identity -p codesigning` looks for.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" \
    "$TMP/cert.pem" >/dev/null 2>&1 || true

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null \
    | grep -q "\"$CERT_NAME\""; then
    echo "✓ Cert ready. Next rebuild will sign with '$CERT_NAME' — TCC grants will persist."
else
    echo "✗ Cert created but not visible to codesigning policy." >&2
    echo "  Open Keychain Access, find '$CERT_NAME', and set Trust → Code Signing = Always Trust." >&2
    exit 1
fi
