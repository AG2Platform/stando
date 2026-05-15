/**
 * Compact "Ns ago" / "Nm ago" / "Nh ago" / "Nd ago" formatter. Pure so it's
 * deterministic in tests (callers pass `now`).
 */

const SECOND_MS = 1000;
const MINUTE_MS = 60 * SECOND_MS;
const HOUR_MS = 60 * MINUTE_MS;
const DAY_MS = 24 * HOUR_MS;

export function formatRelativeAgo(ts: number, now: number): string {
	const delta = Math.max(0, now - ts);
	if (delta < MINUTE_MS) return `${Math.round(delta / SECOND_MS)}s ago`;
	if (delta < HOUR_MS) return `${Math.round(delta / MINUTE_MS)}m ago`;
	if (delta < DAY_MS) return `${Math.round(delta / HOUR_MS)}h ago`;
	return `${Math.round(delta / DAY_MS)}d ago`;
}
