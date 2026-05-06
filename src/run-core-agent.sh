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
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

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
if ! tmux -S "$SOCKET" has-session -t "$SESSION" 2>/dev/null; then
    echo "$(ts) [core-agent] starting tmux session $SESSION"
    tmux -S "$SOCKET" new-session -d -s "$SESSION" -- \
        claude --name "$SESSION" --dangerously-skip-permissions --add-dir "$HOME" -- "/proactive-loop"
    if ! tmux -S "$SOCKET" has-session -t "$SESSION" 2>/dev/null; then
        echo "$(ts) [core-agent] tmux new-session failed — sleeping before retry"
        sleep 60
        exit 1
    fi
fi

# Block until the session exits. tmux's wait-for would be ideal but it
# requires the channel to have been signaled; instead poll has-session
# every 30 seconds. Fast detection of restarts isn't critical — claude's
# crash recovery is rare.
echo "$(ts) [core-agent] tmux session $SESSION is alive; waiting"
while tmux -S "$SOCKET" has-session -t "$SESSION" 2>/dev/null; do
    sleep 30
done
echo "$(ts) [core-agent] tmux session ended; exiting (launchd will restart us)"
