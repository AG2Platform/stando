#!/bin/bash
# Generate Sparkle EdDSA signing keys (one-time setup per release line).
#
# Usage: bash app/sparkle/generate-keys.sh
#
# Sparkle 2 uses EdDSA (Ed25519) signatures to verify update integrity. The
# private key signs new builds; the public key is embedded in Info.plist
# (SUPublicEDKey) so installed clients can verify.
#
# This script:
#   1. Stores the private key in your macOS keychain (Sparkle does this
#      automatically — see `man generate_keys`).
#   2. Prints the public key for you to paste into app/Info.plist.
#
# IMPORTANT: the keychain entry IS your private key. Do not commit it.
# The public key is safe to commit.
#
# To rotate keys: delete the keychain entry "https://sparkle-project.org"
# in Keychain Access first.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
GEN="$REPO/app/vendor/sparkle-bin/generate_keys"

if [ ! -x "$GEN" ]; then
    echo "✗ generate_keys not found at $GEN"
    echo "  Run: bash app/sparkle/fetch-sparkle.sh"
    exit 1
fi

"$GEN"

echo ""
echo "Public key shown above. Paste it into app/Info.plist as the value"
echo "of the <key>SUPublicEDKey</key> entry."
echo ""
echo "Private key is stored in your macOS keychain under the item"
echo "'Private key for signing Sparkle updates'."
echo ""
echo "To export for CI (so the GitHub Action can sign releases):"
echo "  $GEN -x app/sparkle/sparkle.priv      # writes to file (then base64 it)"
echo "Then add base64-encoded contents as the SPARKLE_PRIVATE_KEY GitHub secret."
