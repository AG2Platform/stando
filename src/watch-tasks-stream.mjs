#!/usr/bin/env node
// Streaming task watcher — Node implementation, replaces the fswatch
// shell script. Same contract:
//
//   • Initial sweep: emit "TASK_FILE: <basename>" for every existing
//     .txt file directly inside TASKS_DIR.
//   • Stream: emit one "TASK_FILE: <basename>" per new .txt file as it
//     lands. Rename-out events (file moved away) are filtered.
//   • Never exits during normal operation.
//
// Designed for Claude Code's Monitor tool (`persistent: true`), where
// each stdout line is a separate notification.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
// Resolve tasksDir in this order:
//   1. argv[2] — explicit override (test harness, oddball wiring)
//   2. $SUTANDO_WORKSPACE/tasks (default ~/.sutando/workspace/tasks).
//      Mirrors workspace_default.resolveWorkspace(); inlined because this
//      .mjs runs under plain node and can't import the TS module.
const workspace = process.env.SUTANDO_WORKSPACE
    ? process.env.SUTANDO_WORKSPACE.replace(/^~/, process.env.HOME || '')
    : path.join(process.env.HOME || '', '.sutando', 'workspace');
const tasksDir = process.argv[2] || path.join(workspace, 'tasks');
fs.mkdirSync(tasksDir, { recursive: true });
const tasksDirAbs = fs.realpathSync(tasksDir);
console.error(`[watch-tasks-stream] watching ${tasksDirAbs}`);

// Initial sweep — surface tasks that arrived during a restart gap.
for (const entry of fs.readdirSync(tasksDirAbs)) {
    if (!entry.endsWith('.txt')) continue;
    try {
        if (fs.statSync(path.join(tasksDirAbs, entry)).isFile()) {
            console.log(`TASK_FILE: ${entry}`);
        }
    } catch {}
}

// Stream subsequent events. fs.watch on macOS uses FSEvents underneath;
// `recursive: false` keeps us from picking up archive subdir moves
// (the original .sh had to filter these out by parent-dir match).
//
// Dedupe: macOS may fire multiple events for a single file landing.
// A name stays in `seen` while the file exists; on rename-out the
// stat fails and we clear it, so a re-create fires fresh.
const seen = new Set();
fs.watch(tasksDirAbs, { recursive: false }, (_eventType, filename) => {
    if (!filename || !filename.endsWith('.txt')) return;
    const full = path.join(tasksDirAbs, filename);
    let exists = false;
    try { exists = fs.statSync(full).isFile(); } catch {}
    if (!exists) {
        seen.delete(filename);
        return;
    }
    if (seen.has(filename)) return;
    seen.add(filename);
    console.log(`TASK_FILE: ${filename}`);
});

// Keep alive — fs.watch holds the loop, but be explicit so SIGINT/SIGTERM
// from the Monitor tool's process group cleanly terminates us.
process.on('SIGINT', () => process.exit(0));
process.on('SIGTERM', () => process.exit(0));
