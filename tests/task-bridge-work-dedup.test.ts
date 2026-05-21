import { describe, it, before, after, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readdirSync, unlinkSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { resolveWorkspace } from '../src/workspace_default.js';
import { workTool } from '../src/task-bridge.js';

// Integration test for the work() dedup window — ports upstream PR #820
// (`fix(task-bridge): dedup work() submissions with identical text within
// 2-minute window`) into this fork. The pre-fix behavior spawned N parallel
// task files when voice over-delegation made Gemini call work() 3-5 times
// with the same text in sub-second succession; each ran independently and
// shipped N duplicate DMs.

const TASK_DIR = join(resolveWorkspace(), 'tasks');

function listTaskFiles(): string[] {
	if (!existsSync(TASK_DIR)) return [];
	return readdirSync(TASK_DIR).filter(f => f.startsWith('task-') && f.endsWith('.txt'));
}

interface WorkResult {
	status?: string;
	taskId?: string;
	message?: string;
}

async function invoke(task: string): Promise<WorkResult> {
	// eslint-disable-next-line @typescript-eslint/no-explicit-any
	return (await (workTool.execute as any)({ task }, null)) as WorkResult;
}

describe('task-bridge workTool — dedup window (PR #820 port)', () => {
	const createdFiles: string[] = [];
	let baselineFiles: Set<string>;

	before(() => {
		mkdirSync(TASK_DIR, { recursive: true });
		baselineFiles = new Set(listTaskFiles());
	});

	afterEach(() => {
		for (const fn of createdFiles) {
			try { unlinkSync(join(TASK_DIR, fn)); } catch { /* already gone */ }
		}
		createdFiles.length = 0;
	});

	after(() => {
		const final = new Set(listTaskFiles());
		const leaked: string[] = [];
		for (const f of final) if (!baselineFiles.has(f)) leaked.push(f);
		assert.deepEqual(leaked, [], 'test leaked task files: ' + leaked.join(', '));
	});

	function trackResult(r: WorkResult): void {
		if (r.taskId && r.status !== 'duplicate') {
			createdFiles.push(r.taskId + '.txt');
		}
	}

	it('second identical call within window returns duplicate with first taskId', async () => {
		const first = await invoke('Render the quarterly report');
		trackResult(first);
		assert.ok(first.taskId, 'first call should produce a taskId');
		assert.notEqual(first.status, 'duplicate', 'first call must not be marked duplicate');

		const second = await invoke('Render the quarterly report');
		trackResult(second);
		assert.equal(second.status, 'duplicate', 'second identical call must dedup');
		assert.equal(second.taskId, first.taskId, 'duplicate must reference the first taskId');
		assert.match(
			second.message ?? '',
			/already.*pending/i,
			'duplicate message should tell the agent to stop re-submitting'
		);
	});

	it('dedup ignores whitespace and case differences', async () => {
		const first = await invoke('Send the deck to Alice');
		trackResult(first);
		// Same task, different whitespace + casing. Production Gemini
		// over-delegation produces near-duplicates like this when the model
		// retries with minor rephrasings; the normalizer must collapse them.
		const second = await invoke('  SEND  the   deck to alice  ');
		trackResult(second);
		assert.equal(second.status, 'duplicate', 'whitespace+case variation should dedup');
		assert.equal(second.taskId, first.taskId);
	});

	it('different task texts each produce a fresh taskId', async () => {
		const first = await invoke('Look up the meeting agenda');
		trackResult(first);
		const second = await invoke('Draft an email to Bob');
		trackResult(second);
		assert.notEqual(second.status, 'duplicate', 'distinct task should not dedup');
		assert.ok(second.taskId);
		assert.notEqual(second.taskId, first.taskId, 'distinct task should get a fresh taskId');
	});
});
