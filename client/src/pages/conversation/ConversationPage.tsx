import { useCallback, useState } from 'react';
import KeyboardShortcutsBar from '@/components/atoms/keyboard-shortcuts-bar';
import LegacyHeader from '@/components/molecules/legacy-header';
import LegacyHero from '@/components/molecules/legacy-hero';
import LegacyInputBar from '@/components/molecules/legacy-input-bar';
import LegacyTranscript from '@/components/molecules/legacy-transcript';
import DynamicRegion from '@/components/organisms/dynamic-region';
import ToastOverlay from '@/components/organisms/toast-overlay';
import { useAgentSse } from '@/hooks/useAgentSse';
import { useMuteStateSync } from '@/hooks/useMuteStateSync';
import { useStandIdentity } from '@/hooks/useStandIdentity';
import { useTaskPolling } from '@/hooks/useTaskPolling';
import { useTaskToastDriver } from '@/hooks/useTaskToastDriver';
import { useTextSubmit } from '@/hooks/useTextSubmit';
import { useVoiceAutoReconnect } from '@/hooks/useVoiceAutoReconnect';
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
	const { state: voice, connect, disconnect, toggleMute, getSession } = useVoiceSession();
	const submitText = useTextSubmit(getSession);
	const identity = useStandIdentity();
	useTaskPolling();
	useTaskToastDriver();
	useMuteStateSync({ voiceStatus: voice.status, muted: voice.muted });
	useVoiceAutoReconnect({ voiceStatus: voice.status, connect });

	const dashboardOrigin = 'http://localhost:7844';
	const dashboardUrl = dashboardOrigin;
	const avatarPngUrl = identity?.avatarGenerated ? `${dashboardOrigin}/avatar` : undefined;
	const standName = identity?.name ? `Sutando — ${identity.name}` : 'Sutando';
	const tagline =
		identity?.nameOrigin?.split(' — ')[1] ??
		identity?.nameOrigin ??
		'Summon your AI superpower';
	const hasCustomIdentity = !!(identity?.name || identity?.avatarGenerated);
	const isLive = voice.status === 'live';

	const onToggleVoice = useCallback(() => {
		if (isLive) disconnect();
		else connect();
	}, [isLive, connect, disconnect]);

	// Listen to the server-pushed /sse stream. Hotkey toggles fire
	// onToggleVoice / toggleMute; agent-state pushes drive the avatar ring
	// color via .s-{state} classes.
	const { agentState: pushedState } = useAgentSse({
		onToggleVoice,
		onToggleMute: toggleMute,
	});
	const agentState: AgentState =
		pushedState !== 'idle' || isLive ? pushedState : 'idle';

	// Chips fill the text input on click — same behavior as the legacy
	// `trySuggestion` (which set #textInput then triggered Enter).
	const [pendingChip, setPendingChip] = useState<string | null>(null);
	const onPickChip = useCallback((label: string) => {
		setPendingChip(label);
	}, []);

	const onSubmitText = submitText;

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
				avatarPngUrl={avatarPngUrl}
			/>

			{!isLive ? (
				<LegacyHero
					standName={standName}
					tagline={tagline}
					agentState={agentState}
					voiceStatus={voice.status}
					onStartVoice={connect}
					avatarPngUrl={avatarPngUrl}
					hasCustomIdentity={hasCustomIdentity}
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

