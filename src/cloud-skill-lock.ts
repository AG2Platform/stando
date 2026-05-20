/**
 * Per-slug lockfile for the cloud-skills install dir.
 *
 * Two surfaces extract tarballs into
 * `~/Library/Application Support/Sutando/cloud-skills/<slug>/`:
 *   - `station_install` (voice-callable, via `skills/superpower-station/tools.ts`)
 *   - `syncOnce()` (background loop, via `src/cloud-skill-sync.ts`)
 *
 * Both do `rmSync(target, recursive=true)` then `tar -xzf`. Concurrent
 * runs on the same slug clobber each other — the second `rmSync` can
 * race the first's `tar -xzf`, leaving a half-extracted skill on disk.
 *
 * This module exposes `withSkillLock(slug, fn)`: a thin wrapper that
 * acquires an exclusive-create lockfile keyed by slug, runs the
 * critical section, and releases on exit. Stale locks (>5 min old)
 * are stolen so a crashed process doesn't block future installs.
 */

import { existsSync, mkdirSync, openSync, closeSync, writeFileSync, statSync, unlinkSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { resolveWorkspace } from './workspace_default.js';

const STALE_LOCK_MS = 5 * 60 * 1000;
const MAX_WAIT_MS = 30 * 1000;
const POLL_MS = 250;

function locksDir(): string {
	return join(resolveWorkspace(), 'cloud-skills');
}

function lockPath(slug: string): string {
	return join(locksDir(), `.lock-${slug}`);
}

function tryAcquire(path: string): boolean {
	try {
		const fd = openSync(path, 'wx');
		try {
			writeFileSync(fd, JSON.stringify({ pid: process.pid, ts: Date.now() }));
		} finally {
			closeSync(fd);
		}
		return true;
	} catch (err) {
		if ((err as NodeJS.ErrnoException).code === 'EEXIST') return false;
		throw err;
	}
}

function isStale(path: string): boolean {
	try {
		const st = statSync(path);
		return Date.now() - st.mtimeMs > STALE_LOCK_MS;
	} catch {
		return false;
	}
}

async function sleep(ms: number): Promise<void> {
	return new Promise((res) => setTimeout(res, ms));
}

/**
 * Acquire the lock for `slug`, run `fn`, release. Throws if the lock
 * can't be acquired within MAX_WAIT_MS — caller should surface that
 * as a retryable error rather than clobbering the other writer.
 */
export async function withSkillLock<T>(slug: string, fn: () => Promise<T> | T): Promise<T> {
	mkdirSync(locksDir(), { recursive: true });
	const path = lockPath(slug);
	const deadline = Date.now() + MAX_WAIT_MS;
	while (true) {
		if (tryAcquire(path)) break;
		if (isStale(path)) {
			try {
				unlinkSync(path);
			} catch {
				// Another process beat us to it; loop and try again.
			}
			continue;
		}
		if (Date.now() > deadline) {
			throw new Error(
				`skill-lock: timed out waiting for ${slug} (another install/sync in progress)`,
			);
		}
		await sleep(POLL_MS);
	}
	try {
		return await fn();
	} finally {
		try {
			unlinkSync(path);
		} catch {
			// Lock already released by a stale-cleanup elsewhere; harmless.
		}
	}
}
