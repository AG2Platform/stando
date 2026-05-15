import AvatarSvgDefault from '@/components/atoms/avatar-svg-default';
import type { VoiceSessionStatus } from '@/lib/voice-session';

/**
 * The "summon your AI superpower" hero connect screen. Visible only when
 * voice is disconnected — the legacy CSS rule `.legacy-shell.voice-active
 * .hero { display:none }` is mirrored on the ConversationPage root.
 */

export interface LegacyHeroProps {
	standName: string;
	tagline: string;
	agentState: 'idle' | 'listening' | 'speaking' | 'working' | 'seeing';
	voiceStatus: VoiceSessionStatus;
	onStartVoice: () => void;
}

export default function LegacyHero({
	standName,
	tagline,
	agentState,
	voiceStatus,
	onStartVoice,
}: LegacyHeroProps) {
	const isConnecting = voiceStatus === 'connecting' || voiceStatus === 'requesting-mic';
	const label = isConnecting ? 'Connecting…' : 'Start Voice';
	return (
		<div className={`hero s-${agentState}`}>
			<div className="hero-svg-wrap">
				<AvatarSvgDefault />
			</div>
			<h2>{standName}</h2>
			<p className="tagline">{tagline}</p>
			<button className="btn-hero" type="button" onClick={onStartVoice} disabled={isConnecting}>
				{label}
			</button>
		</div>
	);
}
