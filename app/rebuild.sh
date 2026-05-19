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
#   bash app/rebuild.sh --reset-onboarding
#                                   # wipe onboarding markers so the wizard shows on launch
#   bash app/rebuild.sh --reset-tcc # wipe all TCC grants for com.sutando.app.
#                                   # Use once after running app/dev-cert.sh to clean
#                                   # up ghost entries left behind by ad-hoc builds.
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
# Stale System Settings entries:
#   Without a stable code-signing identity, ad-hoc signed builds get a
#   Designated Requirement of `cdhash H"..."` — a fresh CDHash every
#   rebuild, which TCC treats as a brand-new app. Old grants pile up in
#   System Settings → Privacy & Security as ghost "Sutando" rows.
#
#   Fix: run `bash app/dev-cert.sh` once to create a self-signed dev
#   cert in your login keychain. Future builds pick it up automatically
#   (see app/build-app.sh). Then run `bash app/rebuild.sh --reset-tcc`
#   once to clear the accumulated ghost entries.
#
# Combine flags freely:  bash app/rebuild.sh --full --install --reset-onboarding

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL=0
FULL=0
RESET_ONBOARDING=0
RESET_TCC=0

for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --full)    FULL=1 ;;
        --reset-onboarding) RESET_ONBOARDING=1 ;;
        --reset-tcc) RESET_TCC=1 ;;
        -h|--help)
            sed -n '2,40p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown flag: $arg (run with --help)" >&2
            exit 2
            ;;
    esac
done

if [ "$RESET_TCC" = "1" ]; then
    echo "→ Resetting TCC grants for com.sutando.app..."
    # `tccutil reset All <bundle-id>` removes every privacy grant for
    # that bundle from BOTH the user and (where permitted) the system
    # TCC databases. macOS rebuilds the entry on next prompt.
    /usr/bin/tccutil reset All com.sutando.app 2>&1 || true
    echo "  ✓ Cleared — System Settings will prompt fresh on next launch."
fi

if [ "$RESET_ONBOARDING" = "1" ]; then
    echo "→ Resetting onboarding markers..."
    # Dev builds (app/build/) walk up to the repo for $SUTANDO_HOME when the
    # env var is unset; installed builds fall back to Application Support.
    # We touch the force sentinel in every candidate root because we don't
    # know which one the launched build will resolve to — extra sentinels
    # are harmless (cleaned up by completeOnboarding) and missing one
    # silently no-ops the flag.
    for root in "$REPO" "${SUTANDO_HOME:-}" "$HOME/Library/Application Support/Sutando"; do
        [ -z "$root" ] && continue
        root="${root/#\~/$HOME}"
        [ -d "$root" ] || continue
        rm -f \
            "$root/.onboarding-complete" \
            "$root/.onboarding-step" \
            "$root/.firstrun-complete"
        # Force sentinel — without this the app's cold-launch path
        # auto-marks onboarding complete and routes to the closable
        # Settings flow instead of the wizard. See
        # OnboardingWindowController.forceWizardRequested.
        : > "$root/.onboarding-force"
    done
    echo "  ✓ Cleared + force sentinel set — wizard will show on next launch."
fi

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
    DEST=/Applications/Sutando.app

    # macOS 14+ ("App Management" TCC permission) blocks writes to signed
    # bundles in /Applications/ unless the calling terminal app has been
    # granted that permission in System Settings → Privacy & Security →
    # App Management. When the grant is missing, BSD `rm` and `cp` return
    # EPERM on individual files but exit 0 overall, leaving a half-removed
    # bundle (Contents/Resources/repo gone, signed Mach-Os stuck). The
    # launcher then spawns into a void. We detect that case and retry
    # under sudo, which bypasses TCC.
    remove_dest() {
        if [ ! -e "$DEST" ]; then return 0; fi
        rm -rf "$DEST" 2>/dev/null || true
        [ ! -e "$DEST" ]
    }

    if ! remove_dest; then
        echo "  ⚠ rm couldn't fully remove the old install (macOS App Management blocked it)."
        echo "    Grant your terminal App Management in System Settings → Privacy & Security,"
        echo "    or accept the sudo prompt below to wipe with root privileges."
        # chflags clears any uchg/schg BSD flags before the recursive rm.
        sudo chflags -R nouchg "$DEST" 2>/dev/null || true
        sudo rm -rf "$DEST"
        if [ -e "$DEST" ]; then
            echo "✗ Could not remove $DEST even with sudo." >&2
            exit 1
        fi
    fi

    # Stage to a sibling path and rename — keeps launchd / Finder from
    # ever seeing a half-copied bundle. ditto preserves resource forks
    # and extended attributes (cp -R can drop xattrs on signed binaries
    # and cause Gatekeeper re-verification on first launch).
    STAGE="${DEST}.staging.$$"
    rm -rf "$STAGE" 2>/dev/null || true
    ditto "$REPO/app/build/Sutando.app" "$STAGE"
    mv "$STAGE" "$DEST"

    # Verify the launcher has the files it actually needs. Half-installs
    # (missing repo/ or client/dist) silently produce a do-nothing menu-bar
    # icon — fail loudly here instead.
    for required in \
        Contents/MacOS/Sutando \
        Contents/Resources/repo/src/voice-agent.ts \
        Contents/Resources/repo/src/web-server.ts \
        Contents/Resources/repo/client/dist/index.html \
        Contents/Resources/repo/node_modules/.bin/tsx
    do
        if [ ! -e "$DEST/$required" ]; then
            echo "✗ Install incomplete — missing $required" >&2
            exit 1
        fi
    done

    echo "  ✓ Installed + verified."
    TARGET="$DEST"
else
    TARGET="$REPO/app/build/Sutando.app"
fi

echo "→ Launching $TARGET..."
open "$TARGET"
echo "✓ Done."
