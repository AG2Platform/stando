import { describe, it, after } from 'node:test';
import assert from 'node:assert/strict';
import type { Server } from 'node:http';
import { mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { setupTempWorkspace } from './_helpers/temp-workspace.js';
import { startWebServer } from '../src/web-server.js';

// Phase 5.2: the /presenter endpoint exposes the presenter-mode sentinel
// (state/presenter-mode.sentinel — the same file scripts/presenter-mode.sh
// writes and the Discord/Slack/Telegram bridges poll) to the React UI so it
// can draw the presenter badge.
//
// Contract:
//   - sentinel with a FUTURE ISO expiry → { active: true, expiresAt: <iso> }
//   - sentinel missing                  → { active: false, expiresAt: null }
//   - sentinel with a PAST expiry       → { active: false, expiresAt: null }
//   - sentinel with garbage             → { active: false, expiresAt: null }

const PORT = 18093;
const WS_PORT = 19903;

const { workspace: TEMP_WORKSPACE, cleanup: cleanupTempWorkspace } =
	setupTempWorkspace('web-server-presenter');
const STATE_DIR = join(TEMP_WORKSPACE, 'state');
mkdirSync(STATE_DIR, { recursive: true });
const SENTINEL = join(STATE_DIR, 'presenter-mode.sentinel');

let server: Server;

async function fetchPresenter(): Promise<{ active: boolean; expiresAt: string | null }> {
	const res = await fetch(`http://127.0.0.1:${PORT}/presenter`);
	assert.equal(res.status, 200);
	return res.json() as Promise<{ active: boolean; expiresAt: string | null }>;
}

async function startServer(): Promise<Server> {
	const s = startWebServer({ port: PORT, host: '127.0.0.1', wsPort: WS_PORT });
	await new Promise<void>((resolve, reject) => {
		if (s.listening) return resolve();
		s.once('listening', () => resolve());
		s.once('error', reject);
	});
	return s;
}

describe('/presenter — presenter-mode sentinel endpoint (Phase 5.2)', () => {
	after(async () => {
		await new Promise<void>((resolve) => {
			if (!server || !server.listening) return resolve();
			server.close(() => resolve());
		});
		try { rmSync(SENTINEL, { force: true }); } catch { /* idempotent */ }
		cleanupTempWorkspace();
	});

	it('reports inactive when the sentinel is missing', async () => {
		try { rmSync(SENTINEL, { force: true }); } catch { /* none */ }
		server = await startServer();
		const body = await fetchPresenter();
		assert.equal(body.active, false);
		assert.equal(body.expiresAt, null);
	});

	it('reports active with a future ISO expiry', async () => {
		const future = new Date(Date.now() + 30 * 60 * 1000).toISOString();
		writeFileSync(SENTINEL, future);
		const body = await fetchPresenter();
		assert.equal(body.active, true);
		assert.equal(body.expiresAt, future);
	});

	it('reports inactive for a past expiry', async () => {
		const past = new Date(Date.now() - 60 * 1000).toISOString();
		writeFileSync(SENTINEL, past);
		const body = await fetchPresenter();
		assert.equal(body.active, false);
		assert.equal(body.expiresAt, null);
	});

	it('reports inactive for an unparseable sentinel body', async () => {
		writeFileSync(SENTINEL, 'not-a-timestamp');
		const body = await fetchPresenter();
		assert.equal(body.active, false);
		assert.equal(body.expiresAt, null);
	});
});
