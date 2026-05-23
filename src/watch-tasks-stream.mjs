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

// Restart-safety: every time the watcher emits a task file (initial
// sweep OR new-file event), increment its `attempts:` counter. Result:
//
//   - First-time emit (fresh task drop) → file gets `attempts: 1`.
//   - Watcher restart with leftover task (agent crashed mid-task,
//     archive never ran) → counter advances. Agent reads
//     `attempts: N (N>1)` as "this is a retry; be careful with
//     non-idempotent side effects."
//
// Insertion point: BEFORE the `task:` line. Task-file parsers across
// the codebase stop scanning at `task:` (that's the "rest is the
// task body" delimiter), so anything after `task:` is invisible to
// them; the counter must precede.
//
// Atomic write via tmp+rename — never leaves a half-written file on
// disk. On any error, log to stderr and continue (a missed bump is
// non-fatal; the agent just sees a slightly-stale count).
function bumpAttemptsCounter(absPath) {
    try {
        const raw = fs.readFileSync(absPath, 'utf8');
        const lines = raw.split('\n');
        // Find the `task:` delimiter line index.
        const taskIdx = lines.findIndex(l => l.startsWith('task:'));
        if (taskIdx < 0) return; // not a well-formed task file — leave alone
        // Find existing `attempts:` line BEFORE the task: delimiter.
        let attemptsIdx = -1;
        for (let i = 0; i < taskIdx; i++) {
            if (lines[i].startsWith('attempts:')) {
                attemptsIdx = i;
                break;
            }
        }
        let newCount = 1;
        if (attemptsIdx >= 0) {
            const m = lines[attemptsIdx].match(/^attempts:\s*(\d+)/);
            if (m) newCount = parseInt(m[1], 10) + 1;
            lines[attemptsIdx] = `attempts: ${newCount}`;
        } else {
            // Insert a new `attempts: 1` line immediately before `task:`.
            lines.splice(taskIdx, 0, 'attempts: 1');
        }
        const updated = lines.join('\n');
        const tmp = `${absPath}.tmp`;
        fs.writeFileSync(tmp, updated);
        fs.renameSync(tmp, absPath);
    } catch (e) {
        console.error(`[watch-tasks-stream] bumpAttemptsCounter(${absPath}) failed: ${e.message}`);
    }
}

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
        const fullPath = path.join(tasksDirAbs, entry);
        if (fs.statSync(fullPath).isFile()) {
            // Bump attempts counter BEFORE emit so the agent reads
            // the updated value. Initial-sweep emissions specifically
            // represent "either fresh-on-disk or left over from
            // crash" — bumping conveys the retry count to the agent.
            bumpAttemptsCounter(fullPath);
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
    // Bump attempts counter BEFORE emit. For new-file events this
    // sets attempts=1 (the file just dropped); the `seen` dedupe
    // prevents same-session double-bumps from FSEvent fan-out.
    bumpAttemptsCounter(full);
    console.log(`TASK_FILE: ${filename}`);
});

// Keep alive — fs.watch holds the loop, but be explicit so SIGINT/SIGTERM
// from the Monitor tool's process group cleanly terminates us.
process.on('SIGINT', () => process.exit(0));
process.on('SIGTERM', () => process.exit(0));
