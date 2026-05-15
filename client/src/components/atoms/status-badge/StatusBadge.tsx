import type { VoiceSessionStatus } from '@/lib/voice-session';

export interface StatusBadgeProps {
	status: VoiceSessionStatus;
	label: string;
}

const TONE_BY_STATUS: Record<VoiceSessionStatus, string> = {
	idle: 'bg-neutral-800/80 text-[color:var(--color-text-mute)]',
	connecting: 'bg-amber-500/15 text-[color:var(--color-warning)]',
	'requesting-mic': 'bg-amber-500/15 text-[color:var(--color-warning)]',
	live: 'bg-emerald-500/15 text-[color:var(--color-success)]',
	error: 'bg-rose-500/15 text-[color:var(--color-danger)]',
	closed: 'bg-neutral-800/80 text-[color:var(--color-text-mute)]',
};

export default function StatusBadge({ status, label }: StatusBadgeProps) {
	const tone = TONE_BY_STATUS[status];
	const showDot = status === 'live' || status === 'connecting' || status === 'requesting-mic';
	return (
		<span
			className={`inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-medium ${tone}`}
			role="status"
			aria-live="polite"
		>
			{showDot ? (
				<span
					className={`inline-block size-1.5 rounded-full ${
						status === 'live' ? 'bg-[color:var(--color-success)]' : 'bg-[color:var(--color-warning)]'
					} ${status === 'live' ? 'animate-pulse' : ''}`}
				/>
			) : null}
			{label}
		</span>
	);
}
