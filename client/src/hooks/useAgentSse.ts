/**
 * SSE bridge to /sse on the conversation server. Ports the legacy
 * `initRemoteToggle()` / `agent-state` handlers from web-client-html.ts.
 *
 * Three events:
 *   - `toggle-voice` — global ⌃V hotkey wants the page to start/stop voice.
 *   - `toggle-mute`  — global ⌃M hotkey wants the page to flip mute.
 *   - `agent-state`  — server-derived 'idle' | 'listening' | 'speaking' |
 *                      'working' | 'seeing'. Drives the avatar ring color.
 *
 * Chrome throttles background tabs after ~5min and kills SSE event
 * processing; we reconnect on visibility change to recover. On network
 * errors we reconnect after a 5s back-off, same as the legacy.
 */

import { useEffect, useState } from 'react';
import { resolveConfig } from '@/lib/config';

export type AgentSseState = 'idle' | 'listening' | 'speaking' | 'working' | 'seeing';

const VALID_STATES: readonly AgentSseState[] = ['idle', 'listening', 'speaking', 'working', 'seeing'];
const RECONNECT_DELAY_MS = 5000;

const normalizeState = (raw: string): AgentSseState => {
	const trimmed = raw.trim();
	return (VALID_STATES as readonly string[]).includes(trimmed) ? (trimmed as AgentSseState) : 'idle';
};

export interface UseAgentSseOptions {
	onToggleVoice: () => void;
	onToggleMute: () => void;
}

export interface UseAgentSseResult {
	agentState: AgentSseState;
}

export function useAgentSse({ onToggleVoice, onToggleMute }: UseAgentSseOptions): UseAgentSseResult {
	const [agentState, setAgentState] = useState<AgentSseState>('idle');

	useEffect(() => {
		const { apiOrigin } = resolveConfig();
		const url = `${apiOrigin}/sse`;
		let source: EventSource | null = null;
		let reconnectTimer: number | null = null;
		let disposed = false;

		const open = () => {
			if (disposed) return;
			try {
				source?.close();
			} catch {
				/* already closed */
			}
			source = new EventSource(url);
			source.addEventListener('toggle-voice', () => onToggleVoice());
			source.addEventListener('toggle-mute', () => onToggleMute());
			source.addEventListener('agent-state', (ev) => {
				const data = (ev as MessageEvent).data;
				setAgentState(normalizeState(typeof data === 'string' ? data : ''));
			});
			source.onerror = () => {
				if (disposed) return;
				if (reconnectTimer != null) return;
				reconnectTimer = window.setTimeout(() => {
					reconnectTimer = null;
					open();
				}, RECONNECT_DELAY_MS);
			};
		};

		const onVisibility = () => {
			if (document.visibilityState === 'visible') open();
		};

		open();
		document.addEventListener('visibilitychange', onVisibility);

		return () => {
			disposed = true;
			document.removeEventListener('visibilitychange', onVisibility);
			if (reconnectTimer != null) window.clearTimeout(reconnectTimer);
			try {
				source?.close();
			} catch {
				/* noop */
			}
		};
	}, [onToggleVoice, onToggleMute]);

	return { agentState };
}
