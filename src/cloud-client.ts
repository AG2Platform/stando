// Cloud client for Node services.
//
// Responsibilities:
//   1. Read the cloud auth record written by CloudAuth.swift at
//      $SUTANDO_HOME/cloud-auth.json. The file ships token + userId +
//      machineId + apiBase. Re-read on every call so a sign-in/sign-out
//      from the menu bar takes effect without restarting services.
//   2. Provide `cloudFetch(path, init)` that injects Bearer auth.
//   3. Provide `recordEvent({...})` that buffers events in memory and
//      flushes every 60s (or when the buffer hits 200 events).
//
// Behaviour when not signed in:
//   - `cloudFetch` returns null (callers must handle it).
//   - `recordEvent` is a no-op — events are discarded silently. The
//     desktop is the source of truth for "what is being used"; if no
//     account is signed in, that's the user's choice.

import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

interface CloudAuthRecord {
	token: string;
	userId: string;
	machineId: string;
	apiBase: string;
	savedAt: number;
}

export interface UsageEventInput {
	kind: string;
	units: number;
	costCents?: number;
	metadata?: Record<string, unknown>;
	ts?: Date;
}

const FLUSH_INTERVAL_MS = 60_000;
const FLUSH_THRESHOLD = 200;
const QUEUE_CAP = 5_000;

let _queue: UsageEventInput[] = [];
let _flushTimer: NodeJS.Timeout | null = null;
let _flushing = false;

function expandHome(p: string): string {
	return p.replace(/^~/, process.env.HOME || '');
}

function authFilePath(): string {
	const root = process.env.SUTANDO_HOME
		? expandHome(process.env.SUTANDO_HOME)
		: new URL('..', import.meta.url).pathname.replace(/\/$/, '');
	return join(root, 'cloud-auth.json');
}

/** Read the auth file. Returns null if the user isn't signed in. */
export function loadCloudAuth(): CloudAuthRecord | null {
	const path = authFilePath();
	if (!existsSync(path)) return null;
	try {
		const raw = readFileSync(path, 'utf-8');
		const parsed = JSON.parse(raw) as CloudAuthRecord;
		if (!parsed.token || !parsed.userId || !parsed.apiBase) return null;
		return parsed;
	} catch {
		return null;
	}
}

/** True if a cloud account is currently signed in. */
export function isCloudSignedIn(): boolean {
	return loadCloudAuth() !== null;
}

/** Authenticated fetch. Returns null when not signed in (caller should
 * skip rather than throw — most cloud features are best-effort). */
export async function cloudFetch(path: string, init: RequestInit = {}): Promise<Response | null> {
	const auth = loadCloudAuth();
	if (!auth) return null;
	const url = new URL(path, auth.apiBase).toString();
	const headers = new Headers(init.headers);
	headers.set('Authorization', `Bearer ${auth.token}`);
	if (init.body && !headers.has('Content-Type')) {
		headers.set('Content-Type', 'application/json');
	}
	return fetch(url, { ...init, headers });
}

/** Buffer an event for the next batch. Drops silently when not signed in. */
export function recordEvent(event: UsageEventInput): void {
	if (!isCloudSignedIn()) return;
	if (_queue.length >= QUEUE_CAP) {
		// Drop oldest — we'd rather lose history than memory-pressure the
		// caller. Voice agent runs hot enough that an unbounded queue
		// during a network outage would balloon.
		_queue.splice(0, _queue.length - QUEUE_CAP + 1);
	}
	_queue.push(event);
	scheduleFlush();
	if (_queue.length >= FLUSH_THRESHOLD) {
		void flush();
	}
}

/** Force-flush. Useful in tests + on graceful shutdown. */
export async function flush(): Promise<void> {
	if (_flushing) return;
	if (_queue.length === 0) return;
	_flushing = true;
	const batch = _queue.splice(0, _queue.length);
	try {
		const res = await cloudFetch('/api/usage', {
			method: 'POST',
			body: JSON.stringify({
				events: batch.map((e) => ({
					kind: e.kind,
					units: e.units,
					costCents: e.costCents,
					metadata: e.metadata,
					ts: e.ts ? e.ts.toISOString() : undefined,
				})),
			}),
		});
		if (!res) {
			// Lost auth between recordEvent and flush. Drop the batch
			// silently — events will resume after the user re-signs in.
			return;
		}
		if (!res.ok) {
			// Re-queue at the head so we retry on the next interval, unless
			// the response is 401 (drop everything; user is signed out).
			if (res.status !== 401) _queue.unshift(...batch);
		}
	} catch {
		_queue.unshift(...batch);
	} finally {
		_flushing = false;
	}
}

function scheduleFlush(): void {
	if (_flushTimer) return;
	_flushTimer = setTimeout(() => {
		_flushTimer = null;
		void flush();
	}, FLUSH_INTERVAL_MS);
	// Don't keep the event loop alive just for the flush timer.
	if (typeof _flushTimer.unref === 'function') _flushTimer.unref();
}

/** For tests / shutdown hooks. */
export function _resetForTests(): void {
	if (_flushTimer) {
		clearTimeout(_flushTimer);
		_flushTimer = null;
	}
	_queue = [];
	_flushing = false;
}
