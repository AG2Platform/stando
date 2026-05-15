/**
 * Thin fetch wrappers around the Python agent API on port 7843. The agent
 * API runs in a separate process from web-server.ts (different lifetime,
 * different language) so this client lives in lib/ — components/hooks never
 * call fetch directly.
 */

import type { ApiTasksResponse } from '@/types/task';

export async function fetchActiveTasks(agentApiOrigin: string, signal?: AbortSignal): Promise<ApiTasksResponse> {
	const url = `${agentApiOrigin.replace(/\/$/, '')}/tasks/active`;
	const response = await fetch(url, { signal });
	if (!response.ok) {
		throw new Error(`fetchActiveTasks ${response.status}`);
	}
	return (await response.json()) as ApiTasksResponse;
}
