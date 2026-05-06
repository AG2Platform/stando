#!/bin/bash
# Build Sutando.app — the macOS .app bundle wrapping the dev environment.
#
# Usage:
#   bash app/build-app.sh                       # build to app/build/Sutando.app
#   bash app/build-app.sh /path/to/output       # build to a specific dir
#
# Environment variables:
#   SIGNING_IDENTITY   "-" for ad-hoc (default), or a Developer ID Application
#                      identity name like "Developer ID Application: Sutando
#                      Inc. (ABCDE12345)". Set to a Developer ID for releases
#                      that need to pass Gatekeeper without right-click → Open.
#   SPARKLE_FRAMEWORK  Path to a vendored Sparkle.framework directory. When
#                      present, gets copied into Contents/Frameworks/ and the
#                      launcher links against it. See app/sparkle/fetch-sparkle.sh.
#   ENABLE_SPARKLE     "1" to compile against Sparkle (requires SPARKLE_FRAMEWORK
#                      to point at a valid framework). Default off so the dev
#                      build doesn't need the framework on disk.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${1:-$REPO/app/build}"
APP="$OUT_DIR/Sutando.app"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
ENABLE_SPARKLE="${ENABLE_SPARKLE:-0}"
SPARKLE_FRAMEWORK="${SPARKLE_FRAMEWORK:-$REPO/app/vendor/Sparkle.framework}"

echo "Building Sutando.app → $APP"

# 0. Make sure the bundled runtime exists. bundle-runtime.sh stages
#    node + tmux + terminfo into app/vendor/runtime/. Skipped if already
#    present and SKIP_BUNDLE_RUNTIME=1 (set by CI when it's already done
#    a clean fetch). Without this, the .app would have no node and rely
#    on Homebrew on the target Mac — the whole point of bundling.
if [ "${SKIP_BUNDLE_RUNTIME:-0}" != "1" ] || [ ! -f "$REPO/app/vendor/runtime/bin/node" ]; then
    bash "$REPO/app/bundle-runtime.sh"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources/LaunchAgents"
mkdir -p "$APP/Contents/Resources/repo"
mkdir -p "$APP/Contents/Resources/runtime"

# 1. Compile the Swift launcher into Contents/MacOS/Sutando.
# Sources are listed explicitly so we can split the launcher across files
# without relying on a Swift Package or Xcode project.
echo "  Compiling launcher..."
# SparkleUpdater.swift is always compiled — it ships both the real
# Sparkle-backed implementation (gated by `#if ENABLE_SPARKLE`) AND a
# no-op stub used by the dev build. main.swift references the type
# unconditionally, so the file must be in SWIFT_SOURCES regardless of
# ENABLE_SPARKLE.
SWIFT_SOURCES=(
    "$REPO/src/Sutando/main.swift"
    "$REPO/src/Sutando/LaunchAgentInstaller.swift"
    "$REPO/src/Sutando/SparkleUpdater.swift"
    "$REPO/src/Sutando/CloudAuth.swift"
    "$REPO/src/Sutando/CloudClient.swift"
    "$REPO/src/Sutando/EnvFile.swift"
    "$REPO/src/Sutando/Permissions.swift"
    "$REPO/src/Sutando/SettingsWindow.swift"
    "$REPO/src/Sutando/WebWindow.swift"
)
SWIFT_FRAMEWORKS=(-framework Cocoa -framework Carbon -framework ApplicationServices -framework AVFoundation -framework WebKit)
SWIFT_FLAGS=(-O -o "$APP/Contents/MacOS/Sutando")

# Optional Sparkle linking. When ENABLE_SPARKLE=1 the launcher links
# against the framework and the Sparkle import inside SparkleUpdater.swift
# is enabled. The default (off) keeps the dev build self-contained.
if [ "$ENABLE_SPARKLE" = "1" ]; then
    if [ ! -d "$SPARKLE_FRAMEWORK" ]; then
        echo "  ✗ ENABLE_SPARKLE=1 but Sparkle.framework not at $SPARKLE_FRAMEWORK"
        echo "    Run: bash app/sparkle/fetch-sparkle.sh"
        exit 1
    fi
    SPARKLE_DIR="$(dirname "$SPARKLE_FRAMEWORK")"
    SWIFT_FLAGS+=(-F "$SPARKLE_DIR" -Xlinker -rpath -Xlinker "@executable_path/../Frameworks")
    SWIFT_FRAMEWORKS+=(-framework Sparkle)
    SWIFT_FLAGS+=(-DENABLE_SPARKLE)
fi

swiftc "${SWIFT_FLAGS[@]}" "${SWIFT_SOURCES[@]}" "${SWIFT_FRAMEWORKS[@]}"

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

# 5b. Stage the bundled runtime (node + tmux + terminfo) into the .app.
# LaunchAgentInstaller.placeholders() resolves {{NODE_BIN}} etc. to
# Bundle.main.resourcePath/runtime/bin/* when this directory exists.
echo "  Staging runtime ($(du -sh "$REPO/app/vendor/runtime" | cut -f1))..."
rsync -a --delete \
    "$REPO/app/vendor/runtime/" "$APP/Contents/Resources/runtime/"

# 6. Optional: copy Sparkle.framework into Contents/Frameworks/. Must
# happen before signing so the framework can be signed as part of the
# bundle.
if [ "$ENABLE_SPARKLE" = "1" ]; then
    echo "  Copying Sparkle.framework..."
    mkdir -p "$APP/Contents/Frameworks"
    rsync -a --delete "$SPARKLE_FRAMEWORK/" "$APP/Contents/Frameworks/Sparkle.framework/"
fi

# 7. Sign. Identity "-" = ad-hoc (Phase 1 default; Gatekeeper requires
# right-click → Open). Identity "Developer ID Application: …" produces a
# distributable signature. Sign nested bundles (Sparkle.framework with its
# helper tools — Autoupdate, Updater.app, etc.) before the outer bundle.
echo "  Signing ($SIGNING_IDENTITY)..."

# Nested signing — Sparkle ships an XPC service + helper apps that need
# to be signed individually with the same identity.
if [ "$ENABLE_SPARKLE" = "1" ] && [ -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
    # Sign Sparkle's bundled helpers from the inside out. Sparkle's
    # framework already ships pre-signed by the Sparkle Project — re-signing
    # with --deep would invalidate inner signatures, so target each piece.
    SPARKLE_HELPERS=(
        "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Updater.app"
        "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"
        "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"
        "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
    )
    for helper in "${SPARKLE_HELPERS[@]}"; do
        [ -e "$helper" ] || continue
        codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp=none "$helper" 2>/dev/null || true
    done
    codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp=none \
        "$APP/Contents/Frameworks/Sparkle.framework" 2>/dev/null || true
fi

codesign --force --sign "$SIGNING_IDENTITY" \
    --entitlements "$REPO/app/Sutando.entitlements" \
    --options runtime \
    "$APP" 2>&1 | grep -v "replacing existing signature" || true

# 8. Verify.
echo "  Verifying..."
codesign --verify --verbose=2 "$APP" 2>&1 | tail -3 || \
    echo "  (verification warning — expected for ad-hoc, will be clean under Developer ID)"

ls -la "$APP/Contents/"
echo ""
echo "Built: $APP"
echo "Run with: open $APP"
if [ "$SIGNING_IDENTITY" != "-" ]; then
    echo "To notarize: bash app/notarize.sh \"$APP\""
fi
