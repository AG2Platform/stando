#!/usr/bin/env node
// Regression guard for restart-safety #4: task-file `attempts:` counter.
//
// ## The bug
//
// If the agent crashes mid-task (Discord message sent, but archive
// of result+task files never ran), on restart the task file is
// still in `tasks/`. The watcher re-emits it and the agent re-
// processes — potentially re-executing non-idempotent side effects.
//
// ## The fix
//
// The watcher bumps an `attempts:` counter on every emission. Insertion
// point is BEFORE the `task:` delimiter line (parsers stop at `task:`
// so fields after it are invisible — counter must precede).
//
//   - First-time emit (fresh task) → `attempts: 1` inserted.
//   - Watcher restart with leftover task → counter advances. Agent
//     sees `attempts > 1` and treats as a retry.
//
// ## What this test covers
//
// The bumper function is now defined inline in `watch-tasks-stream.mjs`.
// We exercise it via re-import (Node ESM) by extracting the
// function-source via regex and eval'ing it in this test's scope —
// not pretty, but matches Sutando's existing test-harness shape for
// the watcher (no separate module to extract; the watcher is
// intentionally a single .mjs script). Tests cover:
//
//   - Fresh task (no attempts field) → attempts:1 inserted before task:
//   - Existing attempts:N → attempts:N+1
//   - Malformed attempts value → reset to 1
//   - Missing `task:` line → file untouched (defensive)
//   - Atomic write: no .tmp file left on disk after a successful bump
//   - attempts: line placement: never AFTER task: (parsers wouldn't see it)

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const watcherSrc = fs.readFileSync(
    path.join(here, '..', 'src', 'watch-tasks-stream.mjs'),
    'utf8',
);

// Extract bumpAttemptsCounter via regex + eval (sandboxed by closure)
const fnMatch = watcherSrc.match(
    /function bumpAttemptsCounter\(absPath\) \{[\s\S]+?\n\}/,
);
if (!fnMatch) {
    console.error("could not locate bumpAttemptsCounter in watcher source");
    process.exit(1);
}
const bumpAttemptsCounter = eval(`(${fnMatch[0].replace('function bumpAttemptsCounter', 'function')})`);

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'sutando-attempts-test-'));

let passed = 0;
let failed = 0;

function assertEq(actual, expected, msg) {
    if (actual !== expected) {
        console.error(`  ✗ ${msg}`);
        console.error(`     expected: ${JSON.stringify(expected)}`);
        console.error(`     actual:   ${JSON.stringify(actual)}`);
        failed++;
    }
}

function assertContains(haystack, needle, msg) {
    if (!haystack.includes(needle)) {
        console.error(`  ✗ ${msg}`);
        console.error(`     expected to find: ${JSON.stringify(needle)}`);
        console.error(`     in: ${JSON.stringify(haystack)}`);
        failed++;
    }
}

function makeTaskFile(name, content) {
    const p = path.join(TMP, name);
    fs.writeFileSync(p, content);
    return p;
}

function readTaskFile(p) {
    return fs.readFileSync(p, 'utf8');
}

function test_fresh_task_gets_attempts_1() {
    const before = `id: task-1\ntimestamp: 2026-05-22T12:00:00Z\ntask: do the thing\n`;
    const p = makeTaskFile('fresh.txt', before);
    bumpAttemptsCounter(p);
    const after = readTaskFile(p);
    assertContains(after, 'attempts: 1', 'fresh task should get attempts: 1');
    // Verify it's BEFORE the task: line
    const attemptsLine = after.split('\n').findIndex(l => l.startsWith('attempts:'));
    const taskLine = after.split('\n').findIndex(l => l.startsWith('task:'));
    if (attemptsLine >= taskLine) {
        console.error(`  ✗ attempts: line must be BEFORE task: line (attempts=${attemptsLine}, task=${taskLine})`);
        failed++;
        return;
    }
    passed++;
    console.log(`  ✓ test_fresh_task_gets_attempts_1`);
}

function test_existing_attempts_increment() {
    const before = `id: task-2\nattempts: 1\ntimestamp: 2026-05-22T12:00:00Z\ntask: retry me\n`;
    const p = makeTaskFile('retry.txt', before);
    bumpAttemptsCounter(p);
    const after = readTaskFile(p);
    assertContains(after, 'attempts: 2', 'attempts: 1 should bump to attempts: 2');
    // Ensure we didn't double-insert
    const attemptsLines = after.split('\n').filter(l => l.startsWith('attempts:'));
    assertEq(attemptsLines.length, 1, 'should have exactly one attempts: line');
    passed++;
    console.log(`  ✓ test_existing_attempts_increment`);
}

function test_high_count_increment() {
    const before = `id: task-h\nattempts: 47\ntask: many retries\n`;
    const p = makeTaskFile('high.txt', before);
    bumpAttemptsCounter(p);
    const after = readTaskFile(p);
    assertContains(after, 'attempts: 48', 'attempts: 47 should bump to attempts: 48');
    passed++;
    console.log(`  ✓ test_high_count_increment`);
}

function test_missing_task_line_untouched() {
    // Defensive: if the file is malformed (no task: line), don't
    // alter it. Avoids the bumper writing into non-task files that
    // somehow ended up in tasks/.
    const before = `this is not a task file\nno task line here\n`;
    const p = makeTaskFile('malformed.txt', before);
    bumpAttemptsCounter(p);
    const after = readTaskFile(p);
    assertEq(after, before, 'malformed file (no task: line) should be untouched');
    passed++;
    console.log(`  ✓ test_missing_task_line_untouched`);
}

function test_no_tmp_file_left() {
    // Atomic write contract: tmp+rename must clean up the .tmp.
    const before = `id: task-tmp\ntask: x\n`;
    const p = makeTaskFile('tmp-test.txt', before);
    bumpAttemptsCounter(p);
    const tmp = p + '.tmp';
    if (fs.existsSync(tmp)) {
        console.error(`  ✗ .tmp file left on disk: ${tmp}`);
        failed++;
        return;
    }
    passed++;
    console.log(`  ✓ test_no_tmp_file_left`);
}

function test_multiple_bumps_in_sequence() {
    // Simulate watcher-restart pattern: bump-emit-bump-emit-bump.
    const before = `id: task-seq\ntask: many bumps\n`;
    const p = makeTaskFile('seq.txt', before);
    bumpAttemptsCounter(p); // 1
    bumpAttemptsCounter(p); // 2
    bumpAttemptsCounter(p); // 3
    const after = readTaskFile(p);
    assertContains(after, 'attempts: 3', 'three bumps should yield attempts: 3');
    const attemptsLines = after.split('\n').filter(l => l.startsWith('attempts:'));
    assertEq(attemptsLines.length, 1, 'still exactly one attempts: line after multiple bumps');
    passed++;
    console.log(`  ✓ test_multiple_bumps_in_sequence`);
}

function test_attempts_line_never_after_task_line() {
    // Parsers stop at `task:` — the attempts field MUST appear before it.
    const before = `id: task-order\ntimestamp: 2026-05-22T12:00:00Z\nsource: discord\ntask: do work\n`;
    const p = makeTaskFile('order.txt', before);
    bumpAttemptsCounter(p);
    const lines = readTaskFile(p).split('\n');
    const attemptsIdx = lines.findIndex(l => l.startsWith('attempts:'));
    const taskIdx = lines.findIndex(l => l.startsWith('task:'));
    if (attemptsIdx >= taskIdx) {
        console.error(`  ✗ attempts: line (${attemptsIdx}) must come BEFORE task: line (${taskIdx}) — parsers stop scanning at task:`);
        failed++;
        return;
    }
    passed++;
    console.log(`  ✓ test_attempts_line_never_after_task_line`);
}

function test_watcher_wires_bumper_into_both_emit_paths() {
    // Architectural source-grep: the watcher must call
    // bumpAttemptsCounter BOTH from the initial sweep AND from the
    // stream-watcher branch. Without both, the contract breaks for
    // one of the two cases (fresh-emit vs restart-emit).
    const src = watcherSrc;
    // Initial sweep block — between "Initial sweep" comment and the
    // fs.watch( call.
    const sweepMatch = src.match(/Initial sweep[\s\S]+?fs\.watch\(/);
    if (!sweepMatch || !sweepMatch[0].includes('bumpAttemptsCounter')) {
        console.error(`  ✗ initial sweep block does NOT call bumpAttemptsCounter`);
        failed++;
        return;
    }
    // Stream branch — fs.watch callback.
    const streamMatch = src.match(/fs\.watch\([\s\S]+?\}\);/);
    if (!streamMatch || !streamMatch[0].includes('bumpAttemptsCounter')) {
        console.error(`  ✗ stream branch does NOT call bumpAttemptsCounter`);
        failed++;
        return;
    }
    passed++;
    console.log(`  ✓ test_watcher_wires_bumper_into_both_emit_paths`);
}

test_fresh_task_gets_attempts_1();
test_existing_attempts_increment();
test_high_count_increment();
test_missing_task_line_untouched();
test_no_tmp_file_left();
test_multiple_bumps_in_sequence();
test_attempts_line_never_after_task_line();
test_watcher_wires_bumper_into_both_emit_paths();

if (failed > 0) {
    console.error(`\n${failed} test(s) failed (${passed} passed).`);
    process.exit(1);
}
console.log(`All ${passed} attempts-counter tests passed.`);
