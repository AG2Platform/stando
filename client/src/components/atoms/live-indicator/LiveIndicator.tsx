import type { CSSProperties } from 'react';
import { APP_COPY } from '@/const-values/app-copy';
import type { VoiceSessionStatus } from '@/lib/voice-session';

/**
 * Pill-style voice-status badge for the top bar. Drops the "Text only" /
 * "Voice active" rebranding into a single component so the badge stays
 * visually consistent with other rounded controls in the chrome.
 */

type StatusKind = 'idle' | 'live' | 'connecting' | 'error';

const KIND_BY_STATUS: Record<VoiceSessionStatus, StatusKind> = {
	idle: 'idle',
	closed: 'idle',
	connecting: 'connecting',
	'requesting-mic': 'connecting',
	live: 'live',
	error: 'error',
};

const LABEL_BY_STATUS: Record<VoiceSessionStatus, string> = {
	idle: APP_COPY.convStatusTextOnly,
	closed: APP_COPY.convStatusTextOnly,
	connecting: APP_COPY.convStatusConnecting,
	'requesting-mic': APP_COPY.convStatusConnecting,
	live: APP_COPY.convStatusVoiceLive,
	error: APP_COPY.convStatusError,
};

/**
 * Brand-monochrome pill: the chrome stays neutral so the indicator
 * doesn't compete with primary CTAs. Only the dot carries the status
 * color (emerald = live, amber = connecting, rose = error) — same idea
 * as a recording light: small, scoped, unmistakable.
 */
const PILL = 'border-(--border) bg-(--surface-elev)/80 text-(--text-muted)';

const DOT_BY_KIND: Record<StatusKind, { cls: string; pulse: string | null }> = {
	idle: { cls: 'bg-(--text-faint)', pulse: null },
	live: { cls: 'bg-emerald-400 animate-live-pulse', pulse: 'rgba(110, 231, 183, 0.55)' },
	connecting: { cls: 'bg-amber-400 animate-live-pulse-fast', pulse: 'rgba(251, 191, 36, 0.55)' },
	error: { cls: 'bg-rose-400', pulse: null },
};

export interface LiveIndicatorProps {
	status: VoiceSessionStatus;
}

export default function LiveIndicator({ status }: LiveIndicatorProps) {
	const kind = KIND_BY_STATUS[status];
	const dot = DOT_BY_KIND[kind];
	return (
		<span
			className={`inline-flex items-center gap-2 rounded-full border px-3 py-1.5 pl-2.5 text-xs font-medium ${PILL}`}
		>
			<span
				className={`h-[7px] w-[7px] rounded-full ${dot.cls}`}
				style={dot.pulse ? ({ ['--pulse-color' as string]: dot.pulse } as CSSProperties) : undefined}
			/>
			<span>{LABEL_BY_STATUS[status]}</span>
		</span>
	);
}
