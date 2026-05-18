/**
 * Mirror the local voice / mute state to the server's /mute-state endpoint.
 * The menu-bar app's recording dot (src/Sutando/main.swift) reads from the
 * same endpoint, so without this bridge the dot would lie when the user
 * toggles mute or disconnects from the React client.
 *
 * Ports the legacy `reportAgentState()` plumbing — fire on transitions plus
 * a 1s heartbeat that re-asserts `voice=true` after a server restart.
 */

import { useEffect, useRef } from 'react';
import { postMuteState } from '@/lib/api';
import type { VoiceSessionStatus } from '@/lib/voice-session';

const HEARTBEAT_MS = 1000;

export interface UseMuteStateSyncOptions {
	voiceStatus: VoiceSessionStatus;
	muted: boolean;
}

export function useMuteStateSync({ voiceStatus, muted }: UseMuteStateSyncOptions): void {
	const lastReportedRef = useRef<{ voice: boolean; muted: boolean } | null>(null);
	const isLive = voiceStatus === 'live';

	// Push immediately on transition so the menu-bar dot updates within
	// one frame of a toggle. The heartbeat below handles re-assertion if
	// the server forgets state (e.g. after a restart).
	useEffect(() => {
		void postMuteState({ voice: isLive, muted });
		lastReportedRef.current = { voice: isLive, muted };
	}, [isLive, muted]);

	// 1Hz heartbeat — re-assert voice=true while connected. Avoids a server-
	// side restart leaving the menu-bar reporting voice=false until the user
	// manually toggles. Skips when disconnected (nothing to assert).
	useEffect(() => {
		if (!isLive) return;
		const id = window.setInterval(() => {
			const last = lastReportedRef.current;
			if (last && last.voice === isLive && last.muted === muted) {
				// Re-assert voice=true on heartbeat so a server restart self-heals;
				// muted stays whatever was last reported.
				void postMuteState({ voice: true });
			}
		}, HEARTBEAT_MS);
		return () => window.clearInterval(id);
	}, [isLive, muted]);
}
