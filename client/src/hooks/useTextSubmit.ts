/**
 * Submit a typed message from the conversation input bar. Mirrors the
 * legacy `sendText()` contract:
 *   1. If the voice WebSocket is open, send a `{type:'text_input', text}`
 *      frame and let the voice agent handle the rest.
 *   2. Otherwise route through the Python task bridge — `POST /task` with
 *      `from: 'web'`, then poll `/result/<id>` and append the reply as an
 *      assistant entry in the transcript.
 *
 * Both paths optimistically append the user-typed text to the local
 * transcript so the conversation feels instant.
 */

import { useCallback, useEffect, useRef } from 'react';
import { resolveConfig } from '@/lib/config';
import { conversationStore } from '@/lib/conversation-store';
import { fetchTaskResult, postWebTask } from '@/lib/tasks-api';
import type { VoiceSession } from '@/lib/voice-session';

const POLL_INTERVAL_MS = 2000;
const MAX_POLL_ATTEMPTS = 60; // 2 minutes worst case

export function useTextSubmit(getSession: () => VoiceSession | null): (text: string) => void {
	const inFlightTimers = useRef<Set<number>>(new Set());

	useEffect(() => {
		const timers = inFlightTimers.current;
		return () => {
			timers.forEach((id) => window.clearInterval(id));
			timers.clear();
		};
	}, []);

	return useCallback(
		(text: string) => {
			const trimmed = text.trim();
			if (!trimmed) return;

			// Optimistic local append — matches legacy `sendText()` behavior.
			conversationStore.appendUserText(trimmed);

			const session = getSession();
			if (session?.sendText(trimmed)) return;

			// WebSocket isn't open — fall back to the Python task bridge.
			const { agentApiOrigin } = resolveConfig();
			void (async () => {
				const result = await postWebTask(agentApiOrigin, trimmed);
				if (!result.ok || !result.task_id) {
					conversationStore.appendSystem(
						`Failed to send: ${result.error ?? 'unknown error'}. Is the agent bridge running?`
					);
					return;
				}
				const taskId = result.task_id;
				let attempts = 0;
				const timer = window.setInterval(async () => {
					attempts += 1;
					try {
						const poll = await fetchTaskResult(agentApiOrigin, taskId);
						if (poll.status === 'completed' && poll.result) {
							window.clearInterval(timer);
							inFlightTimers.current.delete(timer);
							conversationStore.appendAssistantText(poll.result);
						}
					} catch {
						/* tolerate transient errors; keep polling */
					}
					if (attempts >= MAX_POLL_ATTEMPTS) {
						window.clearInterval(timer);
						inFlightTimers.current.delete(timer);
					}
				}, POLL_INTERVAL_MS);
				inFlightTimers.current.add(timer);
			})();
		},
		[getSession]
	);
}
