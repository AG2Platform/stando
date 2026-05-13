// Cloud client for Node services.
//
// Responsibilities:
//   1. Read the cloud auth record written by CloudAuth.swift at
//      $SUTANDO_HOME/cloud-auth.json. The file ships token + userId +
//      machineId + apiBase. Re-read on every call so a sign-in/sign-out
//      from the menu bar takes effect without restarting services.
//   2. Provide `cloudFetch(path, init)` that injects Bearer auth.
//   3. Provide `recordEvent({...})` that buffers usage events and
//      flushes every 60s (or when the buffer hits 200 events).
//   4. Provide one-shot helpers for the lower-frequency event streams
//      that admin views consume: onboarding milestones, error reports,
//      session start/end. These are fire-and-forget — failure never
//      crashes the caller, and "not signed in" is a silent no-op.
//
// Behaviour when not signed in:
//   - `cloudFetch` returns null (callers must handle it).
//   - `recordEvent` / `recordOnboarding` / `recordError` / `startSession`
//     / `endSession` are no-ops. The desktop is the source of truth for
//     "what is being used"; if no account is signed in, that's the
//     user's choice.

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

export interface ErrorEventInput {
	kind: string;
	severity: 'info' | 'warn' | 'error' | 'fatal';
	message: string;
	stack?: string;
	metadata?: Record<string, unknown>;
	ts?: Date;
}

export interface SessionStartInput {
	kind: 'voice' | 'phone.outbound' | 'phone.inbound';
	startedAt?: Date;
	metadata?: Record<string, unknown>;
}

export interface SessionEndInput {
	turnCount?: number;
	toolsUsed?: Record<string, number>;
	endedReason?: 'user' | 'timeout' | 'error' | 'system';
	endedAt?: Date;
	metadata?: Record<string, unknown>;
}

const FLUSH_INTERVAL_MS = 60_000;
const FLUSH_THRESHOLD = 200;
const QUEUE_CAP = 5_000;

let _queue: UsageEventInput[] = [];
let _flushTimer: NodeJS.Timeout | null = null;
let _flushing = false;

// ============================================================
// Cap-hit accounting hook
// ============================================================
// /api/usage now returns an `accounting` array describing the rate-limit
// outcome for each event in the batch. When the server denies a kind
// (tier cap exhausted + wallet empty), the entry has `allowed: false`
// — surface those so callers (voice-agent, bridges) can react.
//
// Beta posture: voice-agent reads the listener to set an `exhausted`
// flag that biases its next turn toward explaining the cap; phone /
// channel surfaces use it via planned cap-hit handlers (currently TODO).
// Other code can ignore the hook entirely; the events are still
// recorded server-side regardless.

export interface CapHitInfo {
	kind: string;
	chargedTo: 'tier' | 'wallet' | 'denied' | 'free' | 'admin';
	group: string | null;
	reason?: string;
	walletBalance: number;
	tierRemainingCanonical: number;
}

export interface UsageAccountingResult {
	allowed: boolean;
	chargedTo: 'tier' | 'wallet' | 'denied' | 'free' | 'admin';
	group: string | null;
	tierRemainingCanonical: number;
	walletBalance: number;
	walletDebited?: number;
	reason?: string;
}

let _capHitListener: ((info: CapHitInfo) => void) | null = null;
let _lastWalletBalance: number | null = null;

export function onCapHit(listener: ((info: CapHitInfo) => void) | null): void {
	_capHitListener = listener;
}

/** Wallet balance from the most recent /api/usage response. Null until
 * the first flush completes (or while not signed in). Useful for the
 * menu-bar to surface "Wallet: $X" without an extra round-trip. */
export function lastKnownWalletCredits(): number | null {
	return _lastWalletBalance;
}

// Cached app version. Read once from the bundled Info.plist or
// package.json at first use and stamped onto every event so the cloud
// admin views can do release-vs-release regression analysis.
let _appVersion: string | null = null;

function readAppVersion(): string {
	if (_appVersion !== null) return _appVersion;
	// 1. Bundled .app — Info.plist sits alongside MacOS/Sutando, two
	//    levels up from $resourcePath/repo/src/cloud-client.{ts,js}.
	try {
		const infoPlist = new URL('../../../Info.plist', import.meta.url).pathname;
		if (existsSync(infoPlist)) {
			const text = readFileSync(infoPlist, 'utf-8');
			const m = text.match(
				/<key>CFBundleShortVersionString<\/key>\s*<string>([^<]+)<\/string>/,
			);
			if (m && m[1]) {
				_appVersion = m[1];
				return _appVersion;
			}
		}
	} catch {
		// fall through to package.json
	}
	// 2. Dev workflow — package.json next to src/.
	try {
		const pkg = new URL('../package.json', import.meta.url).pathname;
		if (existsSync(pkg)) {
			const text = readFileSync(pkg, 'utf-8');
			const parsed = JSON.parse(text) as { version?: string };
			if (parsed.version) {
				_appVersion = parsed.version;
				return _appVersion;
			}
		}
	} catch {
		// fall through to default
	}
	_appVersion = '0.0.0';
	return _appVersion;
}

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
		const appVersion = readAppVersion();
		const res = await cloudFetch('/api/usage', {
			method: 'POST',
			body: JSON.stringify({
				events: batch.map((e) => ({
					kind: e.kind,
					units: e.units,
					costCents: e.costCents,
					metadata: e.metadata,
					appVersion,
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
			return;
		}
		// Surface per-event rate-limit accounting back to subscribers.
		try {
			const body = (await res.json().catch(() => ({}))) as {
				accounting?: Array<{ kind: string; result: UsageAccountingResult }>;
			};
			if (body.accounting && body.accounting.length > 0) {
				const last = body.accounting[body.accounting.length - 1];
				if (last) _lastWalletBalance = last.result.walletBalance;
				if (_capHitListener) {
					for (const a of body.accounting) {
						if (!a.result.allowed) {
							_capHitListener({
								kind: a.kind,
								chargedTo: a.result.chargedTo,
								group: a.result.group,
								reason: a.result.reason,
								walletBalance: a.result.walletBalance,
								tierRemainingCanonical: a.result.tierRemainingCanonical,
							});
						}
					}
				}
			}
		} catch {
			// Body parse failure — events accepted, no accounting to surface.
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
	_appVersion = null;
}

// ============================================================
// Onboarding events
// ============================================================
// Fired at each Settings stepper checkpoint + first-skill-success
// derivations the desktop wants to attribute. Server enforces
// uniqueness on (user_id, step) so retries are safe.

const KNOWN_ONBOARDING_STEPS = new Set([
	'gemini_key_set',
	'claude_installed',
	'perms_granted',
	'services_installed',
	'firstrun_complete',
	'first_voice',
	'first_task',
	'first_phone',
	'first_image',
]);

/** Record an onboarding milestone. Idempotent on the server side
 * (unique index on user_id+step). Fire-and-forget — never throws.
 *
 * Steps `signup` / `device_linked` / `subscribed` are server-emitted
 * from `users` / `devices` / Stripe webhooks; emitting them from the
 * desktop is harmless but redundant. */
export function recordOnboarding(step: string, metadata?: Record<string, unknown>): void {
	if (!isCloudSignedIn()) return;
	if (!KNOWN_ONBOARDING_STEPS.has(step)) {
		// Refuse silently rather than ship typos to the cloud filter.
		return;
	}
	void (async () => {
		try {
			await cloudFetch('/api/onboarding', {
				method: 'POST',
				body: JSON.stringify({
					events: [{ step, metadata, ts: new Date().toISOString() }],
				}),
			});
		} catch {
			// telemetry must never crash the caller
		}
	})();
}

// ============================================================
// Error events
// ============================================================

/** Report a recoverable or fatal error to the cloud reliability board.
 * Fire-and-forget. Don't include PII in `message` — the admin panel
 * surfaces it raw. */
export function recordError(input: ErrorEventInput): void {
	if (!isCloudSignedIn()) return;
	void (async () => {
		try {
			const appVersion = readAppVersion();
			await cloudFetch('/api/errors', {
				method: 'POST',
				body: JSON.stringify({
					events: [
						{
							kind: input.kind,
							severity: input.severity,
							message: input.message.slice(0, 2000),
							stack: input.stack ? input.stack.slice(0, 20000) : undefined,
							appVersion,
							metadata: input.metadata,
							ts: (input.ts ?? new Date()).toISOString(),
						},
					],
				}),
			});
		} catch {
			// Errors emitting errors. Drop.
		}
	})();
}

// ============================================================
// Sessions (voice / phone)
// ============================================================

/** Begin a session. Returns the server-assigned id, or null when not
 * signed in / network failed. The caller should keep the id and pass
 * it to `endSession`; if it's null, just skip the close call. */
export async function startSession(input: SessionStartInput): Promise<string | null> {
	if (!isCloudSignedIn()) return null;
	try {
		const appVersion = readAppVersion();
		const res = await cloudFetch('/api/sessions', {
			method: 'POST',
			body: JSON.stringify({
				kind: input.kind,
				startedAt: (input.startedAt ?? new Date()).toISOString(),
				appVersion,
				metadata: input.metadata,
			}),
		});
		if (!res || !res.ok) return null;
		const body = (await res.json()) as { id?: string };
		return body.id ?? null;
	} catch {
		return null;
	}
}

/** Close a session. Tolerates a null id (no-op) so callers don't have
 * to branch when sign-in failed at start time. */
export async function endSession(id: string | null, input: SessionEndInput = {}): Promise<void> {
	if (!id) return;
	if (!isCloudSignedIn()) return;
	try {
		await cloudFetch('/api/sessions', {
			method: 'PATCH',
			body: JSON.stringify({
				id,
				endedAt: (input.endedAt ?? new Date()).toISOString(),
				turnCount: input.turnCount,
				toolsUsed: input.toolsUsed,
				endedReason: input.endedReason,
				metadata: input.metadata,
			}),
		});
	} catch {
		// Drop.
	}
}
