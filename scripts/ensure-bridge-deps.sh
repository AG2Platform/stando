#!/bin/bash
# Ensure the channel-bridge Python deps (slack_bolt, discord.py) exist in a
# dedicated workspace venv so the Slack + Discord bridges can start.
#
# Why this exists: the packaged app's bundled runtime ships node/tmux/ffmpeg but
# NO Python packages, and a clean Mac's python3 has neither slack_bolt nor
# discord.py. Without these the Electron supervisor silently SKIPS both bridges
# (gateDaemon needs an importable dep), so Slack appears "completely broken" on a
# fresh install — exactly the v0.5.0 report. The supervisor adds this venv's
# python3 to its bridge-interpreter candidate list, so populating it here makes
# the bridges launchable.
#
# Contract: idempotent + best-effort. If the venv already imports both, it's a
# no-op and exits fast. Any failure (offline, no pip, no venv module) exits 0 so
# it NEVER blocks boot — the bridge just stays skipped and the UI surfaces why.
# Telegram is unaffected (pure stdlib). Run by the supervisor before the bridges
# launch; safe to re-run every boot.
set -uo pipefail

WORKSPACE="${SUTANDO_WORKSPACE:-$HOME/.sutando/workspace}"
WORKSPACE="${WORKSPACE/#\~/$HOME}"
VENV="$WORKSPACE/runtime/bridge-venv"
PY="$VENV/bin/python3"

# import names (slack_bolt / discord) vs pip package names (slack_bolt / discord.py)
have_deps() { "$1" -c 'import slack_bolt, discord' >/dev/null 2>&1; }

if [ -x "$PY" ] && have_deps "$PY"; then
  echo "[bridge-deps] venv already has slack_bolt + discord.py — nothing to do"
  exit 0
fi

# Pick a base python3 that can build a venv (system python3 is a stated app
# prerequisite). Prefer Homebrew/managed pythons over the /usr/bin stub.
BASE=""
for cand in /opt/homebrew/bin/python3 /usr/local/bin/python3 "$(command -v python3 2>/dev/null || true)" /usr/bin/python3; do
  [ -n "$cand" ] && [ -x "$cand" ] || continue
  if "$cand" -c 'import venv, ensurepip' >/dev/null 2>&1; then BASE="$cand"; break; fi
done
if [ -z "$BASE" ]; then
  echo "[bridge-deps] no python3 with venv/ensurepip found — Slack/Discord bridges will stay unavailable"
  exit 0
fi

if [ ! -x "$PY" ]; then
  echo "[bridge-deps] creating venv at $VENV (base: $BASE)"
  mkdir -p "$(dirname "$VENV")"
  "$BASE" -m venv "$VENV" || { echo "[bridge-deps] venv create failed — skipping"; exit 0; }
fi

"$PY" -m pip install --quiet --upgrade pip >/dev/null 2>&1 || true
echo "[bridge-deps] installing slack_bolt + discord.py (one-time, needs network)…"
if "$PY" -m pip install --quiet slack_bolt "discord.py"; then
  if have_deps "$PY"; then
    echo "[bridge-deps] ✓ slack_bolt + discord.py ready in venv"
  else
    echo "[bridge-deps] ⚠ pip reported success but import check failed"
  fi
else
  echo "[bridge-deps] ⚠ pip install failed (offline?) — Slack/Discord bridges will retry next boot"
fi
exit 0
