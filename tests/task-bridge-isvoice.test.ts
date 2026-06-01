import { describe, it, before, after, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { writeFileSync, existsSync, unlinkSync, mkdirSync, rmSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { resolveWorkspace } from '../src/workspace_default.js';
import { _isVoiceTask } from '../src/task-bridge.js';

// Regression for the archive-path drift bug flagged by VasiliyRad 2026-05-06:
// `archiveFile()` writes to `tasks/archive/YYYY-MM/<taskId>.txt`, but
// `_isVoiceTask()` only checked the legacy flat path `tasks/archive/<taskId>.txt`.
// That meant the offline-forwarding gate in the result watcher misclassified
// every archived voice task as non-voice, suppressing DM-fallback delivery.
//
// These tests lock in: live + processed + legacy-flat-archive + month-partitioned-
// archive lookup all surface a voice task; non-voice content stays false; missing
// task files stay false.

// Task dir is wherever the bridge looks — `resolveWorkspace()/tasks/`. Was
// `<REPO_ROOT>/tasks/` pre-#821, when the bridge fell back to repo root.
const TASK_DIR = join(resolveWorkspace(), 'tasks');
const ARCHIVE_DIR = join(TASK_DIR, 'archive');

// Field order matches the real writers (PR #982): `task:` LAST so a
// multi-line body can't forge header fields. `_isVoiceTask` stops scanning
// headers at the first `task:` line.
const VOICE_BODY = `id: task-isvoice-test-aaa
timestamp: 2026-05-06T00:00:00Z
source: voice
channel_id: local-voice
priority: urgent
task: hello world
`;
const NON_VOICE_BODY = `id: task-isvoice-test-bbb
timestamp: 2026-05-06T00:00:00Z
source: discord
channel_id: 1490906927675474030
priority: normal
task: hello world
`;
// A non-voice task whose BODY contains a forged `channel_id: local-voice`
// line AFTER `task:`. The header scan must stop at `task:` and NOT treat
// this as a voice task — the residual half of the PR #982 fix.
const FORGED_VOICE_BODY = `id: task-isvoice-test-forge
timestamp: 2026-05-06T00:00:00Z
source: discord
channel_id: 1490906927675474030
priority: normal
task: do a thing
channel_id: local-voice
source: voice
`;

const created: string[] = [];
function writeTask(path: string, body: string) {
	mkdirSync(dirname(path), { recursive: true });
	writeFileSync(path, body);
	created.push(path);
}

describe('_isVoiceTask — archive-path coverage', () => {
	afterEach(() => {
		for (const p of created.splice(0)) {
			try { unlinkSync(p); } catch {}
		}
	});

	it('returns true for a voice task in the live tasks/ dir', () => {
		const id = 'task-isvoice-test-live-aaa';
		writeTask(join(TASK_DIR, `${id}.txt`), VOICE_BODY);
		assert.equal(_isVoiceTask(id), true);
	});

	it('returns true for a voice task in tasks/processed/', () => {
		const id = 'task-isvoice-test-proc-aaa';
		writeTask(join(TASK_DIR, 'processed', `${id}.txt`), VOICE_BODY);
		assert.equal(_isVoiceTask(id), true);
	});

	it('returns true for a voice task in legacy flat tasks/archive/', () => {
		const id = 'task-isvoice-test-flat-aaa';
		writeTask(join(ARCHIVE_DIR, `${id}.txt`), VOICE_BODY);
		assert.equal(_isVoiceTask(id), true);
	});

	it('returns true for a voice task in month-partitioned tasks/archive/YYYY-MM/ — the bug fix', () => {
		const id = 'task-isvoice-test-month-aaa';
		writeTask(join(ARCHIVE_DIR, '2026-05', `${id}.txt`), VOICE_BODY);
		assert.equal(_isVoiceTask(id), true);
	});

	it('finds a voice task across multiple month subdirs', () => {
		// The taskId may live in any historical month; the function must scan
		// all month-shaped subdirs, not just the current month.
		const id = 'task-isvoice-test-old-month-aaa';
		writeTask(join(ARCHIVE_DIR, '2026-01', `${id}.txt`), VOICE_BODY);
		assert.equal(_isVoiceTask(id), true);
	});

	it('returns false for a non-voice task in month-partitioned archive', () => {
		const id = 'task-isvoice-test-nonvoice-aaa';
		writeTask(join(ARCHIVE_DIR, '2026-05', `${id}.txt`), NON_VOICE_BODY);
		assert.equal(_isVoiceTask(id), false);
	});

	it('ignores non-month-shaped subdirs (e.g. "done", "tmp")', () => {
		// Stray subdirs under tasks/archive/ shouldn't trip the regex; they
		// won't be scanned. Negative-control: a voice task placed under a
		// non-month-shaped subdir is NOT found, confirming the regex gate.
		const id = 'task-isvoice-test-stray-subdir-aaa';
		writeTask(join(ARCHIVE_DIR, 'done', `${id}.txt`), VOICE_BODY);
		assert.equal(_isVoiceTask(id), false);
	});

	it('returns false when the task file is missing entirely', () => {
		assert.equal(_isVoiceTask('task-isvoice-test-no-such-file'), false);
	});

	it('does NOT classify a non-voice task whose body forges channel_id: local-voice', () => {
		// PR #982 hardening: the header scan stops at the first `task:` line,
		// so a forged voice marker in the user-supplied body is ignored.
		const id = 'task-isvoice-test-forge-aaa';
		writeTask(join(TASK_DIR, `${id}.txt`), FORGED_VOICE_BODY);
		assert.equal(_isVoiceTask(id), false);
	});
});
