#!/bin/bash
# Session handoff — writes a summary for the next session to pick up.
# Called by PreCompact hook so context survives session restarts.
#
# Reads the transcript, extracts key signals, and writes to session-state.md.
# The incoming session reads this in CLAUDE.md or as part of the proactive loop.

REPO="${SUTANDO_WORKSPACE:-$HOME/.sutando/workspace}"
# Dev clone root resolved from the script's own location so this
# works for any contributor, not just the original author. Honor
# $SUTANDO_DEV_REPO when set (e.g. running from a vendored copy
# where the script's parent isn't the dev clone). The previous
# `$HOME/Development/core-prod/stando` literal silently turned the
# "Recent Work", "Pending Questions" and "Quota" sections of the
# handoff blank for anyone whose checkout didn't sit at that path —
# every downstream `git -C`, `sys.path.insert`, and `QUOTA_FILE`
# read had its error swallowed by `2>/dev/null`.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEV_REPO="${SUTANDO_DEV_REPO:-$(cd "$SCRIPT_DIR/.." && pwd)}"
if [ ! -d "$DEV_REPO/src" ]; then
  echo "session-handoff: DEV_REPO=$DEV_REPO doesn't look like a Sutando clone (no src/). Set SUTANDO_DEV_REPO or move the script." >&2
fi
export PATH="/opt/homebrew/bin:$HOME/.nvm/versions/node/v24.14.1/bin:$PATH"
STATE_FILE="$REPO/session-state.md"
TRANSCRIPT="$1"  # Passed by PreCompact hook as $TRANSCRIPT_PATH

# Build state from available signals
{
  echo "---"
  echo "# Session State (auto-generated on compaction)"
  echo "timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "---"
  echo ""

  # What's running
  echo "## System Status"
  python3 "$REPO/src/health-check.py" 2>/dev/null | grep -E "✓|⚠|✗" | head -15
  echo ""

  # Recent git activity (what was built)
  echo "## Recent Work (last 10 commits)"
  git -C "$DEV_REPO" log --oneline -10 2>/dev/null
  echo ""

  # Open PRs
  echo "## Open PRs"
  gh pr list --repo sonichi/sutando --state open --limit 5 2>/dev/null || echo "(couldn't fetch)"
  echo ""

  # Pending questions — canonical home is private machine-<host>/ post-migration.
  # Resolves via util_paths.personal_path() with cwd fallback.
  PQ_PATH=$(SUTANDO_PRIVATE_DIR="${SUTANDO_PRIVATE_DIR:-}" python3 -c "
import sys; sys.path.insert(0, '$DEV_REPO/src')
from util_paths import personal_path
from pathlib import Path
print(personal_path('pending-questions.md', Path('$REPO')))
" 2>/dev/null || echo "$REPO/pending-questions.md")
  echo "## Pending Questions"
  if [ -f "$PQ_PATH" ]; then
    grep "^## " "$PQ_PATH" | grep -v "^## Pending" | head -10
  else
    echo "None"
  fi
  echo ""

  # Tasks in flight
  echo "## Tasks"
  ls "$REPO/tasks/"*.txt 2>/dev/null | wc -l | awk '{print $1 " pending"}' || echo "None pending"
  echo ""

  # Quota (with reset times)
  echo "## Quota"
  QUOTA_FILE="$DEV_REPO/skills/quota-tracker/quota-state.json"
  [ ! -f "$QUOTA_FILE" ] && QUOTA_FILE="$HOME/.claude/skills/quota-tracker/quota-state.json"
  [ ! -f "$QUOTA_FILE" ] && QUOTA_FILE="$REPO/quota-state.json"
  if [ -f "$QUOTA_FILE" ]; then
    python3 -c "
import json
from datetime import datetime
d=json.load(open('$QUOTA_FILE'))
now=datetime.now()
r5=datetime.fromtimestamp(int(d['headers']['anthropic-ratelimit-unified-5h-reset']))
m5=int((r5-now).total_seconds()/60)
print(f'5h: {d[\"utilization_5h\"]:.0%} (resets in {m5}min at {r5.strftime(\"%I:%M %p\")}), 7d: {d[\"utilization_7d\"]:.0%}')
" 2>/dev/null
  fi
  echo ""

  # Stars
  echo "## Repo Stats"
  gh api repos/sonichi/sutando --jq '.stargazers_count, .forks_count' 2>/dev/null | tr '\n' ' ' | awk '{print $1 " stars, " $2 " forks"}' || echo "(couldn't fetch)"

} > "$STATE_FILE" 2>/dev/null

echo "Session state saved to $STATE_FILE"
