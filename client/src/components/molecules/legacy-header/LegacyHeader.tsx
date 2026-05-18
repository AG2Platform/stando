import AvatarSvgDefault from '@/components/atoms/avatar-svg-default';
import VoiceStatusPill from '@/components/atoms/voice-status-pill';
import type { VoiceSessionStatus } from '@/lib/voice-session';

/**
 * Header for the legacy conversation page — port of the `<div class="header">`
 * block in src/web-client-html.ts. Renders:
 *   - 60x60 avatar wrap (inline SVG default for now; PNG path is a TODO once
 *     the identity service is wired into React)
 *   - "Sutando" h1 + status pill + Dashboard link
 *   - End Voice / Mute buttons (visible only when live)
 *
 * Avatar-state ring animation is driven by the `s-{state}` class on
 * `.avatar-wrap`, mirrored from the SSE agent-state stream.
 */

export interface LegacyHeaderProps {
	standName: string;
	voiceStatus: VoiceSessionStatus;
	agentState: 'idle' | 'listening' | 'speaking' | 'working' | 'seeing';
	muted: boolean;
	onToggleVoice: () => void;
	onToggleMute: () => void;
	dashboardUrl: string;
	/** When the agent-universe dashboard reports avatarGenerated=true,
	 *  use this PNG instead of the inline SVG. Same source the legacy
	 *  `<img id="stand-avatar">` pointed at. */
	avatarPngUrl?: string;
}

export default function LegacyHeader({
	standName,
	voiceStatus,
	agentState,
	muted,
	onToggleVoice,
	onToggleMute,
	dashboardUrl,
	avatarPngUrl,
}: LegacyHeaderProps) {
	const isLive = voiceStatus === 'live';
	return (
		<div className="header">
			<div className={`avatar-wrap s-${agentState}`} id="avatar-wrap">
				{avatarPngUrl ? (
					<img className="avatar" id="stand-avatar" src={avatarPngUrl} alt={standName} />
				) : (
					<div className="avatar-svg-wrap">
						<AvatarSvgDefault />
					</div>
				)}
			</div>
			<div className="info">
				<h1 id="stand-name">{standName}</h1>
				<div className="meta">
					<VoiceStatusPill status={voiceStatus} />
					<a href={dashboardUrl} target="_blank" rel="noreferrer">Dashboard</a>
				</div>
			</div>
			<div className="controls">
				{isLive ? (
					<>
						<button className="btn-voice active" onClick={onToggleVoice} type="button">
							End Voice
						</button>
						<button
							className={`btn-mute ${muted ? 'muted' : ''}`}
							onClick={onToggleMute}
							type="button"
						>
							{muted ? 'Unmute' : 'Mute'}
						</button>
					</>
				) : null}
			</div>
		</div>
	);
}
