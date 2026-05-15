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

/**
 * Report mute / voice / agent-state to the conversation server.
 * Mirrors the legacy `fetch('/mute-state?…')` plumbing — the menu-bar
 * app reads from the same endpoint to draw the recording indicator.
 */
export async function postMuteState(patch: {
	muted?: boolean;
	voice?: boolean;
	state?: string;
}): Promise<void> {
	const qs = new URLSearchParams();
	if (patch.muted !== undefined) qs.set('muted', String(patch.muted));
	if (patch.voice !== undefined) qs.set('voice', String(patch.voice));
	if (patch.state !== undefined) qs.set('state', patch.state);
	await fetch(apiUrl(`/mute-state?${qs.toString()}`)).catch(() => {});
}

export interface StandIdentity {
	name?: string;
	nameOrigin?: string;
	avatarGenerated?: boolean;
	avatarUrl?: string;
}

/**
 * Fetch the persistent identity (custom name + generated avatar URL) the
 * `agent-universe` dashboard owns on port 7844. Failure-safe — the legacy
 * `.catch(()=>{})` style was load-bearing because the dashboard server is
 * optional. Returns null when the endpoint is unreachable.
 */
export async function fetchStandIdentity(signal?: AbortSignal): Promise<StandIdentity | null> {
	const host = window.location.hostname || 'localhost';
	const url = `http://${host}:7844/stand-identity`;
	try {
		const res = await fetch(url, { signal });
		if (!res.ok) return null;
		return (await res.json()) as StandIdentity;
	} catch {
		return null;
	}
}
