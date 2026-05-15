/**
 * React adapter around VoiceSession (lib/voice-session.ts). Thin —
 * subscribes via useSyncExternalStore so re-renders only fire when state
 * changes, and exposes stable `connect` / `disconnect` / `toggleMute`
 * callbacks. The session instance is created once per mount and torn down
 * on unmount (covers React 18+ StrictMode double-invocation cleanly).
 */

import { useCallback, useEffect, useMemo, useRef, useSyncExternalStore } from 'react';
import { resolveConfig } from '@/lib/config';
import { conversationStore } from '@/lib/conversation-store';
import { VoiceSession, type VoiceSessionState } from '@/lib/voice-session';

const INITIAL_STATE: VoiceSessionState = {
	status: 'idle',
	muted: false,
	errorMessage: null,
	bytesSent: 0,
	bytesRecv: 0,
};

interface Store {
	getState: () => VoiceSessionState;
	subscribe: (l: () => void) => () => void;
}

export interface UseVoiceSessionResult {
	state: VoiceSessionState;
	connect: () => void;
	disconnect: () => void;
	toggleMute: () => void;
}

export function useVoiceSession(): UseVoiceSessionResult {
	const stateRef = useRef<VoiceSessionState>(INITIAL_STATE);
	const listenersRef = useRef<Set<() => void>>(new Set());

	const store = useMemo<Store>(
		() => ({
			getState: () => stateRef.current,
			subscribe: (listener) => {
				listenersRef.current.add(listener);
				return () => listenersRef.current.delete(listener);
			},
		}),
		[]
	);

	const sessionRef = useRef<VoiceSession | null>(null);

	useEffect(() => {
		const session = new VoiceSession({
			onStateChange: (next) => {
				stateRef.current = next;
				listenersRef.current.forEach((l) => l());
			},
			onLog: (msg, level) => {
				const fn = level === 'error' ? console.error : level === 'warn' ? console.warn : console.log;
				fn('[voice-session]', msg);
			},
			onTranscript: (role, text, partial) => conversationStore.handleTranscript(role, text, partial),
			onTurnEnd: () => conversationStore.endTurn(),
			onTurnInterrupted: () => conversationStore.interruptTurn(),
			onSystemMessage: (text) => conversationStore.appendSystem(text),
		});
		sessionRef.current = session;
		return () => {
			session.disconnect();
			sessionRef.current = null;
		};
	}, []);

	const state = useSyncExternalStore(store.subscribe, store.getState, store.getState);

	const connect = useCallback(() => {
		const { wsUrl } = resolveConfig();
		void sessionRef.current?.connect(wsUrl);
	}, []);

	const disconnect = useCallback(() => {
		sessionRef.current?.disconnect();
	}, []);

	const toggleMute = useCallback(() => {
		sessionRef.current?.toggleMute();
	}, []);

	return { state, connect, disconnect, toggleMute };
}
