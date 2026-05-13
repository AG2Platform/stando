#!/bin/bash
# Memory backup daemon — uploads $SUTANDO_MEMORY_DIR + notes/ to the
# cloud on a slow loop. No-op when signed out or on a free plan.
#
# Sleep interval: 20 min. Tunable via SUTANDO_MEMORY_BACKUP_INTERVAL.
# Lower bound clamped to 5 min so a runaway typo can't hammer the
# upstream.
#
# Started from src/startup.sh in the background.

set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
INTERVAL="${SUTANDO_MEMORY_BACKUP_INTERVAL:-1200}"
if [ "$INTERVAL" -lt 300 ]; then INTERVAL=300; fi

cd "$REPO"

while true; do
  python3 src/memory-backup.py upload || true
  sleep "$INTERVAL"
done
