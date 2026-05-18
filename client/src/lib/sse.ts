/**
 * Minimal EventSource subscription helper. Wraps the browser API so
 * hooks can call it without re-implementing reconnection or message-
 * parsing boilerplate. Components never instantiate EventSource directly.
 */

import { resolveConfig } from './config';

export type SseEventName = 'agent-state' | 'toggle-voice' | 'toggle-mute' | 'message';

export interface SseSubscription {
	close: () => void;
}

export function subscribeSse(
	handlers: Partial<Record<SseEventName, (data: unknown) => void>>
): SseSubscription {
	const { apiOrigin } = resolveConfig();
	const src = new EventSource(`${apiOrigin}/sse`);

	const wrap = (name: SseEventName) => (event: MessageEvent) => {
		const fn = handlers[name];
		if (!fn) return;
		try {
			fn(JSON.parse(event.data));
		} catch {
			fn(event.data);
		}
	};

	(['agent-state', 'toggle-voice', 'toggle-mute', 'message'] as const).forEach((name) => {
		if (handlers[name]) src.addEventListener(name, wrap(name));
	});

	return {
		close: () => src.close(),
	};
}
