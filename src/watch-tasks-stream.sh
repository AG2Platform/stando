#!/bin/bash
# Streaming task watcher.
#
# Thin wrapper around watch-tasks-stream.mjs so every existing caller
# (`bash src/watch-tasks-stream.sh`, the proactive-loop SKILL.md
# instructions, Monitor tool invocations, pgrep -f watch-tasks) keeps
# working unchanged. Implementation is in Node now — the bundled .app
# ships its own node and doesn't require fswatch.

exec node "$(dirname "$0")/watch-tasks-stream.mjs" "$@"
