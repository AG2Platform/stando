import PrimaryVoiceButton from '@/components/atoms/primary-voice-button';
import VoiceOrb, { type VoiceOrbState } from '@/components/atoms/voice-orb';
import { APP_COPY } from '@/const-values/app-copy';
import type { VoiceSessionStatus } from '@/lib/voice-session';

/**
 * Idle hero block: animated orb + greeting + tagline + primary voice
 * call-to-action. Shown when no voice session is live. The greeting
 * strips the "Sutando — " prefix when the user has a custom identity
 * so the heading reads as the stand's chosen name on its own line.
 */

export interface ConversationHeroProps {
	standName: string;
	tagline: string;
	voiceStatus: VoiceSessionStatus;
	agentState: VoiceOrbState;
	avatarPngUrl?: string;
	onStartVoice: () => void;
}

export default function ConversationHero({
	standName,
	tagline,
	voiceStatus,
	agentState,
	avatarPngUrl,
	onStartVoice,
}: ConversationHeroProps) {
	const heading = standName.startsWith('Sutando — ')
		? standName.replace('Sutando — ', '')
		: APP_COPY.convGreeting;
	const sub = tagline || APP_COPY.convTagline;
	return (
		<section className="flex flex-col items-center px-4 pb-2 pt-10 text-center">
			<VoiceOrb agentState={agentState} avatarPngUrl={avatarPngUrl} alt={standName} />
			<h1 className="m-0 mb-2 text-[30px] font-semibold tracking-[-0.02em] text-(--text)">
				{heading}
			</h1>
			<p className="mx-auto mb-6 max-w-[440px] text-[15px] leading-relaxed text-(--text-muted)">
				{sub}
			</p>
			<PrimaryVoiceButton status={voiceStatus} onStart={onStartVoice} />
		</section>
	);
}
