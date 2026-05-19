#!/usr/bin/env bash
# Rebuild AppIcon.icns from icon-source.png.
# Usage: bash app/branding/build-icon.sh
#
# Requires:
#   sips       (preinstalled on macOS)
#   iconutil   (preinstalled on macOS)
#
# Output: app/AppIcon.icns  (consumed by app/build-app.sh)
#
# Note: the menubar template image is shipped as `menubar-source.png`
# verbatim — main.swift reads that 1024×1024 PNG and macOS rasterizes
# it to the menubar's 18×18 / 36×36 slot at runtime. No SVG → PNG
# pre-render step is needed.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PNG_SRC="$HERE/icon-source.png"
ICONSET="$HERE/AppIcon.iconset"
OUT_ICNS="$HERE/../AppIcon.icns"

if [ ! -f "$PNG_SRC" ]; then
    echo "No icon source found at $PNG_SRC" >&2
    exit 1
fi

for tool in sips iconutil; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "$tool not found (should be on every macOS install)" >&2
        exit 1
    fi
done

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
    sips -z "$px" "$px" "$PNG_SRC" --out "$out" >/dev/null
done

iconutil -c icns -o "$OUT_ICNS" "$ICONSET"
rm -rf "$ICONSET"
echo "Wrote $OUT_ICNS"
