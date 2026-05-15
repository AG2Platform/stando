import { useCallback, useState } from 'react';
import KeyboardShortcutsBar from '@/components/atoms/keyboard-shortcuts-bar';
import LegacyHeader from '@/components/molecules/legacy-header';
import LegacyHero from '@/components/molecules/legacy-hero';
import LegacyInputBar from '@/components/molecules/legacy-input-bar';
import LegacyTranscript from '@/components/molecules/legacy-transcript';
import DynamicRegion from '@/components/organisms/dynamic-region';
import ToastOverlay from '@/components/organisms/toast-overlay';
import { useAgentStatus } from '@/hooks/useAgentStatus';
import { useTaskPolling } from '@/hooks/useTaskPolling';
import { useTaskToastDriver } from '@/hooks/useTaskToastDriver';
import { useVoiceSession } from '@/hooks/useVoiceSession';

/**
 * Conversation page — port of src/web-client-html.ts. Renders the legacy
 * DOM structure (header / hero / status-bar / dynamic-region / main+bottom-
 * panel) so legacy.css produces a byte-identical look.
 *
 * Layout:
 *   .legacy-shell                            (light-first palette + dark via @media)
 *     .header                                (avatar + name + status pill + buttons)
 *     .hero          (when disconnected)     (big avatar + tagline + Start Voice)
 *     .status-bar                            (keyboard shortcuts)
 *     .dynamic-region                        (sub-tabs + per-tab content)
 *     .main                                  (transcript wrapper)
 *     .bottom-panel  (fixed)                 (text input bar)
 *     .toast-container                       (transient notifications)
 */

type AgentState = 'idle' | 'listening' | 'speaking' | 'working' | 'seeing';

export default function ConversationPage() {
	const { state: voice, connect, disconnect, toggleMute } = useVoiceSession();
	const { status: serverStatus } = useAgentStatus();
	useTaskPolling();
	useTaskToastDriver();

	const standName = 'Sutando';
	const tagline = 'Summon your AI superpower';
	const dashboardUrl = 'http://localhost:7844';
	const isLive = voice.status === 'live';

	// Map server-reported state ("idle" | "listening" | ...) into the
	// agent-state class on .avatar-wrap / .hero. Falls back to local
	// voice status (live=listening, otherwise idle) until SSE delivers
	// the first agent-state event.
	const agentState = deriveAgentState(serverStatus?.state, voice.status);

	const onToggleVoice = useCallback(() => {
		if (isLive) disconnect();
		else connect();
	}, [isLive, connect, disconnect]);

	// Chips fill the text input on click — same behavior as the legacy
	// `trySuggestion` (which set #textInput then triggered Enter).
	const [pendingChip, setPendingChip] = useState<string | null>(null);
	const onPickChip = useCallback((label: string) => {
		setPendingChip(label);
	}, []);

	// Text submit handler — placeholder. Wiring through to the voice WS as
	// a text frame requires a small VoiceSession extension; PR-D will do it.
	const onSubmitText = useCallback((text: string) => {
		console.log('[conversation] text input:', text);
	}, []);

	return (
		<div className={`legacy-shell ${isLive ? 'voice-active' : ''}`}>
			<LegacyHeader
				standName={standName}
				voiceStatus={voice.status}
				agentState={agentState}
				muted={voice.muted}
				onToggleVoice={onToggleVoice}
				onToggleMute={toggleMute}
				dashboardUrl={dashboardUrl}
			/>

			{!isLive ? (
				<LegacyHero
					standName={standName}
					tagline={tagline}
					agentState={agentState}
					voiceStatus={voice.status}
					onStartVoice={connect}
				/>
			) : null}

			<KeyboardShortcutsBar />

			<DynamicRegion connected={isLive} onPickChip={onPickChip} />

			<div className="main">
				{voice.errorMessage ? <div className="t-entry t-system">{voice.errorMessage}</div> : null}
			</div>

			<div className="bottom-panel">
				<LegacyTranscript />
				<LegacyInputBar
					onSubmit={onSubmitText}
					placeholder="Type a message…"
					initialValue={pendingChip}
					onConsumeInitial={() => setPendingChip(null)}
				/>
			</div>

			<ToastOverlay />
		</div>
	);
}

function deriveAgentState(
	server: string | undefined,
	voiceStatus: 'idle' | 'connecting' | 'requesting-mic' | 'live' | 'error' | 'closed'
): AgentState {
	const valid: AgentState[] = ['idle', 'listening', 'speaking', 'working', 'seeing'];
	if (server && valid.includes(server as AgentState)) return server as AgentState;
	if (voiceStatus === 'live') return 'listening';
	return 'idle';
}
