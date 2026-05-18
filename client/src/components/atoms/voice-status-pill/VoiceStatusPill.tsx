import type { VoiceSessionStatus } from '@/lib/voice-session';

/**
 * The "• Text only" / "• Voice active" pill from the legacy header.
 * Color flips between voice-on (green) and voice-off (gray) based on
 * status — matches `.status-pill.voice-on/.voice-off` in legacy.css.
 */

const LABEL_BY_STATUS: Record<VoiceSessionStatus, string> = {
	idle: 'Text only',
	closed: 'Text only',
	connecting: 'Connecting…',
	'requesting-mic': 'Mic request',
	live: 'Voice active',
	error: 'Voice error',
};

export interface VoiceStatusPillProps {
	status: VoiceSessionStatus;
}

export default function VoiceStatusPill({ status }: VoiceStatusPillProps) {
	const isOn = status === 'live';
	return (
		<span className={`status-pill ${isOn ? 'voice-on' : 'voice-off'}`}>
			<span className="dot" />
			<span>{LABEL_BY_STATUS[status]}</span>
		</span>
	);
}
