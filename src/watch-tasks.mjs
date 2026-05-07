#!/usr/bin/env node
// One-shot task watcher — Node implementation, replaces the fswatch
// shell script. Same contract:
//
//   • If .txt files already exist in TASKS_DIR, emit them and exit.
//   • Otherwise wait for the first filesystem event that produces one,
//     emit, exit.
//
// Output format (matches the prior .sh exactly so callers don't need
// to change):
//   TASK_DETECTED: Process ALL .txt files in tasks/.
//   --- <basename> ---
//   <file contents>
//   ...
//
// Caller pattern (per CLAUDE.md): `bash src/watch-tasks.sh` with
// run_in_background, read the output, process every task, restart.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const tasksDir = process.argv[2] || path.resolve(here, '..', 'tasks');
fs.mkdirSync(tasksDir, { recursive: true });
fs.mkdirSync(path.resolve(here, '..', 'results', 'calls'), { recursive: true });

function existingTxt() {
    try {
        return fs.readdirSync(tasksDir).filter(f => f.endsWith('.txt')).sort();
    } catch {
        return [];
    }
}

function emit(files) {
    console.log('TASK_DETECTED: Process ALL .txt files in tasks/.');
    for (const f of files) {
        console.log(`--- ${f} ---`);
        try {
            process.stdout.write(fs.readFileSync(path.join(tasksDir, f), 'utf8'));
            // Ensure separator newline if file didn't end in one.
            process.stdout.write('\n');
        } catch {}
    }
}

// Check for existing files BEFORE waiting (catches files written during restarts).
const initial = existingTxt();
if (initial.length > 0) {
    emit(initial);
    process.exit(0);
}

// Wait for the next filesystem event. fs.watch on macOS may fire
// spurious events; loop until at least one .txt is present.
const watcher = fs.watch(tasksDir, { recursive: false }, (_eventType, filename) => {
    if (filename) console.log(`fs.watch triggered: ${filename}`);
    const files = existingTxt();
    if (files.length > 0) {
        watcher.close();
        emit(files);
        process.exit(0);
    }
    // False trigger — keep watching.
});

process.on('SIGINT', () => process.exit(0));
process.on('SIGTERM', () => process.exit(0));
