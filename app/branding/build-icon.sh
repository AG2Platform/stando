#!/usr/bin/env bash
# Rebuild AppIcon.icns from icon-source.png (preferred) or icon.svg.
# Usage: bash app/branding/build-icon.sh
#
# Requires:
#   sips          (preinstalled on macOS — used when source is PNG)
#   rsvg-convert  (brew install librsvg — only used when source is SVG)
#   iconutil      (preinstalled on macOS)
#
# Output: app/AppIcon.icns  (consumed by app/build-app.sh)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PNG_SRC="$HERE/icon-source.png"
SVG_SRC="$HERE/icon.svg"
ICONSET="$HERE/AppIcon.iconset"
OUT_ICNS="$HERE/../AppIcon.icns"

if [ -f "$PNG_SRC" ]; then
    SOURCE_KIND="png"
    if ! command -v sips >/dev/null 2>&1; then
        echo "sips not found (should be on every macOS install)" >&2
        exit 1
    fi
elif [ -f "$SVG_SRC" ]; then
    SOURCE_KIND="svg"
    if ! command -v rsvg-convert >/dev/null 2>&1; then
        echo "rsvg-convert not found. Install: brew install librsvg" >&2
        exit 1
    fi
else
    echo "No icon source found (looked for $PNG_SRC and $SVG_SRC)" >&2
    exit 1
fi

if ! command -v iconutil >/dev/null 2>&1; then
    echo "iconutil not found (should be on every macOS install)" >&2
    exit 1
fi

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# macOS .icns expects this exact set of sizes/filenames. Anything
# missing breaks the Finder preview; anything extra is silently dropped.
declare -a SIZES=(
    "16:16x16"
    "32:16x16@2x"
    "32:32x32"
    "64:32x32@2x"
    "128:128x128"
    "256:128x128@2x"
    "256:256x256"
    "512:256x256@2x"
    "512:512x512"
    "1024:512x512@2x"
)

for entry in "${SIZES[@]}"; do
    px="${entry%%:*}"
    label="${entry##*:}"
    out="$ICONSET/icon_${label}.png"
    echo "  rendering $label (${px}px) → $out"
    if [ "$SOURCE_KIND" = "png" ]; then
        sips -z "$px" "$px" "$PNG_SRC" --out "$out" >/dev/null
    else
        rsvg-convert -w "$px" -h "$px" -o "$out" "$SVG_SRC"
    fi
done

iconutil -c icns -o "$OUT_ICNS" "$ICONSET"
rm -rf "$ICONSET"
echo "Wrote $OUT_ICNS"

# Menubar template icon — rendered separately because it's a different
# composition (no rounded-square background, single-tone strokes) and
# loaded by main.swift as a template image. Two sizes (@1x + @2x) so
# Retina menubars stay crisp. Filenames match what main.swift reads.
if [ -f "$HERE/menubar.svg" ]; then
    echo "  rendering menubar 18px → app/branding/menubar.png"
    rsvg-convert -w 18 -h 18 -o "$HERE/menubar.png" "$HERE/menubar.svg"
    echo "  rendering menubar 36px → app/branding/menubar@2x.png"
    rsvg-convert -w 36 -h 36 -o "$HERE/menubar@2x.png" "$HERE/menubar.svg"
fi
