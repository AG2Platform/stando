#!/bin/bash
# Build Sutando.app — the macOS .app bundle wrapping the dev environment.
#
# Usage:
#   bash app/build-app.sh                       # build to app/build/Sutando.app
#   bash app/build-app.sh /path/to/output       # build to a specific dir
#
# This builds a structurally complete .app: Info.plist, entitlements, the
# Swift launcher binary, LaunchAgent templates, and (when the source tree is
# present) a copy of the runtime repo. It does NOT yet bundle Node, Python,
# fswatch, or ffmpeg — that's Phase 1.5. It does NOT yet sign or notarize —
# that's Phase 2.
#
# For Phase 0 / 1.1, the goal is "the .app launches, hits the menu bar, and
# the launcher's bundle-aware path resolution works". Bundled runtimes,
# first-launch wizard, and signing land in subsequent steps.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${1:-$REPO/app/build}"
APP="$OUT_DIR/Sutando.app"

echo "Building Sutando.app → $APP"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources/LaunchAgents"
mkdir -p "$APP/Contents/Resources/repo"

# 1. Compile the Swift launcher into Contents/MacOS/Sutando.
# Sources are listed explicitly so we can split the launcher across files
# without relying on a Swift Package or Xcode project (Phase 1.x).
echo "  Compiling launcher..."
swiftc -O \
    -o "$APP/Contents/MacOS/Sutando" \
    "$REPO/src/Sutando/main.swift" \
    "$REPO/src/Sutando/LaunchAgentInstaller.swift" \
    -framework Cocoa \
    -framework Carbon \
    -framework ApplicationServices \
    -framework AVFoundation

# 2. Copy Info.plist + entitlements into the bundle
echo "  Copying Info.plist..."
cp "$REPO/app/Info.plist" "$APP/Contents/Info.plist"

# 3. Copy LaunchAgent templates
echo "  Copying LaunchAgent templates..."
cp "$REPO/app/LaunchAgents/"*.plist.template "$APP/Contents/Resources/LaunchAgents/"
cp "$REPO/app/LaunchAgents/README.md" "$APP/Contents/Resources/LaunchAgents/"

# 4. Copy app icon (placeholder if no .icns yet)
if [ -f "$REPO/app/AppIcon.icns" ]; then
    cp "$REPO/app/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
elif [ -f "$REPO/assets/stand-avatar.png" ]; then
    # Lazy fallback: copy PNG so the bundle has *something* under Resources/.
    # Real .icns generation is part of Phase 1.6.
    cp "$REPO/assets/stand-avatar.png" "$APP/Contents/Resources/AppIcon.png"
fi

# 5. Stage the repo source (src + skills + package.json + node_modules) into
# the bundle. Copies are kept read-only in the bundle; runtime state goes to
# SUTANDO_HOME. node_modules is bundled so the .app doesn't need to run
# npm install on first launch — saves ~30s and removes a Homebrew/network
# dependency at install time.
echo "  Staging repo source..."
cp -R "$REPO/src" "$APP/Contents/Resources/repo/src"
cp -R "$REPO/skills" "$APP/Contents/Resources/repo/skills"
cp "$REPO/package.json" "$APP/Contents/Resources/repo/package.json"
cp "$REPO/package-lock.json" "$APP/Contents/Resources/repo/package-lock.json"
cp "$REPO/tsconfig.json" "$APP/Contents/Resources/repo/tsconfig.json"
cp "$REPO/CLAUDE.md" "$APP/Contents/Resources/repo/CLAUDE.md"
[ -f "$REPO/PERSONAL_CLAUDE.md.example" ] && \
    cp "$REPO/PERSONAL_CLAUDE.md.example" "$APP/Contents/Resources/repo/PERSONAL_CLAUDE.md.example"
[ -d "$REPO/assets" ] && cp -R "$REPO/assets" "$APP/Contents/Resources/repo/assets"

if [ -d "$REPO/node_modules" ]; then
    echo "  Staging node_modules ($(du -sh "$REPO/node_modules" | cut -f1))..."
    # `cp -RL` would dereference symlinks — use plain -R so we keep the
    # native binary symlinks in node_modules/.bin/. .DS_Store and editor
    # detritus are skipped.
    rsync -a --delete \
        --exclude='.DS_Store' --exclude='*.log' --exclude='.cache' \
        "$REPO/node_modules/" "$APP/Contents/Resources/repo/node_modules/"
else
    echo "  ⚠ node_modules not found — first launch will need 'npm install'"
fi

# 6. Ad-hoc sign so Gatekeeper at least lets users open it after the
# right-click → Open dance. Real Developer ID signing + notarization is
# Phase 2. The "-" identity is the ad-hoc identity.
echo "  Ad-hoc signing..."
codesign --force --sign - \
    --entitlements "$REPO/app/Sutando.entitlements" \
    --options runtime \
    --deep \
    "$APP" 2>&1 | grep -v "replacing existing signature" || true

# 7. Verify
echo "  Verifying..."
codesign --verify --verbose=2 "$APP" 2>&1 | tail -3 || echo "  (verification warning — expected for ad-hoc, will be clean under Developer ID)"

ls -la "$APP/Contents/"
echo ""
echo "Built: $APP"
echo "Run with: open $APP"
