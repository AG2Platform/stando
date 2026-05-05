#!/bin/bash
# Fetch Sparkle.framework from the official sparkle-project release.
#
# Usage: bash app/sparkle/fetch-sparkle.sh
#
# Output: app/vendor/Sparkle.framework/  (also unpacks bin/sign_update,
#         bin/generate_keys, bin/generate_appcast into app/vendor/sparkle-bin/)
#
# Sparkle is the macOS auto-update framework. The .app bundle links against
# Sparkle.framework when ENABLE_SPARKLE=1; it must be present at the path
# below before running `bash app/build-app.sh` with ENABLE_SPARKLE=1.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
VENDOR="$REPO/app/vendor"
FW="$VENDOR/Sparkle.framework"
BIN="$VENDOR/sparkle-bin"

# Pin a specific version so builds are reproducible. Bump intentionally.
SPARKLE_VERSION="${SPARKLE_VERSION:-2.9.1}"
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"

echo "Fetching Sparkle ${SPARKLE_VERSION}..."

if [ -d "$FW" ]; then
    echo "  Sparkle.framework already at $FW — remove it first if you want a re-fetch."
    exit 0
fi

mkdir -p "$VENDOR"
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

cd "$TMPDIR"
curl -fL --progress-bar -o Sparkle.tar.xz "$SPARKLE_URL"
tar xf Sparkle.tar.xz

# The release tarball lays out:
#   Sparkle.framework/   (the framework)
#   bin/sign_update
#   bin/generate_keys
#   bin/generate_appcast
mv Sparkle.framework "$FW"
mkdir -p "$BIN"
[ -d bin ] && cp -R bin/* "$BIN/"

echo ""
echo "Installed:"
echo "  $FW"
echo "  $BIN/  (sign_update, generate_keys, generate_appcast)"
echo ""
echo "Next: bash app/sparkle/generate-keys.sh   # one-time, generate signing keys"
