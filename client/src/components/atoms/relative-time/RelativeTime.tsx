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
		<span className="task-time" title={new Date(ts).toISOString()}>
			{label}
		</span>
	);
}
