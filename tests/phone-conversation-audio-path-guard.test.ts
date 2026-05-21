import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, unlinkSync, rmSync, symlinkSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { isAllowedAudioPath, AUDIO_ALLOWED_PREFIXES } from '../skills/phone-conversation/scripts/audio_path_guard.js';

// Security-relevant regression guard for the path-allowlist gate added
// to `/play-audio` in `skills/phone-conversation/scripts/conversation-server.ts`.
//
// Pre-fix: that endpoint validated only `existsSync(body.path)` before
// passing the path to `spawn('ffmpeg', ['-i', body.path, …])`. The
// server binds to 0.0.0.0 (LAN-reachable to accommodate ngrok's
// local-tunnel client), so any caller on the local network could have
// ffmpeg open any file the server's user could read and stream the
// audio to whoever was on the active phone call.
//
// This file pins the allowlist contract: only paths under
// `/tmp/sutando-*` (and the `/private/tmp/...` realpath equivalent on
// macOS) pass. Path traversal via `..` and symlink escapes are caught
// by the `realpathSync` collapse before the prefix check.

describe('audio_path_guard.isAllowedAudioPath', () => {
	let tmp: string;
	const created: string[] = [];

	before(() => {
		// macOS prefixes `/var/folders/...` for mkdtemp; we instead use
		// /tmp directly so the realpath matches one of the allowed
		// prefixes for the "allowed" case below.
		tmp = mkdtempSync(join(tmpdir(), 'audio-guard-test-'));
	});

	after(() => {
		for (const p of created) {
			try { unlinkSync(p); } catch {}
		}
		try { rmSync(tmp, { recursive: true, force: true }); } catch {}
	});

	function makeFile(path: string, content = 'x'): string {
		writeFileSync(path, content);
		created.push(path);
		return path;
	}

	it('allows files directly under /tmp/sutando-', () => {
		const p = makeFile('/tmp/sutando-test-allowed-' + Date.now() + '.mp4');
		assert.equal(isAllowedAudioPath(p), true, `expected allow for ${p}`);
	});

	it('rejects /etc/hosts (existing file outside allowlist)', () => {
		// /etc/hosts exists on every macOS / Linux system. NOT under
		// /tmp/sutando-* — must reject.
		assert.equal(isAllowedAudioPath('/etc/hosts'), false);
	});

	it('rejects a /tmp file with a different prefix', () => {
		const p = makeFile('/tmp/other-not-sutando-' + Date.now() + '.mp3');
		assert.equal(isAllowedAudioPath(p), false, `expected reject for ${p}`);
	});

	it('rejects a non-existent file even with allowed prefix', () => {
		// existsSync precheck — defends against an attacker passing a
		// future-write path or a URL.
		assert.equal(isAllowedAudioPath('/tmp/sutando-does-not-exist-12345.mp4'), false);
	});

	it('rejects null/empty/non-string input', () => {
		assert.equal(isAllowedAudioPath(''), false);
		// eslint-disable-next-line @typescript-eslint/no-explicit-any
		assert.equal(isAllowedAudioPath(null as any), false);
		// eslint-disable-next-line @typescript-eslint/no-explicit-any
		assert.equal(isAllowedAudioPath(undefined as any), false);
		// eslint-disable-next-line @typescript-eslint/no-explicit-any
		assert.equal(isAllowedAudioPath(42 as any), false);
	});

	it('rejects a symlink under an allowed prefix that points outside the allowlist', () => {
		// Symlink-escape: attacker drops a symlink at /tmp/sutando-link
		// pointing to /tmp/other-secret. existsSync would return true
		// (follows the link); the OLD allowlist (prefix-check on the
		// LITERAL path) would have accepted it. The realpathSync
		// collapse defeats this.
		const target = makeFile('/tmp/other-not-sutando-symlink-target-' + Date.now() + '.mp3');
		const link = '/tmp/sutando-symlink-pointer-' + Date.now() + '.mp3';
		symlinkSync(target, link);
		created.push(link);
		assert.equal(
			isAllowedAudioPath(link),
			false,
			`symlink ${link} -> ${target} should be rejected by realpath collapse`,
		);
	});

	it('rejects a `..` traversal that escapes the allowed prefix', () => {
		// Textual /tmp/sutando-foo/../other.mp3 collapses to /tmp/other.mp3.
		// Even if the latter file exists, it's not under /tmp/sutando-.
		const target = makeFile('/tmp/other-traversal-target-' + Date.now() + '.mp3');
		const dir = '/tmp/sutando-traversal-dir-' + Date.now();
		mkdirSync(dir);
		const traversal = `${dir}/../${target.split('/').pop()}`;
		try {
			assert.equal(
				isAllowedAudioPath(traversal),
				false,
				`traversal ${traversal} should be rejected after realpath`,
			);
		} finally {
			try { rmSync(dir, { recursive: true, force: true }); } catch {}
		}
	});

	it('AUDIO_ALLOWED_PREFIXES is the documented tight set', () => {
		// Architectural assertion: the allowlist must stay small. Any
		// future addition (e.g., the workspace's results/calls dir
		// for recorded calls) should land deliberately, with this test
		// updated to confirm the new exposure is intended.
		const documented = new Set([
			'/tmp/sutando-',
			'/private/tmp/sutando-',
		]);
		const actual = new Set(AUDIO_ALLOWED_PREFIXES);
		assert.deepEqual(actual, documented, (
			`AUDIO_ALLOWED_PREFIXES has changed unexpectedly. ` +
			`Removed: ${[...documented].filter((p) => !actual.has(p))}, ` +
			`Added: ${[...actual].filter((p) => !documented.has(p))}. ` +
			`Update this test deliberately to confirm the new exposure is intended.`
		));
	});
});
