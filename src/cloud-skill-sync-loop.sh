#!/bin/bash
# Cloud-skill auto-installer loop.
#
# Pulls the user's server-side skill_installs list on a slow interval and
# extracts any tarballs that aren't already on disk. Lets dashboard
# installs propagate to every Mac the user signs into without manual
# re-clicks. No-op when signed out.
#
# Interval default 60s. Tunable via SUTANDO_SKILL_SYNC_INTERVAL. Floor is
# 30s so a Station install propagates to the user's Mac inside ~30–60s
# from the click, not 10 minutes.

set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
INTERVAL="${SUTANDO_SKILL_SYNC_INTERVAL:-60}"
if [ "$INTERVAL" -lt 30 ]; then INTERVAL=30; fi

cd "$REPO"

while true; do
  npx tsx src/cloud-skill-sync.ts || true
  sleep "$INTERVAL"
done
