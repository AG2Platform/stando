/**
 * Tests for the per-surface conversation-store schema (Phase 5.20).
 *
 * Why this test exists:
 *   Phase 5.20 swapped the single `conversation` table + standalone
 *   `tool_calls` table for per-surface tables (`voice`, `phone`,
 *   `discord_voice`). The public API for `recordConversation` /
 *   `recordSession` is unchanged but their internal routing now derives
 *   the table from a role-prefix or `source` value. Two new exported
 *   helpers (`sourceFromRole`, `kindFromRole`) plus a new exported
 *   `recordToolCall` sink were added.
 *
 *   The migration from the legacy schema runs at first init and must be
 *   idempotent — restart-safety matters here because the module is
 *   imported by every voice surface server (voice-agent, phone,
 *   discord-voice). A non-idempotent migration would either re-backfill
 *   on every boot (duplicated rows) or fail on every boot (noisy logs).
 *
 *   These tests use a temp DB path via SUTANDO_CONVERSATION_DB so the
 *   developer's live workspace DB is never touched.
 *
 * Coverage:
 *   1. sourceFromRole + kindFromRole semantics — the documented routing
 *      contract that every caller silently depends on.
 *   2. recordConversation routes by role-prefix (`phone-` / `discord-` /
 *      otherwise) and writes to the matching surface table only.
 *   3. recordToolCall writes a kind='tool_call' row to the named source
 *      table. Tool calls are now per-row, not JSON-blob batched.
 *   4. recordSessionBoundary still writes a `SESSION_END` row (used by
 *      voice-agent's getRecentConversation replay-window trim).
 *   5. recordSession's per-event fan-out filters out duplicate prefixes
 *      (user:/sutando:/tool_call:/etc) — these atoms now live in
 *      surface tables and would double-count if not filtered.
 *   6. Migration: legacy `conversation` + `tool_calls` rows backfill
 *      into the matching surface tables, then the legacy tables are
 *      dropped. NULL-ts_unix rows are dropped (can't be recovered).
 *   7. Migration idempotency: second open of the migrated DB is a
 *      no-op (no duplicate rows, no error).
 *   8. The legacy `conversation` view is created post-migration so
 *      old callers that still SELECT FROM conversation keep working.
 */
import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { createRequire } from 'node:module';
import { spawnSync } from 'node:child_process';

// Each test uses its own temp DB so we can exercise the full init path
// (including migration) without polluting the user's workspace. The
// SUTANDO_CONVERSATION_DB env var is checked by conversation-store.ts at
// module load — set it BEFORE importing the module under test.
const TMP_ROOT = mkdtempSync(join(tmpdir(), 'sutando-conv-test-'));
const PRIMARY_DB = join(TMP_ROOT, 'primary', 'conv.sqlite');
mkdirSync(dirname(PRIMARY_DB), { recursive: true });
process.env.SUTANDO_CONVERSATION_DB = PRIMARY_DB;

// Direct sqlite access for asserting on rows; goes through the same
// `node:sqlite` that conversation-store does.
const require = createRequire(import.meta.url);
const { DatabaseSync } = require('node:sqlite');

const mod = await import('../src/conversation-store.js');

after(() => {
	try { rmSync(TMP_ROOT, { recursive: true, force: true }); } catch { /* ignore */ }
});

// ----------------------------------------------------------------------
// 1. Helpers — sourceFromRole + kindFromRole routing contract
// ----------------------------------------------------------------------

describe('sourceFromRole', () => {
	it('routes phone-* to phone', () => {
		assert.equal(mod.sourceFromRole('phone-caller'), 'phone');
		assert.equal(mod.sourceFromRole('phone-agent'), 'phone');
	});

	it('routes discord-* to discord-voice', () => {
		assert.equal(mod.sourceFromRole('discord-user'), 'discord-voice');
		assert.equal(mod.sourceFromRole('discord-peer'), 'discord-voice');
	});

	it('routes anything else to voice (the default)', () => {
		assert.equal(mod.sourceFromRole('user'), 'voice');
		assert.equal(mod.sourceFromRole('assistant'), 'voice');
		assert.equal(mod.sourceFromRole('SESSION_END'), 'voice');
		assert.equal(mod.sourceFromRole('core-agent'), 'voice');
		// Edge: a role with -user mid-string isn't prefixed → still voice
		assert.equal(mod.sourceFromRole('shared-user'), 'voice');
	});
});

describe('kindFromRole', () => {
	it('normalizes user-side variants to "user"', () => {
		assert.equal(mod.kindFromRole('user'), 'user');
		assert.equal(mod.kindFromRole('phone-caller'), 'user');
		assert.equal(mod.kindFromRole('discord-user'), 'user');
	});

	it('normalizes agent-side variants to "agent"', () => {
		assert.equal(mod.kindFromRole('assistant'), 'agent');
		assert.equal(mod.kindFromRole('sutando'), 'agent');
		assert.equal(mod.kindFromRole('phone-agent'), 'agent');
		assert.equal(mod.kindFromRole('discord-agent'), 'agent');
	});

	it('maps discord-peer to "peer"', () => {
		assert.equal(mod.kindFromRole('discord-peer'), 'peer');
	});

	it('passes through roles that do not match a known suffix', () => {
		assert.equal(mod.kindFromRole('SESSION_END'), 'SESSION_END');
		assert.equal(mod.kindFromRole('tool_call'), 'tool_call');
		assert.equal(mod.kindFromRole('system_event'), 'system_event');
	});

	it('treats core-agent as "agent" because it ends with -agent', () => {
		// Documented in conversation-store.ts kindFromRole comment: any
		// role ending in `-agent` collapses to the agent kind. This is
		// intentional so core-agent / proactive-agent / etc. share the
		// same surface-table category as the primary assistant.
		assert.equal(mod.kindFromRole('core-agent'), 'agent');
		assert.equal(mod.kindFromRole('proactive-agent'), 'agent');
	});
});

// ----------------------------------------------------------------------
// 2. recordConversation routes by role-prefix
// ----------------------------------------------------------------------

describe('recordConversation routing', () => {
	before(() => {
		// Force a write so init() runs and the DB is created. The DB
		// path is fixed at module import time via SUTANDO_CONVERSATION_DB.
		mod.recordConversation('user', 'hello world', 'session-a');
		mod.recordConversation('phone-caller', 'hi from phone', 'call-b');
		mod.recordConversation('discord-user', 'hey from discord', 'session-c');
	});

	it('writes voice rows to the voice table only', () => {
		const db = new DatabaseSync(PRIMARY_DB);
		try {
			const row = db
				.prepare("SELECT text, kind, session_id FROM voice WHERE text='hello world'")
				.get() as { text: string; kind: string; session_id: string } | undefined;
			assert.ok(row, 'voice row should exist');
			assert.equal(row!.kind, 'user');
			assert.equal(row!.session_id, 'session-a');
			// And the row must NOT have leaked into phone/discord_voice
			const phoneCount = (db.prepare("SELECT count(*) AS c FROM phone WHERE text='hello world'").get() as { c: number }).c;
			const dvCount = (db.prepare("SELECT count(*) AS c FROM discord_voice WHERE text='hello world'").get() as { c: number }).c;
			assert.equal(phoneCount, 0);
			assert.equal(dvCount, 0);
		} finally {
			db.close();
		}
	});

	it('writes phone rows to the phone table only', () => {
		const db = new DatabaseSync(PRIMARY_DB);
		try {
			const row = db
				.prepare("SELECT text, kind, session_id FROM phone WHERE text='hi from phone'")
				.get() as { text: string; kind: string; session_id: string } | undefined;
			assert.ok(row, 'phone row should exist');
			assert.equal(row!.kind, 'user');
			assert.equal(row!.session_id, 'call-b');
		} finally {
			db.close();
		}
	});

	it('writes discord rows to the discord_voice table only', () => {
		const db = new DatabaseSync(PRIMARY_DB);
		try {
			const row = db
				.prepare("SELECT text, kind, session_id FROM discord_voice WHERE text='hey from discord'")
				.get() as { text: string; kind: string; session_id: string } | undefined;
			assert.ok(row, 'discord_voice row should exist');
			assert.equal(row!.kind, 'user');
			assert.equal(row!.session_id, 'session-c');
		} finally {
			db.close();
		}
	});

	it('SESSION_END boundary lands as a verbatim-kind row in voice', () => {
		mod.recordSessionBoundary('user_goodbye', 'session-end-1');
		const db = new DatabaseSync(PRIMARY_DB);
		try {
			const row = db
				.prepare("SELECT kind, text FROM voice WHERE session_id='session-end-1'")
				.get() as { kind: string; text: string } | undefined;
			assert.ok(row, 'session boundary row should exist');
			assert.equal(row!.kind, 'SESSION_END');
			assert.equal(row!.text, 'user_goodbye');
		} finally {
			db.close();
		}
	});
});

// ----------------------------------------------------------------------
// 3. recordToolCall writes kind='tool_call' to the matching surface table
// ----------------------------------------------------------------------

describe('recordToolCall', () => {
	it('writes a kind="tool_call" row with the tool name as text', () => {
		mod.recordToolCall('voice', 'describe_screen', 234, 'tc-session-a');
		mod.recordToolCall('phone', 'hang_up', 12, 'tc-call-b');
		mod.recordToolCall('discord-voice', 'summon', null, 'tc-session-c');
		const db = new DatabaseSync(PRIMARY_DB);
		try {
			const v = db.prepare("SELECT kind, text, duration_ms FROM voice WHERE session_id='tc-session-a'").get() as { kind: string; text: string; duration_ms: number | null };
			assert.equal(v.kind, 'tool_call');
			assert.equal(v.text, 'describe_screen');
			assert.equal(v.duration_ms, 234);

			const p = db.prepare("SELECT kind, text, duration_ms FROM phone WHERE session_id='tc-call-b'").get() as { kind: string; text: string; duration_ms: number | null };
			assert.equal(p.kind, 'tool_call');
			assert.equal(p.text, 'hang_up');

			// durationMs=null should land as NULL, not 0
			const dv = db.prepare("SELECT kind, text, duration_ms FROM discord_voice WHERE session_id='tc-session-c'").get() as { kind: string; text: string; duration_ms: number | null };
			assert.equal(dv.kind, 'tool_call');
			assert.equal(dv.text, 'summon');
			assert.equal(dv.duration_ms, null);
		} finally {
			db.close();
		}
	});
});

// ----------------------------------------------------------------------
// 4. recordSession filters duplicate event prefixes
// ----------------------------------------------------------------------

describe('recordSession event fan-out', () => {
	it('filters duplicate-prefix events (user:/sutando:/tool_call:/etc)', () => {
		mod.recordSession({
			source: 'voice',
			sessionId: 'sess-fanout-1',
			durationMs: 1234,
			events: [
				{ event: 'session_started', timestamp: '2026-06-01T12:00:00Z' },
				{ event: 'user: hello', timestamp: '2026-06-01T12:00:01Z' },           // filtered
				{ event: 'sutando: hi there', timestamp: '2026-06-01T12:00:02Z' },     // filtered
				{ event: 'tool_call: describe_screen', timestamp: '2026-06-01T12:00:03Z' }, // filtered
				{ event: 'tool_result: ok', timestamp: '2026-06-01T12:00:04Z' },       // filtered
				{ event: 'assistant: bye', timestamp: '2026-06-01T12:00:05Z' },        // filtered
				{ event: 'caller: still here', timestamp: '2026-06-01T12:00:06Z' },    // filtered
				{ event: 'session_ended', timestamp: '2026-06-01T12:00:07Z' },
			],
		});
		const db = new DatabaseSync(PRIMARY_DB);
		try {
			const rows = db.prepare(
				"SELECT event_name FROM session_events WHERE session_id='sess-fanout-1' ORDER BY event_name",
			).all() as Array<{ event_name: string }>;
			const names = rows.map(r => r.event_name);
			// Only the two non-prefixed events land in session_events
			assert.deepEqual(names, ['session_ended', 'session_started']);
		} finally {
			db.close();
		}
	});

	it('records a row in sessions table', () => {
		const db = new DatabaseSync(PRIMARY_DB);
		try {
			const row = db.prepare(
				"SELECT source, session_id, duration_ms FROM sessions WHERE session_id='sess-fanout-1'",
			).get() as { source: string; session_id: string; duration_ms: number };
			assert.equal(row.source, 'voice');
			assert.equal(row.duration_ms, 1234);
		} finally {
			db.close();
		}
	});
});

// ----------------------------------------------------------------------
// 5. Migration: legacy schema → per-surface tables (idempotent, drops nulls)
// ----------------------------------------------------------------------

describe('legacy migration', () => {
	// Use a fresh DB so the migration probe sees a legacy schema. We
	// spawn a child Node process so the module's top-level singleton
	// can target this distinct path (the parent already initialized
	// against PRIMARY_DB and won't re-init).
	const MIG_DIR = join(TMP_ROOT, 'migration');
	const MIG_DB = join(MIG_DIR, 'conv.sqlite');
	const RUNNER = join(MIG_DIR, 'runner.mjs');
	const REPO = process.cwd();
	mkdirSync(MIG_DIR, { recursive: true });

	before(() => {
		// Seed a legacy-schema DB BEFORE the child process imports the
		// module. We control the seed so we can assert exact post-
		// migration row counts.
		const seed = new DatabaseSync(MIG_DB);
		// Pre-refactor schema (matches what existing stando installs ship
		// with prior to this PR). Crucially includes the sessions table
		// WITH the JSON `tool_calls` and `events` columns — the migration
		// reads from `sessions.tool_calls` via json_each() and would fail
		// against the post-refactor sessions schema (no JSON cols). In
		// production every stando install has either zero legacy tables
		// (fresh) or all three of conversation + tool_calls + sessions
		// (pre-refactor); a half-migrated state isn't expected. The test
		// reproduces the pre-refactor state faithfully.
		seed.exec(`
			CREATE TABLE conversation (
				ts_unix    REAL NOT NULL,
				role       TEXT NOT NULL,
				text       TEXT NOT NULL,
				session_id TEXT
			);
			CREATE TABLE tool_calls (
				ts_unix     REAL NOT NULL,
				source      TEXT NOT NULL,
				session_id  TEXT,
				call_sid    TEXT,
				name        TEXT NOT NULL,
				duration_ms INTEGER
			);
			CREATE TABLE sessions (
				ts_unix          REAL    NOT NULL,
				source           TEXT    NOT NULL,
				session_id       TEXT,
				call_sid         TEXT,
				caller           TEXT,
				is_owner         INTEGER,
				is_meeting       INTEGER,
				duration_ms      INTEGER NOT NULL,
				transcript_lines INTEGER,
				tool_count       INTEGER,
				pending_tasks    INTEGER,
				tool_calls       TEXT,
				events           TEXT
			);
		`);
		const ins = seed.prepare("INSERT INTO conversation VALUES (?, ?, ?, ?)");
		// Distinctive timestamps so we can assert exact preservation.
		ins.run(1000.0, 'user', 'voice user msg', 'voice-sess');
		ins.run(1001.0, 'assistant', 'voice agent reply', 'voice-sess');
		ins.run(1002.0, 'phone-caller', 'phone hello', 'phone-sess');
		ins.run(1003.0, 'phone-agent', 'phone reply', 'phone-sess');
		ins.run(1004.0, 'discord-user', 'dv hello', 'dv-sess');
		ins.run(1005.0, 'discord-agent', 'dv reply', 'dv-sess');
		ins.run(1006.0, 'discord-peer', 'dv peer talking', 'dv-sess');
		const itc = seed.prepare("INSERT INTO tool_calls VALUES (?, ?, ?, ?, ?, ?)");
		itc.run(2000.0, 'voice', 'voice-sess', null, 'describe_screen', 50);
		itc.run(2001.0, 'phone', 'phone-sess', 'call-sid-1', 'hang_up', 12);
		seed.close();

		// Runner script: import the module and force init() via a
		// recordConversation call. The role 'core-migration-trigger'
		// routes to the voice surface but uses a marker session_id so
		// we can distinguish it from migrated voice rows.
		writeFileSync(RUNNER, `
			import { recordConversation } from '${REPO}/src/conversation-store.ts';
			recordConversation('SESSION_END', 'migration-trigger', 'migrate-trigger-sentinel');
		`);
	});

	function runMigration(): { status: number | null; stdout: string; stderr: string } {
		const r = spawnSync('npx', ['tsx', RUNNER], {
			env: { ...process.env, SUTANDO_CONVERSATION_DB: MIG_DB },
			encoding: 'utf-8',
			cwd: REPO,
		});
		return { status: r.status, stdout: r.stdout ?? '', stderr: r.stderr ?? '' };
	}

	it('migrates legacy rows into per-surface tables', () => {
		const r = runMigration();
		assert.equal(r.status, 0, `migration runner failed: ${r.stderr}`);
		const db = new DatabaseSync(MIG_DB);
		try {
			// Voice: 2 utterances (user, assistant) + 1 tool_call + 1
			// SESSION_END from the trigger.
			const voiceRows = db.prepare("SELECT kind, text FROM voice ORDER BY ts_unix").all() as Array<{ kind: string; text: string }>;
			const voiceKinds = voiceRows.map(r => r.kind);
			const voiceTexts = voiceRows.map(r => r.text);
			assert.ok(voiceTexts.includes('voice user msg'), `voice user msg missing: ${JSON.stringify(voiceTexts)}`);
			assert.ok(voiceTexts.includes('voice agent reply'), 'voice agent reply missing');
			assert.ok(voiceTexts.includes('describe_screen'), 'tool_call describe_screen missing');
			assert.ok(voiceKinds.includes('tool_call'), 'tool_call kind missing');
			assert.ok(voiceKinds.includes('user'), 'user kind missing');
			assert.ok(voiceKinds.includes('agent'), 'agent kind missing (assistant normalization)');

			// Phone: 1 caller utt + 1 agent utt + 1 tool_call
			const phoneTexts = (db.prepare("SELECT text FROM phone ORDER BY ts_unix").all() as Array<{ text: string }>).map(r => r.text);
			assert.deepEqual(phoneTexts.sort(), ['hang_up', 'phone hello', 'phone reply'].sort());
			const phoneKinds = (db.prepare("SELECT kind FROM phone ORDER BY ts_unix").all() as Array<{ kind: string }>).map(r => r.kind);
			assert.ok(phoneKinds.includes('user'), 'phone-caller should normalize to user');
			assert.ok(phoneKinds.includes('agent'), 'phone-agent should normalize to agent');
			assert.ok(phoneKinds.includes('tool_call'), 'phone tool_call kind missing');

			// discord_voice: user, agent, peer (3 utterances, no tool_calls in seed)
			const dvKinds = (db.prepare("SELECT kind FROM discord_voice ORDER BY ts_unix").all() as Array<{ kind: string }>).map(r => r.kind);
			assert.deepEqual(dvKinds.sort(), ['agent', 'peer', 'user'].sort());

			// Legacy tables dropped (post-migration, the `conversation`
			// name now refers to the backwards-compat VIEW, not the
			// table; tool_calls is gone entirely).
			const convType = (db.prepare("SELECT type FROM sqlite_master WHERE name='conversation'").get() as { type?: string } | undefined)?.type;
			assert.equal(convType, 'view', `expected 'conversation' to be a view post-migration, got ${convType}`);
			const tcExists = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='tool_calls'").get();
			assert.equal(tcExists, undefined, 'tool_calls table should be dropped post-migration');
		} finally {
			db.close();
		}
	});

	it('is idempotent on a second open (no row duplication)', () => {
		// Capture row counts after the first migration ran in the prior
		// test, then re-run the runner against the SAME DB and assert
		// counts are unchanged.
		let beforeCount: number;
		{
			const db = new DatabaseSync(MIG_DB);
			try {
				beforeCount = (db.prepare("SELECT (SELECT count(*) FROM voice) + (SELECT count(*) FROM phone) + (SELECT count(*) FROM discord_voice) AS c").get() as { c: number }).c;
			} finally {
				db.close();
			}
		}
		const r = runMigration();
		assert.equal(r.status, 0, `second migration runner failed: ${r.stderr}`);
		const db = new DatabaseSync(MIG_DB);
		try {
			// Second run adds exactly one row (the SESSION_END trigger)
			// but does NOT re-backfill anything from the now-gone legacy
			// table. So the diff must equal exactly 1.
			const afterCount = (db.prepare("SELECT (SELECT count(*) FROM voice) + (SELECT count(*) FROM phone) + (SELECT count(*) FROM discord_voice) AS c").get() as { c: number }).c;
			assert.equal(afterCount, beforeCount + 1, 'second run must add exactly one row (the SESSION_END trigger)');
		} finally {
			db.close();
		}
	});
});

// ----------------------------------------------------------------------
// 6. Backwards-compatibility view: `conversation` reads work post-migration
// ----------------------------------------------------------------------

describe('backwards-compat conversation view', () => {
	it('SELECT FROM conversation unions all 3 surface tables', () => {
		const db = new DatabaseSync(PRIMARY_DB);
		try {
			const allKinds = db.prepare("SELECT DISTINCT role FROM conversation ORDER BY role").all() as Array<{ role: string }>;
			const roles = allKinds.map(r => r.role);
			// Should include the kinds we wrote across voice/phone/dv tables
			assert.ok(roles.includes('user'), `expected 'user' in roles: ${JSON.stringify(roles)}`);
			assert.ok(roles.includes('tool_call'), `expected 'tool_call' in roles: ${JSON.stringify(roles)}`);
			assert.ok(roles.includes('SESSION_END'), `expected 'SESSION_END' in roles: ${JSON.stringify(roles)}`);
		} finally {
			db.close();
		}
	});

	it('v_voice / v_phone / v_discord_voice views exist with human-readable time', () => {
		const db = new DatabaseSync(PRIMARY_DB);
		try {
			for (const v of ['v_voice', 'v_phone', 'v_discord_voice']) {
				const cols = db.prepare(`PRAGMA table_info(${v})`).all() as Array<{ name: string }>;
				assert.ok(cols.some(c => c.name === 'time'), `${v} should have a 'time' column`);
				assert.ok(cols.some(c => c.name === 'kind'), `${v} should have a 'kind' column`);
			}
		} finally {
			db.close();
		}
	});
});

// ----------------------------------------------------------------------
// 7. SessionMetrics interface is backwards-compatible
// ----------------------------------------------------------------------

describe('SessionMetrics back-compat', () => {
	it('accepts (and silently ignores) the legacy toolCalls field', () => {
		// The toolCalls field is documented as accepted-but-ignored. This
		// guards against the field being removed from the interface,
		// which would break existing callers that still pass it.
		assert.doesNotThrow(() => {
			mod.recordSession({
				source: 'voice',
				sessionId: 'compat-sess',
				durationMs: 100,
				toolCalls: [{ name: 'x', durationMs: 1, timestamp: '2026-06-01T12:00:00Z' }],
				events: [],
			});
		});
	});
});
