/**
 * Activity tab content for the dynamic region. Ports the legacy
 * `tab === 'activity'` branch of renderTabContent() — fetch /activity from
 * the Python agent API (port 7843) and render two row types:
 *   - commit: short hash + first line of the commit message
 *   - task:   first line of a recently-processed task result
 *
 * No polling — the legacy fetched once on tab open and so do we. The
 * dynamic-region's tab switcher remounts this component, so re-opening
 * the tab refreshes naturally.
 */

import { useEffect, useState } from 'react';
import { resolveConfig } from '@/lib/config';
import { fetchActivity, type ActivityItem } from '@/lib/tasks-api';

export default function ActivityPanel() {
	const [items, setItems] = useState<ActivityItem[] | null>(null);
	const [error, setError] = useState<string | null>(null);

	useEffect(() => {
		const controller = new AbortController();
		void (async () => {
			try {
				const { agentApiOrigin } = resolveConfig();
				const next = await fetchActivity(agentApiOrigin, controller.signal);
				setItems(next);
			} catch (err) {
				if (!controller.signal.aborted) setError((err as Error).message);
			}
		})();
		return () => controller.abort();
	}, []);

	if (error) {
		return (
			<div style={{ color: '#666', fontSize: 13, textAlign: 'center', padding: 12 }}>
				Couldn't load activity ({error}).
			</div>
		);
	}

	if (!items) {
		return (
			<div style={{ color: '#666', fontSize: 13, textAlign: 'center', padding: 12 }}>Loading…</div>
		);
	}

	if (items.length === 0) {
		return (
			<div style={{ color: '#666', fontSize: 16, textAlign: 'center', padding: 12 }}>
				No recent activity
			</div>
		);
	}

	return (
		<div>
			{items.map((item, idx) => {
				if (item.type === 'commit') {
					return (
						<div key={`c-${item.hash}-${idx}`} style={{ padding: '6px 0', fontSize: 16, lineHeight: 1.5 }}>
							<span style={{ color: '#888', fontFamily: 'monospace', fontSize: 14 }}>{item.hash}</span>{' '}
							<span style={{ color: '#7c83ff' }}>{item.message}</span>
						</div>
					);
				}
				return (
					<div
						key={`t-${item.id}-${idx}`}
						style={{ padding: '6px 0', fontSize: 16, lineHeight: 1.5, color: '#4ecca3' }}
					>
						{item.preview}
					</div>
				);
			})}
		</div>
	);
}
