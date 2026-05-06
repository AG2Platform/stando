#!/bin/bash
# Stage a self-contained runtime for Sutando.app under app/vendor/runtime/.
#
# Bundles:
#   bin/node, bin/npm, bin/npx                — official Node 22 LTS tarball
#   bin/tmux                                  — Homebrew tmux (re-rpathed)
#   lib/lib{event,ncurses,...}.*.dylib        — tmux dylib chain (re-rpathed)
#   share/terminfo/                           — ncurses terminfo (so tmux can
#                                                resolve $TERM under launchd)
#
# Cached downloads in app/vendor/cache/.
#
# Usage:
#   bash app/bundle-runtime.sh                  # host arch only (fast)
#   ARCH=universal bash app/bundle-runtime.sh   # universal2 node (CI)
#
# `bash app/build-app.sh` calls this before staging the .app.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="$REPO/app/vendor/runtime"
CACHE="$REPO/app/vendor/cache"
NODE_VERSION="${NODE_VERSION:-22.11.0}"
ARCH="${ARCH:-auto}"

if [ "$ARCH" = "auto" ]; then
    case "$(uname -m)" in
        arm64)  ARCH=arm64 ;;
        x86_64) ARCH=x64 ;;
        *)      echo "  ✗ unsupported uname -m: $(uname -m)"; exit 1 ;;
    esac
fi

echo "Sutando runtime bundle"
echo "  Output: $RUNTIME"
echo "  Node:   v$NODE_VERSION ($ARCH)"
echo ""

rm -rf "$RUNTIME"
mkdir -p "$RUNTIME/bin" "$RUNTIME/lib" "$RUNTIME/share" "$CACHE"

# =============================================================
# Node 22 — official tarball from nodejs.org
# =============================================================

fetch_node() {
    local arch=$1
    local tarball="$CACHE/node-v$NODE_VERSION-darwin-$arch.tar.gz"
    local extracted="$CACHE/node-v$NODE_VERSION-darwin-$arch"
    # All progress output → stderr so $(fetch_node ...) captures only the path.
    if [ ! -f "$tarball" ]; then
        echo "  Downloading node v$NODE_VERSION ($arch)..." >&2
        curl -fsSL --retry 3 -o "$tarball" \
            "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-darwin-$arch.tar.gz" >&2
    fi
    if [ ! -d "$extracted" ]; then
        tar -xzf "$tarball" -C "$CACHE" >&2
    fi
    echo "$extracted"
}

if [ "$ARCH" = "universal" ]; then
    ARM=$(fetch_node arm64)
    X64=$(fetch_node x64)
    echo "  Staging node (universal2)..."
    # Use arm64 tree as the base (npm scripts are arch-independent JS).
    rsync -a "$ARM/" "$RUNTIME/"
    # Replace the node binary with a lipo'd version.
    lipo -create "$ARM/bin/node" "$X64/bin/node" -output "$RUNTIME/bin/node"
else
    SRC=$(fetch_node "$ARCH")
    echo "  Staging node ($ARCH)..."
    rsync -a "$SRC/" "$RUNTIME/"
fi

# Trim Node distribution to runtime essentials. Drops:
#   - include/  (53MB of C++ headers; only needed to compile native modules)
#   - share/doc, share/man  (Node + npm documentation)
#   - CHANGELOG / LICENSE / README at the root
# Keeps:
#   - bin/{node,npm,npx,corepack}
#   - lib/node_modules/  (npm's own implementation + corepack)
rm -rf "$RUNTIME/include" "$RUNTIME/share/doc" "$RUNTIME/share/man"
rm -f  "$RUNTIME/CHANGELOG.md" "$RUNTIME/LICENSE" "$RUNTIME/README.md"

# Strip debug symbols from the node binary (114MB → ~95MB). `strip -S` keeps
# the symbol table needed for debuggers but drops debug sections — fine for
# end-user runtime, painless to drop.
strip -S "$RUNTIME/bin/node" 2>/dev/null || true

# Re-sign node — Apple's tarball ships unsigned, hardened-runtime needs a
# signature (even ad-hoc) for the bundled binary to run. (strip also
# invalidates any prior signature.)
codesign --force --sign - "$RUNTIME/bin/node" 2>/dev/null || true
echo "  ✓ Node $($RUNTIME/bin/node --version) staged"

# =============================================================
# tmux + dylib chain + terminfo
# =============================================================

if ! command -v tmux >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
        echo "  Installing tmux via Homebrew..."
        brew install tmux >/dev/null
    else
        echo "  ✗ tmux not on PATH and no Homebrew available."
        exit 1
    fi
fi

TMUX_SRC="$(command -v tmux)"
echo "  Bundling tmux from $TMUX_SRC..."
cp "$TMUX_SRC" "$RUNTIME/bin/tmux"
chmod +w "$RUNTIME/bin/tmux"

# Walk the dylib graph, copy each non-system dependency in.
copy_dylib_chain() {
    local binary=$1
    while IFS= read -r line; do
        local path
        path=$(echo "$line" | awk '{print $1}')
        case "$path" in
            ""|/System/*|/usr/lib/*|"@"*) continue ;;
        esac
        local name
        name=$(basename "$path")
        if [ ! -f "$RUNTIME/lib/$name" ]; then
            cp "$path" "$RUNTIME/lib/$name"
            chmod +w "$RUNTIME/lib/$name"
            echo "    + lib/$name"
            copy_dylib_chain "$RUNTIME/lib/$name"
        fi
    done < <(otool -L "$binary" 2>/dev/null | tail -n +2)
}
copy_dylib_chain "$RUNTIME/bin/tmux"

# Rewrite install names so the binary + dylibs find each other under
# Sutando.app/Contents/Resources/runtime/lib/.
rewrite_paths() {
    local binary=$1
    while IFS= read -r line; do
        local path
        path=$(echo "$line" | awk '{print $1}')
        case "$path" in
            ""|/System/*|/usr/lib/*|"@"*) continue ;;
        esac
        local name
        name=$(basename "$path")
        install_name_tool -change "$path" "@executable_path/../lib/$name" "$binary" 2>/dev/null || true
    done < <(otool -L "$binary" 2>/dev/null | tail -n +2)
    if [[ "$binary" == *.dylib ]]; then
        install_name_tool -id "@executable_path/../lib/$(basename "$binary")" "$binary" 2>/dev/null || true
    fi
}

echo "  Rewriting rpaths..."
rewrite_paths "$RUNTIME/bin/tmux"
for dylib in "$RUNTIME"/lib/*.dylib; do
    [ -e "$dylib" ] || continue
    rewrite_paths "$dylib"
done

# Bundle terminfo so tmux can resolve $TERM when launchd starts it without
# a TTY. Without this, `tmux new-session` fails with "open terminal failed:
# missing or unsuitable terminal: xterm-256color".
NCURSES_PREFIX=$(brew --prefix ncurses 2>/dev/null || echo "/opt/homebrew/opt/ncurses")
if [ -d "$NCURSES_PREFIX/share/terminfo" ]; then
    echo "  Bundling terminfo from $NCURSES_PREFIX/share/terminfo..."
    rsync -a "$NCURSES_PREFIX/share/terminfo/" "$RUNTIME/share/terminfo/"
else
    echo "  ⚠ ncurses terminfo not found at $NCURSES_PREFIX — bundled tmux may fail under launchd"
fi

# Re-sign — install_name_tool invalidates ad-hoc signatures.
echo "  Re-signing..."
codesign --force --sign - "$RUNTIME/bin/tmux"
for dylib in "$RUNTIME"/lib/*.dylib; do
    [ -e "$dylib" ] || continue
    codesign --force --sign - "$dylib" 2>/dev/null || true
done

echo "  Verifying..."
TMUX_VERSION=$("$RUNTIME/bin/tmux" -V) || { echo "  ✗ bundled tmux failed to run"; exit 1; }
echo "    $TMUX_VERSION"

echo ""
echo "✓ Runtime bundle ready: $(du -sh "$RUNTIME" | cut -f1)"
