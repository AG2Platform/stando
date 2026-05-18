/**
 * Extract a list of decision options from an assistant result string.
 *
 * Ported from src/web-client-html.ts parseDecisionOptions. Two patterns
 * are recognised, in priority order:
 *
 *   1. `Say "alpha", "beta", or "gamma".` — short instruction-style
 *      enumerations (max 30 chars per option). Treats `, or ` as a list
 *      separator.
 *
 *   2. `DECISION: alpha / beta / gamma` — explicit decision marker. Each
 *      slash-segment is stripped of bold markers + cut at the first em/en
 *      dash, paren, or period boundary.
 *
 * Returns `null` when the text doesn't look like a decision prompt — the
 * caller falls back to the open-ended reply input.
 */

const RE_SAY = /\bSay\s+([^.\n\r]+?)(?:\s*\.|\s*$)/im;
const RE_DECISION = /DECISION:\s*([^\n\r]+)/i;
const RE_OR_JOIN = /,?\s+or\s+/i;
const RE_ASTERISK = /^\*\*|\*\*$/g;
const RE_SPLIT_TAIL = /\s*[\u2014\u2013(]\s*|\.\s/;
const RE_QUOTES = /^['"\u201C]|['"\u201D.]$/g;
const MAX_OPTION_LEN = 30;

const fromSayPattern = (text: string): readonly string[] | null => {
	const match = text.match(RE_SAY);
	if (!match) return null;
	const flattened = match[1]!.trim().replace(RE_OR_JOIN, ', ');
	const parts = flattened
		.split(',')
		.map((p) => p.trim())
		.filter(Boolean);
	const allShort = parts.every((p) => p.length > 0 && p.length <= MAX_OPTION_LEN);
	return parts.length >= 2 && allShort ? parts : null;
};

const fromDecisionPattern = (text: string): readonly string[] | null => {
	const match = text.match(RE_DECISION);
	if (!match) return null;
	const options = match[1]!
		.split('/')
		.map((segment) => segment.trim().replace(RE_ASTERISK, '').trim())
		.map((segment) => segment.split(RE_SPLIT_TAIL)[0]!.trim())
		.map((segment) => segment.replace(RE_QUOTES, '').trim())
		.filter((segment) => segment.length > 0 && segment.length <= MAX_OPTION_LEN);
	return options.length >= 2 ? options : null;
};

export function parseDecisionOptions(text: string | undefined | null): readonly string[] | null {
	if (!text) return null;
	return fromSayPattern(text) ?? fromDecisionPattern(text);
}
