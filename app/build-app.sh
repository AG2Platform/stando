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
    "$REPO/src/Sutando/ClaudeCodeAuth.swift"
    "$REPO/src/Sutando/CloudAuth.swift"
    "$REPO/src/Sutando/CloudClient.swift"
    "$REPO/src/Sutando/EnvFile.swift"
    "$REPO/src/Sutando/FeedbackWindow.swift"
    "$REPO/src/Sutando/OnboardingWindow.swift"
    "$REPO/src/Sutando/Permissions.swift"
    "$REPO/src/Sutando/ScreenCaptureSupervisor.swift"
    "$REPO/src/Sutando/SettingsWindow.swift"
    "$REPO/src/Sutando/SkillsViewController.swift"
    "$REPO/src/Sutando/UnifiedMainWindow.swift"
    "$REPO/src/Sutando/Uninstaller.swift"
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

# 4.1 Menubar template icon — monochrome PNG that macOS tints for dark
# vs light menubars. main.swift loads from Bundle.main.resourcePath first.
# We ship the 1024px source directly; macOS rasterizes to 18×18 at
# render time so a single asset works for both retina and non-retina
# menubars.
if [ -f "$REPO/app/branding/menubar-source.png" ]; then
    cp "$REPO/app/branding/menubar-source.png" "$APP/Contents/Resources/menubar-source.png"
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
# Stage patches/ so the bundle's npm ci postinstall can re-apply our
# bodhi v1alpha patch (required for managed-Gemini ephemeral tokens
# to authenticate against Gemini Live's v1alpha-only auth_tokens API).
[ -d "$REPO/patches" ] && cp -R "$REPO/patches" "$APP/Contents/Resources/repo/patches"
cp "$REPO/CLAUDE.md" "$APP/Contents/Resources/repo/CLAUDE.md"
[ -f "$REPO/PERSONAL_CLAUDE.md.example" ] && \
    cp "$REPO/PERSONAL_CLAUDE.md.example" "$APP/Contents/Resources/repo/PERSONAL_CLAUDE.md.example"
[ -d "$REPO/assets" ] && cp -R "$REPO/assets" "$APP/Contents/Resources/repo/assets"

# React frontend (Vite + React 19) — `src/web-server.ts` serves
# `client/dist/index.html` + hashed assets at GET / and /v2. Without this
# step the bundle falls back to the legacy inline HTML even though
# web-server.ts knows the React routes — which is the exact symptom we
# hit after PR-C step 5 shipped.
#
# Build first if dist/ is missing or stale relative to the workspace
# package.json. `pnpm` is required at build time but not at runtime
# (everything ends up in client/dist/ which is plain static files).
echo "  Building + staging React client (client/dist/)..."
if [ ! -d "$REPO/client/dist" ] || [ "$REPO/client/package.json" -nt "$REPO/client/dist/index.html" ]; then
    (cd "$REPO" && pnpm --filter @sutando/client build 2>&1 | tail -5)
fi
mkdir -p "$APP/Contents/Resources/repo/client"
cp -R "$REPO/client/dist" "$APP/Contents/Resources/repo/client/dist"
# package.json + index.html are useful for diagnostics inside the bundle
# (lets you run `node` against the staged copy if something goes wrong).
cp "$REPO/client/package.json" "$APP/Contents/Resources/repo/client/package.json"
[ -f "$REPO/client/index.html" ] && cp "$REPO/client/index.html" "$APP/Contents/Resources/repo/client/index.html"

# Production-only install directly into the bundle. Skips devDeps
# (typescript, @types/*) which a runtime never touches. Cuts ~30MB and
# fewer Mach-O binaries for Apple's notary to scan.
echo "  Installing production node_modules into bundle..."
(cd "$APP/Contents/Resources/repo" && npm ci --omit=dev --no-audit --no-fund 2>&1 | tail -3)

# Strip transitive deps with no live callers. These come in via
# bodhi-realtime-agent's optionalDependencies (or as transitive native
# binaries) but no Sutando code imports them. Keeping them inflates the
# bundle by ~80MB and slows notarization scans by ~5x.
#
# Verify with: `grep -r '@anthropic-ai\|sharp\|@img' src/ skills/ | grep -v node_modules`
# Anything that grep finds means a caller has been added — re-evaluate.
STAGE_NM="$APP/Contents/Resources/repo/node_modules"
if [ -d "$STAGE_NM/@anthropic-ai" ]; then
    echo "  Stripping @anthropic-ai/claude-agent-sdk (unused, ~68M)..."
    rm -rf "$STAGE_NM/@anthropic-ai"
fi
if [ -d "$STAGE_NM/@img" ]; then
    echo "  Stripping @img/sharp-* (unused, ~15M)..."
    rm -rf "$STAGE_NM/@img"
fi

echo "  Final node_modules size: $(du -sh "$STAGE_NM" | cut -f1)"

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
# distributable signature. For notarization, EVERY Mach-O in the bundle
# (including bundled node, tmux, dylibs, and Sparkle helpers) must be
# signed with the same Developer ID + --options runtime + a secure
# Apple timestamp. Ad-hoc inner signatures get rejected.
echo "  Signing ($SIGNING_IDENTITY)..."

# `--timestamp=none` would skip Apple's timestamp authority — DON'T use
# that with notarization. Default `--timestamp` (no value) hits the TSA.
# When ad-hoc signing locally for dev, neither matters; the runtime
# enforces nothing.
SIGN_FLAGS=(--force --sign "$SIGNING_IDENTITY" --options runtime)
if [ "$SIGNING_IDENTITY" != "-" ]; then
    SIGN_FLAGS+=(--timestamp)
fi

# 7a. Re-sign every Mach-O under Contents/Resources/ — covers
# bundle-runtime.sh's ad-hoc signed binaries (node, tmux, dylibs) AND
# the pre-built native binaries that npm packages ship inside
# node_modules (ripgrep, fsevents, sharp, esbuild, libvips, etc.) AND
# any .node addons or custom helpers under skills/.
#
# Apple's notary walks every Mach-O in the bundle and rejects any that
# isn't (1) signed with our Developer ID, (2) timestamped via Apple's
# TSA, and (3) has hardened runtime enabled. Missing any of the three
# = full rejection.
#
# Runtime entitlements (allow-jit + allow-unsigned-executable-memory +
# disable-library-validation + allow-dyld-environment-variables) are
# applied to all of them — node binaries need JIT, native node-addons
# need library-validation off to load alongside non-Apple-signed dylibs.
#
# Frameworks/ is handled separately in 7b — applying our runtime
# entitlements to Sparkle's helpers (especially Downloader.xpc, which
# ships its own sandbox entitlements) breaks Sparkle at runtime AND
# raises notarization scrutiny. Keep the two passes apart.
RUNTIME_ENTITLEMENTS="$REPO/app/Sutando-runtime.entitlements"
RUNTIME_SIGN_FLAGS=("${SIGN_FLAGS[@]}" --entitlements "$RUNTIME_ENTITLEMENTS")
SIGNED_COUNT=0
SCAN_DIR="$APP/Contents/Resources"
while IFS= read -r -d '' bin; do
    # `file` reliably distinguishes Mach-O (binaries, dylibs, bundles,
    # .node addons) from text. Skip everything that isn't Mach-O.
    if file "$bin" 2>/dev/null | grep -qE 'Mach-O|dynamically linked shared library'; then
        codesign "${RUNTIME_SIGN_FLAGS[@]}" "$bin" 2>&1 | grep -v "replacing existing signature" || true
        SIGNED_COUNT=$((SIGNED_COUNT + 1))
    fi
done < <(find "$SCAN_DIR" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' -o -name '*.node' \) -print0)
echo "  Re-signed $SIGNED_COUNT bundled Mach-O binaries (Resources/)"

# 7b. Sparkle.framework — sign deepest-first per Sparkle's codesigning
# guide: https://sparkle-project.org/documentation/sandboxing/
# Sparkle ships pre-signed by the Sparkle Project; we MUST re-sign with
# our identity so the chain validates against our cert.
#
# Order matters: nested helpers first, then the framework that seals
# them. Inside helpers also use the actual on-disk paths
# (Versions/B/Updater.app — NOT Versions/B/Resources/Updater.app, which
# is what Sparkle 1.x had). Downloader.xpc's own sandbox entitlements
# must be preserved or Sparkle's privilege-separated download breaks at
# runtime; --preserve-metadata=entitlements keeps them.
if [ "$ENABLE_SPARKLE" = "1" ] && [ -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
    SPARKLE_VB="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
    [ -e "$SPARKLE_VB/XPCServices/Installer.xpc" ] && \
        codesign "${SIGN_FLAGS[@]}" "$SPARKLE_VB/XPCServices/Installer.xpc" 2>&1 | grep -v "replacing existing signature" || true
    [ -e "$SPARKLE_VB/XPCServices/Downloader.xpc" ] && \
        codesign "${SIGN_FLAGS[@]}" --preserve-metadata=entitlements "$SPARKLE_VB/XPCServices/Downloader.xpc" 2>&1 | grep -v "replacing existing signature" || true
    [ -e "$SPARKLE_VB/Autoupdate" ] && \
        codesign "${SIGN_FLAGS[@]}" "$SPARKLE_VB/Autoupdate" 2>&1 | grep -v "replacing existing signature" || true
    [ -e "$SPARKLE_VB/Updater.app" ] && \
        codesign "${SIGN_FLAGS[@]}" "$SPARKLE_VB/Updater.app" 2>&1 | grep -v "replacing existing signature" || true
    # Framework last — seals over the helpers and the main Sparkle binary
    # at Versions/B/Sparkle.
    codesign "${SIGN_FLAGS[@]}" "$APP/Contents/Frameworks/Sparkle.framework" 2>&1 | grep -v "replacing existing signature" || true
fi

# 7c. Outer .app last — entitlements applied here.
OUTER_FLAGS=(--force --sign "$SIGNING_IDENTITY" --entitlements "$REPO/app/Sutando.entitlements" --options runtime)
if [ "$SIGNING_IDENTITY" != "-" ]; then
    OUTER_FLAGS+=(--timestamp)
fi
codesign "${OUTER_FLAGS[@]}" "$APP" 2>&1 | grep -v "replacing existing signature" || true

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
