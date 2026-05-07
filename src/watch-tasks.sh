#!/bin/bash
# One-shot task watcher.
#
# Thin wrapper around watch-tasks.mjs. Implementation is in Node so
# the .app bundle doesn't need fswatch.

exec node "$(dirname "$0")/watch-tasks.mjs" "$@"
