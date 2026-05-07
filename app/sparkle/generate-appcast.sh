#!/bin/bash
# Generate / update the Sparkle appcast.xml for a release.
#
# Usage:
#   bash app/sparkle/generate-appcast.sh <release-dir>
#
# <release-dir> should contain one or more of:
#   Sutando-{version}.dmg        (preferred distribution format)
#   Sutando-{version}.zip        (also accepted)
#
# Sparkle's generate_appcast scans the directory, computes EdDSA
# signatures using the keychain-stored private key (or the explicit key
# file when SPARKLE_PRIVATE_KEY_FILE is set), and emits/updates
# appcast.xml in the same directory.
#
# Channels: pass --channel internal|beta|stable to tag the release.
# Defaults to internal.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
GEN="$REPO/app/vendor/sparkle-bin/generate_appcast"
DIR="${1:-}"
CHANNEL="${SPARKLE_CHANNEL:-internal}"

if [ -z "$DIR" ] || [ ! -d "$DIR" ]; then
    echo "Usage: bash app/sparkle/generate-appcast.sh <release-dir> [--channel internal|beta|stable]"
    exit 1
fi

shift
while [ $# -gt 0 ]; do
    case "$1" in
        --channel) CHANNEL="$2"; shift 2 ;;
        *) echo "✗ unknown arg: $1"; exit 1 ;;
    esac
done

if [ ! -x "$GEN" ]; then
    echo "✗ generate_appcast not found at $GEN"
    echo "  Run: bash app/sparkle/fetch-sparkle.sh"
    exit 1
fi

GEN_ARGS=()
if [ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]; then
    GEN_ARGS+=(--ed-key-file "$SPARKLE_PRIVATE_KEY_FILE")
fi
GEN_ARGS+=(--channel "$CHANNEL")
GEN_ARGS+=("$DIR")

echo "Generating appcast (channel=$CHANNEL) in $DIR..."
"$GEN" "${GEN_ARGS[@]}"

ls -la "$DIR/appcast"*.xml 2>/dev/null || true
echo ""
echo "Upload appcast.xml + the .dmg files to your Sparkle host"
echo "(ag2.ai/sutando/updates/<channel>/appcast.xml + the binaries)."
