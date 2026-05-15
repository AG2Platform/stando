/**
 * Live snapshot of `/sse-status` — polls every 3s. Stays as a one-shot
 * fetch + interval for now because the legacy HTML at GET / already runs
 * exactly the same poll cadence; matching it keeps server load identical
 * during the PR-B ↔ PR-C transition. Future work: switch to /sse stream.
 */

import { useEffect, useState } from 'react';
import { fetchAgentStatus, type AgentStatus } from '@/lib/api';

const POLL_INTERVAL_MS = 3000;

export interface UseAgentStatusResult {
	status: AgentStatus | null;
	error: Error | null;
}

export function useAgentStatus(): UseAgentStatusResult {
	const [status, setStatus] = useState<AgentStatus | null>(null);
	const [error, setError] = useState<Error | null>(null);

	useEffect(() => {
		const controller = new AbortController();
		let cancelled = false;

		const tick = async () => {
			try {
				const next = await fetchAgentStatus(controller.signal);
				if (!cancelled) setStatus(next);
			} catch (err) {
				if (cancelled || controller.signal.aborted) return;
				setError(err instanceof Error ? err : new Error(String(err)));
			}
		};

		void tick();
		const id = window.setInterval(() => void tick(), POLL_INTERVAL_MS);

		return () => {
			cancelled = true;
			controller.abort();
			window.clearInterval(id);
		};
	}, []);

	return { status, error };
}
