/**
 * Collapse routing prefixes + drop noisy chunks for the task list summary
 * line. Ported from src/web-client-html.ts summarizeTaskText. Pure — no
 * DOM, no state — to make unit testing trivial when we add a runner.
 *
 *   "[Discord @susanliu_] maybe make it look more like this"
 *     → "[Discord] maybe make it look more like this"
 *
 * Keeps the origin channel visible (per the prior product call) while
 * stripping handles, replyTo metadata, and file-attached blobs.
 */

import { SUMMARY_MAX_CHARS } from '@/const-values/task-config';

const PREFIX_RE = /^\[(Discord|Voice|Replying to|Reply|Phone|Sutando-core|Sutando-Lucy|Sutando-Maddy|Task|Context drop)[^\]]*\]\s*/i;
const FILE_ATTACHED_RE = /\[File attached:[^\]]*\]/gi;
const WHITESPACE_RE = /\s+/g;
const BOUNDARY_CUTS = [' (', ' — ', ' - ', ': ', '. ', ', '] as const;
const MAX_PREFIX_PASSES = 4;
const MAX_BOUNDARY_IDX = 90;
const ELLIPSIS = '…';

const SHORT_KIND: Record<string, string> = {
	'replying to': 'Reply',
	reply: 'Reply',
	'sutando-core': 'Sutando-core',
	'sutando-lucy': 'Sutando-Lucy',
	'sutando-maddy': 'Sutando-Maddy',
	'context drop': 'Context drop',
};

const shortenKind = (kind: string): string => {
	const lower = kind.toLowerCase();
	return SHORT_KIND[lower] ?? kind.charAt(0).toUpperCase() + kind.slice(1).toLowerCase();
};

const stripStackedPrefixes = (input: string): string =>
	// Tasks may stack multiple prefixes ("[Reply][Discord @foo]"). Iterate a
	// bounded number of times; reduce keeps the loop declarative and lets the
	// no-change comparison short-circuit semantically.
	Array.from({ length: MAX_PREFIX_PASSES }).reduce<string>((acc) => {
		const next = acc.replace(PREFIX_RE, (_match, kind: string) => `[${shortenKind(kind)}] `);
		return next === acc ? acc : next;
	}, input);

const trimAtSentenceBoundary = (input: string): string => {
	const hit = BOUNDARY_CUTS.map((cut) => ({ cut, idx: input.indexOf(cut) })).find(
		({ idx }) => idx > 0 && idx < MAX_BOUNDARY_IDX
	);
	return hit ? input.slice(0, hit.idx) : input;
};

const enforceMaxLength = (input: string): string =>
	input.length > SUMMARY_MAX_CHARS ? `${input.slice(0, SUMMARY_MAX_CHARS - ELLIPSIS.length)}${ELLIPSIS}` : input;

export function summarizeTaskText(raw: string): string {
	if (!raw) return '';
	const trimmed = raw.trim();
	const dePrefixed = stripStackedPrefixes(trimmed);
	const cleaned = dePrefixed.replace(FILE_ATTACHED_RE, '').replace(WHITESPACE_RE, ' ').trim();
	const bounded = trimAtSentenceBoundary(cleaned);
	return enforceMaxLength(bounded);
}

/** Default-tag bare tasks (no `[Channel]` prefix) as `[Voice]` — the
 *  overwhelming majority of un-prefixed tasks come from the voice agent. */
export const tagVoiceFallback = (raw: string): string => {
	if (!raw) return raw;
	return /^\[/.test(raw) ? raw : `[Voice] ${raw}`;
};
