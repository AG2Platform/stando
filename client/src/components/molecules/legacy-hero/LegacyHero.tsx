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
	/** Generated avatar PNG (from agent-universe /avatar). When set we
	 *  swap the inline SVG for the image and trigger the legacy
	 *  `.identity-reveal` fade-in. */
	avatarPngUrl?: string;
	hasCustomIdentity?: boolean;
}

export default function LegacyHero({
	standName,
	tagline,
	agentState,
	voiceStatus,
	onStartVoice,
	avatarPngUrl,
	hasCustomIdentity,
}: LegacyHeroProps) {
	const isConnecting = voiceStatus === 'connecting' || voiceStatus === 'requesting-mic';
	const label = isConnecting ? 'Connecting…' : 'Start Voice';
	const heroClasses = ['hero', `s-${agentState}`];
	if (hasCustomIdentity) heroClasses.push('identity-reveal');
	return (
		<div className={heroClasses.join(' ')} id="hero">
			{avatarPngUrl ? (
				<img className="avatar-hero" id="hero-avatar" src={avatarPngUrl} alt={standName} />
			) : (
				<div className="hero-svg-wrap">
					<AvatarSvgDefault />
				</div>
			)}
			<h2 id="hero-name">{standName}</h2>
			<p className="tagline">{tagline}</p>
			<button className="btn-hero" type="button" onClick={onStartVoice} disabled={isConnecting}>
				{label}
			</button>
		</div>
	);
}
