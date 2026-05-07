#!/bin/bash
# Notarize Sutando.app or Sutando.dmg via Apple's notarytool.
#
# Usage:
#   bash app/notarize.sh                           # notarize app/build/Sutando.dmg
#   bash app/notarize.sh /path/to/Sutando.app      # notarize a specific .app
#   bash app/notarize.sh /path/to/Sutando.dmg      # or .dmg
#
# Required env vars (set in your shell or via a .env / GitHub Actions
# secrets — never commit these):
#   APPLE_ID                 your Apple ID email
#   APPLE_TEAM_ID            10-character team ID (System Settings →
#                            Apple ID → Devices, or developer.apple.com)
#   APPLE_APP_SPECIFIC_PASSWORD
#                            app-specific password from appleid.apple.com.
#                            NOT your real password.
#
# Or, equivalently, set NOTARYTOOL_PROFILE to a stored notarytool keychain
# profile name (set up once with `xcrun notarytool store-credentials`).
#
# This script:
#   1. Submits the artifact to Apple's notary service.
#   2. Waits for the verdict (typically 1–10 minutes).
#   3. On success, staples the ticket so the artifact validates offline.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACT="${1:-$REPO/app/build/Sutando.dmg}"

if [ ! -e "$ARTIFACT" ]; then
    echo "✗ Artifact not found: $ARTIFACT"
    exit 1
fi

# Build notarytool credential args from whichever auth path is configured.
NOTARY_AUTH=()
if [ -n "${NOTARYTOOL_PROFILE:-}" ]; then
    NOTARY_AUTH=(--keychain-profile "$NOTARYTOOL_PROFILE")
elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]; then
    NOTARY_AUTH=(
        --apple-id "$APPLE_ID"
        --team-id "$APPLE_TEAM_ID"
        --password "$APPLE_APP_SPECIFIC_PASSWORD"
    )
else
    echo "✗ Notary credentials missing."
    echo "  Either set NOTARYTOOL_PROFILE, or set APPLE_ID + APPLE_TEAM_ID +"
    echo "  APPLE_APP_SPECIFIC_PASSWORD."
    exit 1
fi

# notarytool wants either a .zip, .pkg, or .dmg. For .app, zip it first.
if [[ "$ARTIFACT" == *.app ]]; then
    ZIP="${ARTIFACT%.app}.zip"
    echo "  Zipping .app for submission → $ZIP"
    rm -f "$ZIP"
    /usr/bin/ditto -c -k --keepParent "$ARTIFACT" "$ZIP"
    SUBMIT_TARGET="$ZIP"
else
    SUBMIT_TARGET="$ARTIFACT"
fi

# Submit without --wait, then poll. Apple's notary occasionally routes
# submissions into an undocumented "in-depth analysis" path that can
# stretch from minutes to days (forum thread 707377). `--wait` will
# block indefinitely in that case, so we cap with NOTARY_MAX_WAIT_SEC
# (default 1800s = 30 min) and exit non-zero with the submission ID
# preserved so a follow-up workflow can resume via
# `notarytool info <id>` + `stapler staple` when Apple eventually
# returns a verdict.
echo "  Submitting $SUBMIT_TARGET to Apple notary service..."
SUBMIT_JSON=$(xcrun notarytool submit "$SUBMIT_TARGET" "${NOTARY_AUTH[@]}" --output-format json 2>&1)
echo "$SUBMIT_JSON"
SUBMISSION_ID=$(echo "$SUBMIT_JSON" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("id",""))
except Exception: pass' 2>/dev/null || true)
if [ -z "$SUBMISSION_ID" ]; then
    echo "✗ Could not extract submission ID — upload likely failed."
    exit 1
fi
echo "  Submission ID: $SUBMISSION_ID"

MAX_WAIT="${NOTARY_MAX_WAIT_SEC:-1800}"
START=$(date +%s)
SUBMISSION_STATUS="In Progress"
echo "  Polling notary (max ${MAX_WAIT}s)..."
while true; do
    ELAPSED=$(( $(date +%s) - START ))
    if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
        break
    fi
    sleep 30
    INFO_JSON=$(xcrun notarytool info "$SUBMISSION_ID" "${NOTARY_AUTH[@]}" --output-format json 2>&1 || true)
    SUBMISSION_STATUS=$(echo "$INFO_JSON" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("status",""))
except Exception: pass' 2>/dev/null || true)
    echo "    [${ELAPSED}s/${MAX_WAIT}s] status: ${SUBMISSION_STATUS:-unknown}"
    case "$SUBMISSION_STATUS" in
        Accepted|Invalid|Rejected) break ;;
    esac
done

if [ "$SUBMISSION_STATUS" != "Accepted" ]; then
    echo ""
    echo "✗ Notarization status: ${SUBMISSION_STATUS:-In Progress (timed out)}"
    echo "  Submission ID: $SUBMISSION_ID"
    if [ "$SUBMISSION_STATUS" = "Invalid" ] || [ "$SUBMISSION_STATUS" = "Rejected" ]; then
        echo "  Fetching detailed log..."
        xcrun notarytool log "$SUBMISSION_ID" "${NOTARY_AUTH[@]}" || true
    else
        echo ""
        echo "  Submission stuck in Apple's notary queue (>${MAX_WAIT}s)."
        echo "  This is an Apple-side condition — see"
        echo "    https://developer.apple.com/forums/thread/707377"
        echo "  Resume later with:"
        echo "    xcrun notarytool info $SUBMISSION_ID ${NOTARYTOOL_PROFILE:+--keychain-profile $NOTARYTOOL_PROFILE}"
        echo "    xcrun stapler staple \"$ARTIFACT\"   # once Accepted"
    fi
    exit 1
fi

# Staple the ticket. For .app, staple the .app itself (not the .zip).
# For .dmg, staple the .dmg.
echo "  Stapling ticket..."
if [[ "$ARTIFACT" == *.app ]]; then
    xcrun stapler staple "$ARTIFACT"
    rm -f "$ZIP"
else
    xcrun stapler staple "$ARTIFACT"
fi

# Validate.
echo "  Validating..."
xcrun stapler validate "$ARTIFACT"
spctl --assess --type execute --verbose=2 "$ARTIFACT" 2>&1 | tail -3 || true

echo ""
echo "Notarized: $ARTIFACT"
