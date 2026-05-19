import { APP_COPY } from '@/const-values/app-copy';
import type { VoiceSessionStatus } from '@/lib/voice-session';

/**
 * Hero call-to-action — "Start voice" in the inverted monochrome
 * treatment shared with every primary control on the page. White-on-dark
 * in dark mode, dark-on-light in light mode, so the CTA reads as the
 * highest-contrast thing on screen without leaning on a colored accent.
 *
 * Disabled while the WebSocket is connecting or the browser is asking
 * for mic permission. Hidden once the session is live (the top bar then
 * owns voice controls).
 */

export interface PrimaryVoiceButtonProps {
	status: VoiceSessionStatus;
	onStart: () => void;
}

export default function PrimaryVoiceButton({ status, onStart }: PrimaryVoiceButtonProps) {
	const isBusy = status === 'connecting' || status === 'requesting-mic';
	const label = isBusy ? APP_COPY.convConnecting : APP_COPY.convStartVoice;
	return (
		<button
			type="button"
			onClick={onStart}
			disabled={isBusy}
			aria-busy={isBusy}
			className="inline-flex items-center gap-2.5 rounded-full border border-(--text)/10 bg-(--text) px-7 py-3.5 text-[15px] font-semibold tracking-[-0.01em] text-(--bg) shadow-[0_18px_40px_-18px_rgba(0,0,0,0.55),inset_0_1px_0_rgba(255,255,255,0.18)] transition-[transform,filter,box-shadow] duration-150 ease-out hover:-translate-y-px hover:brightness-95 disabled:translate-y-0 disabled:cursor-progress disabled:opacity-70"
		>
			<span
				aria-hidden
				className="inline-flex h-[22px] w-[22px] items-center justify-center rounded-full bg-(--bg)/15 text-(--bg)"
			>
				▶
			</span>
			{label}
		</button>
	);
}
