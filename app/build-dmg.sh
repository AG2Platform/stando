#!/bin/bash
# Build Sutando.dmg — drag-to-Applications installer.
#
# Usage:
#   bash app/build-dmg.sh                  # build to app/build/Sutando.dmg
#   bash app/build-dmg.sh /path/to/out     # build to a specific dir
#
# Builds the .app first if missing, then wraps it in a UDZO-compressed DMG
# with a /Applications symlink for the standard drag-to-install UX. Custom
# background image + window layout are Phase 2 polish.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${1:-$REPO/app/build}"
APP="$OUT_DIR/Sutando.app"
DMG="$OUT_DIR/Sutando.dmg"
STAGING="$OUT_DIR/dmg-staging"

# Read version from Info.plist for the volume name.
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$REPO/app/Info.plist" 2>/dev/null || echo "0.1.0")
VOLNAME="Sutando ${VERSION}"

echo "Building Sutando.dmg → $DMG"

# 1. Make sure the .app is up to date.
if [ ! -d "$APP" ] || [ "$REPO/src/Sutando/main.swift" -nt "$APP/Contents/MacOS/Sutando" ]; then
    echo "  Building Sutando.app first..."
    bash "$REPO/app/build-app.sh" "$OUT_DIR"
fi

# 2. Stage the DMG contents in a clean temp dir.
echo "  Staging DMG contents..."
rm -rf "$STAGING"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/Sutando.app"
ln -s /Applications "$STAGING/Applications"

# 3. Optional README inside the DMG explains prereqs.
cat > "$STAGING/READ ME FIRST.txt" <<'EOF'
Sutando — internal alpha

To install:
  1. Drag Sutando.app to Applications.
  2. Open Sutando from /Applications/.
  3. macOS will prompt for Screen Recording, Accessibility, Microphone,
     and Notification permissions on first use. Click Allow.
  4. From the menu-bar S icon, choose:
        Install Background Services…
     This sets up the launchd agents for the voice agent, web client,
     dashboard, and bridges.

Prerequisites:
  Install Claude Code (the only thing Sutando.app can't bundle):
     https://docs.anthropic.com/en/docs/claude-code/getting-started
  Then run `claude auth login` once to authenticate.

  Everything else (Node runtime, tmux) is bundled inside Sutando.app.

Configuration:
  ~/Library/Application Support/Sutando/.env  — your API keys and settings
  See docs/env.example for the full list.

To uninstall:
  Sutando → Uninstall Background Services
  Then drag Sutando.app to the Trash.
EOF

# 4. Remove any quarantine bits (preserves the ad-hoc signature).
xattr -cr "$STAGING" 2>/dev/null || true

# 5. Build the DMG. UDZO = compressed read-only.
echo "  Creating DMG..."
rm -f "$DMG"
hdiutil create \
    -volname "$VOLNAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG" \
    >/dev/null

# 6. Clean up staging.
rm -rf "$STAGING"

echo ""
echo "Built: $DMG ($(du -sh "$DMG" | cut -f1))"
echo "Open with: open $DMG"
