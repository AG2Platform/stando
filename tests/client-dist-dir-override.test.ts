import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import type { Server } from 'node:http';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setupTempWorkspace } from './_helpers/temp-workspace.js';
import { startWebServer } from '../src/web-server.js';

// Pluggability test for the CLIENT_DIST_DIR env override.
//
// Background: the React bundle is served from `client/dist/` by default,
// but downstream deployments (private branded builds, third-party UIs,
// the production stando overlay) need to point the voice-agent at their
// own bundle without editing source. This is the seam that makes the
// frontend pluggable — anyone can swap UIs by exporting CLIENT_DIST_DIR
// before launching.
//
// Mirrors sutando/tests/client-dist-dir-override.test.ts so the contract
// stays in lockstep between OSS and private.
//
// The contract this test pins down:
//   1. With CLIENT_DIST_DIR pointing at a custom dir, GET / returns the
//      custom index.html (not the bundled client/dist one).
//   2. With CLIENT_DIST_DIR unset, GET / falls back to the bundled UI.
//   3. The override is re-read on each startWebServer() call so tests
//      can flip the env between server instances (also matters if the
//      voice-agent restarts for any reason).

const PORT_OVERRIDE = 18091;
const PORT_DEFAULT = 18092;
const WS_PORT = 19901;

const { workspace: TEMP_WORKSPACE, cleanup: cleanupTempWorkspace } =
	setupTempWorkspace('client-dist-override');
// state/ is read by other endpoints during startup; create empty so the
// server's readCoreStatus / readVoiceState don't trip on a missing dir.
mkdirSync(join(TEMP_WORKSPACE, 'state'), { recursive: true });

const CUSTOM_DIST = mkdtempSync(join(tmpdir(), 'stando-custom-ui-'));
const SENTINEL_HTML =
	'<!DOCTYPE html><html><head><title>Custom Stando UI</title></head><body><div id="root">CUSTOM_UI_SENTINEL</div></body></html>';
writeFileSync(join(CUSTOM_DIST, 'index.html'), SENTINEL_HTML);
writeFileSync(join(CUSTOM_DIST, 'app.js'), 'console.log("custom bundle");\n');

let server: Server;
const originalEnv = process.env.CLIENT_DIST_DIR;

async function fetchText(port: number, path: string): Promise<{ status: number; body: string; ctype: string }> {
	const res = await fetch(`http://127.0.0.1:${port}${path}`);
	return {
		status: res.status,
		body: await res.text(),
		ctype: res.headers.get('content-type') ?? '',
	};
}

async function startOn(port: number): Promise<Server> {
	const s = startWebServer({ port, host: '127.0.0.1', wsPort: WS_PORT });
	await new Promise<void>((resolve, reject) => {
		if (s.listening) return resolve();
		s.once('listening', () => resolve());
		s.once('error', reject);
	});
	return s;
}

async function stop(s: Server): Promise<void> {
	await new Promise<void>((resolve) => {
		if (!s || !s.listening) return resolve();
		s.close(() => resolve());
	});
}

describe('CLIENT_DIST_DIR — pluggable UI override (Phase 1.7)', () => {
	after(async () => {
		await stop(server);
		if (originalEnv === undefined) delete process.env.CLIENT_DIST_DIR;
		else process.env.CLIENT_DIST_DIR = originalEnv;
		try { rmSync(CUSTOM_DIST, { recursive: true, force: true }); } catch { /* idempotent */ }
		cleanupTempWorkspace();
	});

	it('serves the custom dist when CLIENT_DIST_DIR is set', async () => {
		process.env.CLIENT_DIST_DIR = CUSTOM_DIST;
		server = await startOn(PORT_OVERRIDE);

		const root = await fetchText(PORT_OVERRIDE, '/');
		assert.equal(root.status, 200);
		assert.match(root.body, /CUSTOM_UI_SENTINEL/);
		assert.match(root.ctype, /text\/html/);

		const asset = await fetchText(PORT_OVERRIDE, '/app.js');
		assert.equal(asset.status, 200);
		assert.match(asset.body, /custom bundle/);
		assert.match(asset.ctype, /application\/javascript/);

		await stop(server);
	});

	it('falls back to the bundled client/dist when CLIENT_DIST_DIR is unset', async () => {
		delete process.env.CLIENT_DIST_DIR;
		server = await startOn(PORT_DEFAULT);

		// The bundled UI either returns the real index.html (when pnpm
		// build:client has run) or a 503 with a build hint (fresh
		// checkout). Either way it should NOT be the custom sentinel.
		const root = await fetchText(PORT_DEFAULT, '/');
		assert.ok(root.status === 200 || root.status === 503, `unexpected status ${root.status}`);
		assert.doesNotMatch(root.body, /CUSTOM_UI_SENTINEL/);

		await stop(server);
	});

	it('blocks path traversal in the override dir', async () => {
		process.env.CLIENT_DIST_DIR = CUSTOM_DIST;
		server = await startOn(PORT_OVERRIDE);

		// The dist resolver should reject any path that escapes the dist
		// root (defense in depth — even with a fork-supplied dist, /etc
		// shouldn't be reachable).
		const escape = await fetchText(PORT_OVERRIDE, '/../../../../etc/hosts');
		// SPA fallback returns index.html for missing files, but only
		// AFTER the traversal check rejects the original path. Either
		// way the body must not be /etc/hosts content.
		assert.doesNotMatch(escape.body, /localhost\s+127\.0\.0\.1/);

		await stop(server);
	});
});
