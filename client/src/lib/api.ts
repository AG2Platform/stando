/**
 * Typed fetch wrappers for the Sutando conversation HTTP API
 * (src/web-server.ts). One module so every page hits the API through
 * the same code path — components never call `fetch` directly per
 * CLAUDE.md § Frontend Conventions ("no fetch calls in components").
 */

import { resolveConfig } from './config';

export type AgentState = 'idle' | 'listening' | 'speaking' | 'working' | 'seeing';

export interface AgentStatus {
	muted: boolean;
	voiceConnected: boolean;
	state: AgentState;
	label?: string;
	clients: number;
}

const apiUrl = (path: string): string => {
	const { apiOrigin } = resolveConfig();
	return `${apiOrigin}${path}`;
};

export async function fetchAgentStatus(signal?: AbortSignal): Promise<AgentStatus> {
	const res = await fetch(apiUrl('/sse-status'), { signal });
	if (!res.ok) throw new Error(`/sse-status returned ${res.status}`);
	return (await res.json()) as AgentStatus;
}

export async function fetchVoiceMode(signal?: AbortSignal): Promise<{ mode: 'active' | 'meeting' }> {
	const res = await fetch(apiUrl('/voice-mode'), { signal });
	if (!res.ok) throw new Error(`/voice-mode returned ${res.status}`);
	return (await res.json()) as { mode: 'active' | 'meeting' };
}
