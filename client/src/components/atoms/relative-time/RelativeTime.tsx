import { formatRelativeAgo } from '@/utils/format-relative-ago';

export interface RelativeTimeProps {
	/** ms since epoch. */
	ts: number;
	/** Optional reference now-ms; defaults to Date.now() when omitted. Pass in
	 *  tests or animation-driven re-renders so the rendered string is stable. */
	now?: number;
}

export default function RelativeTime({ ts, now }: RelativeTimeProps) {
	const label = formatRelativeAgo(ts, now ?? Date.now());
	return (
		<time className="font-mono text-[11px] text-[color:var(--color-text-mute)]" dateTime={new Date(ts).toISOString()}>
			{label}
		</time>
	);
}
