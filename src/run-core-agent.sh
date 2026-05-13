#!/bin/bash
# Run the Sutando core agent (Claude Code) as a launchd-managed service.
#
# Lifecycle:
#   1. If a tmux session named `sutando-core` already exists on the
#      shared socket, attach by checking liveness and waiting.
#   2. Otherwise, create it detached and start `claude` with the
#      proactive-loop slash command.
#   3. Block until the tmux session exits, then return — launchd's
#      KeepAlive restarts us, recreating the session.
#
# Prerequisites (the user must have done these once before the launchd
# service can run successfully):
#   - claude CLI on PATH (Claude Code), authenticated via `claude auth login`
#   - tmux on PATH (auto-installed via Homebrew by `bash src/startup.sh` for
#     dev users, but launchd runs without that helper — tmux must already
#     be installed when this script fires)
#
# Env from the plist:
#   SUTANDO_HOME    where state + logs live
#   PATH            we extend with /opt/homebrew/bin and /usr/local/bin so
#                   `tmux` and `claude` resolve under launchd's minimal PATH

set -u

SOCKET=/tmp/sutando-tmux.sock
SESSION=sutando-core
SUTANDO_HOME="${SUTANDO_HOME:-$HOME/Library/Application Support/Sutando}"

# Self-detect the bundled runtime and prepend it to PATH. When run from
# inside Sutando.app, $SCRIPT_DIR is Resources/repo/src and the bundled
# runtime lives at Resources/runtime/. Falls through harmlessly in the
# dev workflow where no bundled runtime exists.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLED_RUNTIME="$SCRIPT_DIR/../../runtime"
if [ -d "$BUNDLED_RUNTIME/bin" ]; then
    export PATH="$BUNDLED_RUNTIME/bin:$PATH"
fi
if [ -d "$BUNDLED_RUNTIME/share/terminfo" ]; then
    # tmux compiled against Homebrew ncurses bakes /opt/homebrew/share/terminfo
    # as its lookup path. On a fresh Mac without Homebrew that path doesn't
    # exist, so we point tmux at the bundled terminfo explicitly.
    export TERMINFO_DIRS="$BUNDLED_RUNTIME/share/terminfo"
fi

# Extend PATH so launchd can find Homebrew binaries (dev workflow + claude).
# `~/.local/bin` is where the official `claude.ai/install.sh` installer drops
# the binary; the Settings → Install Claude Code button uses that installer,
# so users who don't have Homebrew claude end up with it there.
export PATH="$HOME/.local/bin:$PATH:/opt/homebrew/bin:/usr/local/bin"

# Symlink read-only repo bits into SUTANDO_HOME so claude's relative-path
# tool invocations (`bash src/watch-tasks-stream.sh`, `python3
# src/health-check.py`, etc.) resolve. The plist's WorkingDirectory is
# SUTANDO_HOME, so claude inherits cwd=SUTANDO_HOME — but writable state
# (tasks/, results/, core-status.json) lives there, while the actual
# scripts ship inside the .app at Resources/repo/. Without these symlinks,
# every relative path in proactive-loop's SKILL.md fails on a fresh user
# who doesn't have a dev clone at ~/stando. Replace symlinks pointing at
# the wrong target so a .app move (Sparkle relocation, drag to /Applications,
# /tmp test build) self-heals on next boot — the prior "only replace if
# dangling" check missed the case where the old target dir still exists
# but is empty (e.g. a deleted prod app that left behind an empty
# /Applications/Sutando.app shell). Real files/dirs at the link path are
# never touched.
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
mkdir -p "$SUTANDO_HOME"
for name in src skills node_modules package.json package-lock.json tsconfig.json CLAUDE.md; do
    target="$REPO_DIR/$name"
    link="$SUTANDO_HOME/$name"
    if [ -L "$link" ]; then
        # Existing symlink — replace when it points anywhere except $target
        current=$(readlink "$link" 2>/dev/null || echo "")
        if [ "$current" != "$target" ]; then
            rm -f "$link"
        fi
    fi
    if [ -e "$target" ] && [ ! -e "$link" ] && [ ! -L "$link" ]; then
        ln -s "$target" "$link"
    fi
done

ts() { date "+%Y-%m-%dT%H:%M:%S%z"; }

if ! command -v tmux >/dev/null 2>&1; then
    echo "$(ts) [core-agent] tmux not found on PATH=$PATH — install with: brew install tmux"
    # Sleep so launchd's ThrottleInterval doesn't hot-loop us.
    sleep 60
    exit 1
fi

if ! command -v claude >/dev/null 2>&1; then
    echo "$(ts) [core-agent] claude not found on PATH — install Claude Code from https://docs.anthropic.com/en/docs/claude-code/getting-started"
    sleep 60
    exit 1
fi

# Create the session if it doesn't exist. `-d` = detached (no TTY needed,
# which is required under launchd). `-A` = attach if exists, but with -d
# it has no effect — we already check existence above.
LOG_DIR="${LOG_DIR:-$SUTANDO_HOME/logs}"
PANE_LOG="$LOG_DIR/core-agent.pane.log"

# Always kill any pre-existing session first. We used to skip recreation
# when a session existed, but the bypass-permissions warning prompt that
# Claude 2.1.x shows on launch means a stuck session can sit at "1. No,
# exit" forever — and the wrapper's has-session check would happily
# treat that zombie as "alive". Killing always recreates from a clean
# state. ~5s downtime worst case is fine; this only runs on launchd
# restarts (rare).
tmux -S "$SOCKET" kill-session -t "$SESSION" 2>/dev/null || true

echo "$(ts) [core-agent] starting tmux session $SESSION"
tmux -S "$SOCKET" new-session -d -s "$SESSION" -- \
    claude --dangerously-skip-permissions --add-dir "$HOME" -- "/proactive-loop"
if ! tmux -S "$SOCKET" has-session -t "$SESSION" 2>/dev/null; then
    echo "$(ts) [core-agent] tmux new-session failed — sleeping before retry"
    sleep 60
    exit 1
fi

# Pipe the claude pane to a log file so we can debug crashes / unknown
# slash commands / auth prompts. Without this the pane output dies with
# the session and we can only guess.
echo "$(ts) [pane] === session $SESSION started ===" >> "$PANE_LOG"
tmux -S "$SOCKET" pipe-pane -t "$SESSION" -o "cat >> '$PANE_LOG'" 2>/dev/null || true

# Dismiss Claude Code 2.1.x's startup dialogs. On a fresh Mac, two
# appear in sequence:
#   (a) workspace-trust dialog — "Is this a project you trust?", default
#       cursor on "Yes, I trust this folder". Bare Enter accepts.
#   (b) bypass-permissions warning — "Bypass Permissions mode", default
#       cursor on "No, exit". Down+Enter selects "Yes, I accept".
# On a relaunch where (a) is remembered, only (b) appears. The earlier
# blind Down+Enter at 2s misfires when (a) renders first: Down on the
# trust dialog moves the cursor to "No, exit", Enter then exits claude,
# launchd crash-loops the session indefinitely with the watcher never
# coming up. Loop with capture-pane detection: respond to whichever
# dialog is visible, exit once two consecutive ticks are dialog-free.
DIALOGS_DONE=0
for attempt in 1 2 3 4 5 6 7 8; do
    sleep 1
    PANE=$(tmux -S "$SOCKET" capture-pane -t "$SESSION" -p 2>/dev/null || true)
    if echo "$PANE" | grep -q "trust this folder"; then
        tmux -S "$SOCKET" send-keys -t "$SESSION" Enter 2>/dev/null || true
        DIALOGS_DONE=0
    elif echo "$PANE" | grep -q "Bypass Permissions"; then
        # Down and Enter must be sent in two separate send-keys calls.
        # Claude Code 2.1.133's TUI reads stdin fast enough that a single
        # `send-keys Down Enter` confirms the default-highlighted "1. No,
        # exit" before the cursor visually advances — claude exits, launchd
        # crash-loops every 30s. The 0.3s gap reliably lands on "2. Yes, I
        # accept" on a fresh-Mac DMG install.
        tmux -S "$SOCKET" send-keys -t "$SESSION" Down 2>/dev/null || true
        sleep 0.3
        tmux -S "$SOCKET" send-keys -t "$SESSION" Enter 2>/dev/null || true
        DIALOGS_DONE=0
    else
        DIALOGS_DONE=$((DIALOGS_DONE + 1))
        [ "$DIALOGS_DONE" -ge 2 ] && break
    fi
done

# Block until the session exits. tmux's wait-for would be ideal but it
# requires the channel to have been signaled; instead poll has-session
# every 30 seconds. Fast detection of restarts isn't critical — claude's
# crash recovery is rare.
echo "$(ts) [core-agent] tmux session $SESSION is alive; waiting"
while tmux -S "$SOCKET" has-session -t "$SESSION" 2>/dev/null; do
    sleep 30
done
echo "$(ts) [core-agent] tmux session ended; exiting (launchd will restart us)"
