/**
 * Persist voice-connected state across page reloads.
 *
 * The legacy client uses sessionStorage `sutando-voice` as a "was connected
 * before refresh" flag — set on connect, cleared on disconnect, checked on
 * page load to re-arm the WS automatically. Keeps the page-refresh muscle
 * memory working ("just hit Cmd+R, it'll come back").
 */

import { useEffect, useRef } from 'react';
import type { VoiceSessionStatus } from '@/lib/voice-session';

const STORAGE_KEY = 'sutando-voice';
const AUTO_CONNECT_DELAY_MS = 500;

export interface UseVoiceAutoReconnectOptions {
	voiceStatus: VoiceSessionStatus;
	connect: () => void;
}

export function useVoiceAutoReconnect({ voiceStatus, connect }: UseVoiceAutoReconnectOptions): void {
	const armedRef = useRef(false);

	useEffect(() => {
		if (armedRef.current) return;
		armedRef.current = true;
		try {
			if (sessionStorage.getItem(STORAGE_KEY)) {
				window.setTimeout(connect, AUTO_CONNECT_DELAY_MS);
			}
		} catch {
			/* sessionStorage can throw in some iframe / private-mode contexts */
		}
	}, [connect]);

	useEffect(() => {
		try {
			if (voiceStatus === 'live') {
				sessionStorage.setItem(STORAGE_KEY, '1');
			} else if (voiceStatus === 'closed' || voiceStatus === 'error') {
				sessionStorage.removeItem(STORAGE_KEY);
			}
		} catch {
			/* noop — same as legacy */
		}
	}, [voiceStatus]);
}
