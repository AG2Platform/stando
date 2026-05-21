import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

// Source-grep regression guard for the connect-race fix in
// `src/voice-agent.ts:startResultWatcher` callback. The upstream PR #924
// fix moves the `isActive` check INSIDE the setTimeout so a voice result
// arriving during the 100-200ms post-client-connect / pre-Gemini-active
// window doesn't drop to the disabled Cartesia branch and get silently
// lost.
//
// voice-agent.ts is tightly coupled to bodhi-realtime-agent + Gemini
// Live + the web client; invoking the result-watcher callback end-to-end
// would need a much larger harness than the value justifies. Source-grep
// catches the specific structural regression (check placement, retry,
// always-on Discord fallback) precisely and cheaply.

const REPO = new URL('..', import.meta.url).pathname.replace(/\/$/, '');
const SRC = readFileSync(join(REPO, 'src/voice-agent.ts'), 'utf-8');

describe('voice-agent — startResultWatcher inject race (PR #924 port)', () => {
	it('does NOT check isActive at callback time before setTimeout', () => {
		// The pre-fix pattern was:
		//   if (session.sessionManager.isActive && isClientConnected(...)) {
		//       setTimeout(() => { injectText(...) }, 1500);
		//   } else if (CARTESIA_API_KEY ...) { ... }
		// The post-fix pattern moves the check INSIDE the setTimeout.
		// Detect the bad pattern by looking for the watcher callback
		// followed (within ~12 lines) by the old gating shape.
		const watcherStart = SRC.indexOf('startResultWatcher((result) =>');
		assert.ok(watcherStart > -1, 'startResultWatcher((result) => not found');
		const window = SRC.slice(watcherStart, watcherStart + 600);
		assert.doesNotMatch(
			window,
			/if\s*\(\s*session\.sessionManager\.isActive[^)]+\)\s*\{[\s\S]{0,200}setTimeout/,
			'pre-fix pattern detected: isActive is gated at callback time. ' +
				'Result delivery in the post-connect / pre-active race window will ' +
				'silently drop. Move the check INSIDE the setTimeout closure.'
		);
	});

	it('uses an inject() closure with a retry', () => {
		// The fix wraps the check + inject in a closure, calls it from a
		// setTimeout, and retries once if the first call returns false.
		assert.match(
			SRC,
			/const\s+inject\s*=\s*\(\s*\)\s*=>\s*\{[\s\S]+?session\.sessionManager\.isActive/,
			'expected `const inject = () => { ... session.sessionManager.isActive ... }` closure'
		);
		// Two nested setTimeouts — first attempt + retry.
		const nestedRetry = /setTimeout\([\s\S]{0,400}if\s*\(inject\(\)\)[\s\S]{0,400}setTimeout\([\s\S]{0,400}if\s*\(inject\(\)\)/;
		assert.match(SRC, nestedRetry, 'expected nested setTimeout retry pattern');
	});

	it('always writes a proactive Discord DM on stuck-voice fallback', () => {
		// After the retry exhausts, the result must be persisted to a
		// proactive-*.txt file so it isn't silently lost. The Cartesia
		// path is a bonus, not a replacement.
		assert.match(
			SRC,
			/proactive-voice-stuck-\$\{[\s\S]+?\}\.txt/,
			'expected `proactive-voice-stuck-${ts}.txt` filename for the ' +
				'Discord DM fallback after stuck-voice. Cartesia alone is ' +
				'insufficient — a stuck-voice user is on the voice surface, ' +
				'not necessarily watching the web UI.'
		);
	});

	it('Cartesia path is preserved as a bonus, not the primary fallback', () => {
		// Cartesia generateSpeech is still called when configured, but it
		// runs AFTER the proactive-*.txt write. Pin that we didn't lose
		// the Cartesia path in the refactor.
		assert.match(
			SRC,
			/generateSpeech\(truncated,\s*\{\s*category:\s*['"]result['"]/,
			'Cartesia generateSpeech call lost — expected it to remain as a ' +
				'bonus playback path when configured'
		);
	});
});
