#!/usr/bin/env bash
# cron-gate.sh — defer a cron job while owner tasks are queued.
#
# Usage:
#   bash scripts/cron-gate.sh <gate-name> <command> [args...]
#
# If SUTANDO_WORKSPACE/tasks/ contains any pending task files (*.txt that
# are NOT inside an archive/ or processed/ sub-directory), the cron fires
# but defers the <command> — returning exit 0 so the scheduler sees
# success.  The next scheduled fire will retry automatically.
#
# If the task queue is empty, <command> is exec'd with its original args.
#
# Example (from crons.json):
#   bash scripts/cron-gate.sh pending-questions python3 src/check-pending-questions.py
#   bash scripts/cron-gate.sh sync-memory bash scripts/sync-memory.sh

set -euo pipefail

GATE_NAME="${1:-cron}"
shift || true  # remaining args are the command

if [[ $# -eq 0 ]]; then
    echo "[cron-gate] error: no command provided" >&2
    exit 1
fi

# Resolve workspace — mirrors workspace_default.py logic.
WORKSPACE="${SUTANDO_WORKSPACE:-$HOME/.sutando/workspace}"
TASKS_DIR="$WORKSPACE/tasks"

# Count pending task files (*.txt directly under TASKS_DIR, skip sub-dirs).
if [[ -d "$TASKS_DIR" ]]; then
    pending=$(find "$TASKS_DIR" -maxdepth 1 -name "*.txt" 2>/dev/null | wc -l | tr -d ' ')
else
    pending=0
fi

if [[ "$pending" -gt 0 ]]; then
    echo "[cron-gate/$GATE_NAME] $pending owner task(s) queued — deferring (next fire will retry)"
    exit 0
fi

exec "$@"
