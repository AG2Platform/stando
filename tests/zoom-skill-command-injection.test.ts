import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

// Security regression guard for `skills/zoom/tools.ts`.
//
// Pre-fix: three call sites used the shape
//   execSync(`open "${zoomUrl}"`)
// where `zoomUrl` interpolated the user-controlled `pwd` field directly:
//   zoomUrl = `zoommtg://zoom.us/join?confno=${cleanId}&pwd=${pwd}`;
//
// `pwd` comes from `passcode ?? getZoomPasscode()` — Gemini tool argument
// or `$ZOOM_PERSONAL_PASSCODE`. A passcode like `"; rm -rf ~/.config; #`
// would break out of the quoted shell argument in execSync (which uses
// `/bin/sh -c`) and execute arbitrary commands.
//
// `cleanId` is digit-only via `.replace(/\D/g, '')` so it's safe. Only
// `pwd` was vulnerable. The fix:
//
//   1. URL-encode `pwd` (defense-in-depth against malformed URLs).
//   2. Use `execFileSync('open', [url])` — argv array, no shell.
//
// This test pins both layers.

const SRC = readFileSync(
	join(import.meta.dirname ?? '.', '..', 'skills/zoom/tools.ts'),
	'utf-8',
);

describe('zoom tools — command-injection guard', () => {
	it('does not use execSync with template-literal `open "${zoomUrl}"`', () => {
		// The pre-fix pattern was `execSync(\`open "${...}"\`)`. Pin
		// it doesn't return. Any future refactor that re-introduces the
		// raw shell-string pattern fails here.
		assert.doesNotMatch(
			SRC,
			/execSync\(`open\s*"\$\{[a-zA-Z]*[uU]rl\}/,
			'skills/zoom/tools.ts contains the raw `execSync(\`open "${...Url}"\`)` pattern again — ' +
				'this splices user-controlled `pwd` into a shell command. Use execFileSync(\'open\', [url]) instead.',
		);
	});

	it('uses execFileSync(\'open\', [...]) for the Zoom URL open call', () => {
		// Positive pin: the safe pattern must appear.
		assert.match(
			SRC,
			/execFileSync\(\s*['"]open['"]\s*,\s*\[/,
			'skills/zoom/tools.ts must use `execFileSync(\'open\', [url])` to invoke `open` — the array form ' +
				'bypasses `/bin/sh -c` so no value spliced into argv is interpreted as shell syntax.',
		);
	});

	it('URL-encodes `pwd` before embedding in the deeplink URL', () => {
		// Defense-in-depth: even though execFileSync alone closes the
		// shell-injection class, URL-encoding the passcode prevents a
		// malformed URL with `&` or `#` in the passcode from confusing
		// `open`'s URL parsing or Zoom's deeplink handler.
		assert.match(
			SRC,
			/encodeURIComponent\(pwd\)/,
			'skills/zoom/tools.ts must URL-encode `pwd` before embedding in the deeplink URL ' +
				'(defense-in-depth: prevents `&` / `#` / non-ASCII in passcodes from confusing the URL).',
		);
	});

	it('all three open-URL sites use the safe pattern (no leftover execSync template-literals)', () => {
		// Architectural assertion: count the unsafe pattern instances.
		// Pre-fix: 3 sites (summon, summon Zoom-running, summon Zoom-not-running).
		// Post-fix: 0.
		const matches = SRC.match(/execSync\(`open\s*"\$\{/g);
		assert.equal(
			matches,
			null,
			`Found ${matches?.length} occurrence(s) of the unsafe shell-template-literal pattern. ` +
				'Every site that opens a user-controlled URL must use execFileSync.',
		);
	});
});
