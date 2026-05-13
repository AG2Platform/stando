#!/bin/bash
# Cloud-skill auto-installer loop.
#
# Pulls the user's server-side skill_installs list on a slow interval and
# extracts any tarballs that aren't already on disk. Lets dashboard
# installs propagate to every Mac the user signs into without manual
# re-clicks. No-op when signed out.
#
# Interval default 600s (10 min). Tunable via SUTANDO_SKILL_SYNC_INTERVAL.

set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
INTERVAL="${SUTANDO_SKILL_SYNC_INTERVAL:-600}"
if [ "$INTERVAL" -lt 120 ]; then INTERVAL=120; fi

cd "$REPO"

while true; do
  npx tsx src/cloud-skill-sync.ts || true
  sleep "$INTERVAL"
done
