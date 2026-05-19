import { useCallback, useState } from 'react';
import ConversationComposer from '@/components/molecules/conversation-composer';
import ConversationHero from '@/components/molecules/conversation-hero';
import ConversationTopBar from '@/components/molecules/conversation-top-bar';
import KbdHintsRow from '@/components/molecules/kbd-hints-row';
import QuickStartGrid from '@/components/molecules/quick-start-grid';
import ConversationPanels from '@/components/organisms/conversation-panels';
import ConversationStream from '@/components/organisms/conversation-stream';
import ToastOverlay from '@/components/organisms/toast-overlay';
import { APP_COPY } from '@/const-values/app-copy';
import { useAgentSse } from '@/hooks/useAgentSse';
import { useMuteStateSync } from '@/hooks/useMuteStateSync';
import { useStandIdentity } from '@/hooks/useStandIdentity';
import { useTaskPolling } from '@/hooks/useTaskPolling';
import { useTaskToastDriver } from '@/hooks/useTaskToastDriver';
import { useTextSubmit } from '@/hooks/useTextSubmit';
import { useVoiceAutoReconnect } from '@/hooks/useVoiceAutoReconnect';
import { useVoiceSession } from '@/hooks/useVoiceSession';

/**
 * Conversation page — full redesign.
 *
 * Layout (top to bottom):
 *   .conv-topbar          sticky glass header (brand · live indicator · voice)
 *   .conv-main
 *     .conv-hero          idle only — animated orb + greeting + Start voice
 *     KbdHintsRow         hotkey reminders under the hero
 *     QuickStartGrid      idle only — quick-start cards
 *     .conv-stream-card   live only — chat-bubble transcript
 *     ConversationPanels  always — tabbed Tasks / Notes / Asks / Activity
 *   .conv-composer-wrap   fixed pill composer at the bottom
 *
 * `.legacy-shell` is retained on the root so existing CSS (avatar
 * `s-{state}` animations, panel internals, toasts) keeps working;
 * `.conv-root` overrides its layout/centering.
 */

type AgentState = 'idle' | 'listening' | 'speaking' | 'working' | 'seeing';

const DASHBOARD_ORIGIN = 'http://localhost:7844';

export default function ConversationPage() {
	const { state: voice, connect, disconnect, toggleMute, getSession } = useVoiceSession();
	const submitText = useTextSubmit(getSession);
	const identity = useStandIdentity();
	useTaskPolling();
	useTaskToastDriver();
	useMuteStateSync({ voiceStatus: voice.status, muted: voice.muted });
	useVoiceAutoReconnect({ voiceStatus: voice.status, connect });

	const avatarPngUrl = identity?.avatarGenerated ? `${DASHBOARD_ORIGIN}/avatar` : undefined;
	const standName = identity?.name ? `Sutando — ${identity.name}` : 'Sutando';
	const tagline =
		identity?.nameOrigin?.split(' — ')[1] ?? identity?.nameOrigin ?? APP_COPY.convTagline;
	const isLive = voice.status === 'live';

	const onStartVoice = useCallback(() => connect(), [connect]);
	const onStopVoice = useCallback(() => disconnect(), [disconnect]);
	const onToggleVoice = useCallback(() => {
		if (isLive) disconnect();
		else connect();
	}, [isLive, connect, disconnect]);

	const { agentState: pushedState } = useAgentSse({
		onToggleVoice,
		onToggleMute: toggleMute,
	});
	const agentState: AgentState = pushedState !== 'idle' || isLive ? pushedState : 'idle';

	const [pendingChip, setPendingChip] = useState<string | null>(null);
	const onPickPrompt = useCallback((prompt: string) => setPendingChip(prompt), []);

	return (
		<div className={`legacy-shell conv-root ${isLive ? 'is-live' : ''}`}>
			<ConversationTopBar
				standName={standName}
				voiceStatus={voice.status}
				muted={voice.muted}
				dashboardUrl={DASHBOARD_ORIGIN}
				onStartVoice={onStartVoice}
				onStopVoice={onStopVoice}
				onToggleMute={toggleMute}
			/>

			<main className="mx-auto flex w-full max-w-[920px] flex-col gap-9 px-6 pb-10 pt-8">
				{isLive ? (
					<ConversationStream errorMessage={voice.errorMessage ?? null} />
				) : (
					<>
						<ConversationHero
							standName={standName}
							tagline={tagline}
							voiceStatus={voice.status}
							agentState={agentState}
							avatarPngUrl={avatarPngUrl}
							onStartVoice={onStartVoice}
						/>
						<KbdHintsRow />
						<QuickStartGrid connected={isLive} onPick={onPickPrompt} />
					</>
				)}

				<ConversationPanels />
			</main>

			<ConversationComposer
				onSubmit={submitText}
				initialValue={pendingChip}
				onConsumeInitial={() => setPendingChip(null)}
				isLive={isLive}
				muted={voice.muted}
				onToggleMute={toggleMute}
			/>

			<ToastOverlay />
		</div>
	);
}
