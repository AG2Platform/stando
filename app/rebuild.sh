#!/bin/bash
# Quit-build-launch wrapper for the local Sutando.app dev loop.
#
# The bare flow each time you change Swift sources:
#   1. Quit any running Sutando (menu-bar app is LSUIElement, so AppleScript
#      `quit` is best-effort — pkill backstops it).
#   2. Rebuild via app/build-app.sh. SKIP_BUNDLE_RUNTIME=1 by default
#      because the node/tmux bundle in app/vendor/runtime/ rarely changes
#      and re-bundling adds ~30s to each iteration. Pass --full to redo it.
#   3. Launch the freshly-built app.
#
# Usage:
#   bash app/rebuild.sh             # fast: rebuild app/build/Sutando.app, launch it
#   bash app/rebuild.sh --install   # rebuild AND copy to /Applications/, launch from there
#   bash app/rebuild.sh --full      # also re-stage app/vendor/runtime/ (slow path)
#
# Why two launch locations:
#   - app/build/Sutando.app keeps the same path across rebuilds, so TCC
#     grants (Microphone, Screen Recording, Accessibility) survive — the
#     normal dev loop.
#   - /Applications/Sutando.app is what end-users would install. Use
#     --install when you want to test the "real" install path; expect
#     TCC to re-prompt because macOS treats a different bundle path as
#     a different app.
#
# Combine flags freely:  bash app/rebuild.sh --full --install

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL=0
FULL=0

for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --full)    FULL=1 ;;
        -h|--help)
            sed -n '2,26p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown flag: $arg (run with --help)" >&2
            exit 2
            ;;
    esac
done

echo "→ Quitting any running Sutando..."
osascript -e 'tell application "Sutando" to quit' 2>/dev/null || true
# Backstop: AppleScript `quit` only reaches apps registered with the
# Script Manager. LSUIElement apps may not be, so kill the binary by
# name as a fallback. -9 is intentional — Sutando spawns child node
# processes that we want to GC before relaunch.
pkill -9 -f "Sutando.app/Contents/MacOS/Sutando" 2>/dev/null || true
sleep 0.4

echo "→ Building..."
if [ "$FULL" = "1" ]; then
    bash "$REPO/app/build-app.sh"
else
    SKIP_BUNDLE_RUNTIME=1 bash "$REPO/app/build-app.sh"
fi

if [ "$INSTALL" = "1" ]; then
    echo "→ Installing to /Applications/Sutando.app..."
    rm -rf /Applications/Sutando.app
    cp -R "$REPO/app/build/Sutando.app" /Applications/Sutando.app
    TARGET=/Applications/Sutando.app
else
    TARGET="$REPO/app/build/Sutando.app"
fi

echo "→ Launching $TARGET..."
open "$TARGET"
echo "✓ Done."
