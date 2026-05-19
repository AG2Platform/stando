import { useEffect, useState, type KeyboardEvent } from 'react';
import { APP_COPY } from '@/const-values/app-copy';

/**
 * Sticky pill-shaped composer that replaces the legacy bottom panel.
 * Owns the message input + circular send button, with an optional inline
 * mute toggle that appears when voice is live so users can hush the mic
 * without reaching for the top bar.
 *
 * `initialValue` lets a quick-start card pre-fill the input; once
 * consumed the parent clears it via `onConsumeInitial`.
 */

export interface ConversationComposerProps {
	onSubmit: (text: string) => void;
	placeholder?: string;
	disabled?: boolean;
	initialValue?: string | null;
	onConsumeInitial?: () => void;
	isLive?: boolean;
	muted?: boolean;
	onToggleMute?: () => void;
}

const WRAP =
	'pointer-events-none fixed bottom-0 left-0 right-0 z-20 px-4 pb-[18px] pt-3.5 bg-gradient-to-t from-(--bg) from-50% to-(--bg)/70';

const PILL =
	'pointer-events-auto mx-auto flex max-w-[920px] items-center gap-2 rounded-full border border-(--border)/80 bg-(--surface)/90 py-1.5 pl-[18px] pr-1.5 shadow-[0_16px_40px_-16px_rgba(0,0,0,0.55),inset_0_1px_0_rgba(255,255,255,0.04)] backdrop-blur-[10px] transition-[border-color,box-shadow] duration-150 ease-out focus-within:border-(--text)/40 focus-within:shadow-[0_20px_50px_-18px_rgba(0,0,0,0.5),inset_0_1px_0_rgba(255,255,255,0.06)]';

const INPUT =
	'min-w-0 flex-1 border-0 bg-transparent py-2.5 text-[15px] text-(--text) outline-none placeholder:text-(--text-faint)';

const ICON_BTN_BASE =
	'inline-flex h-[38px] w-[38px] items-center justify-center rounded-full p-0 transition-[background,color,border-color,filter,transform,opacity] duration-150 ease-out disabled:cursor-not-allowed disabled:opacity-40';

const MUTE_BTN =
	'border border-(--border) bg-(--surface-elev)/80 text-(--text) hover:bg-(--surface-elev)';
const MUTE_BTN_ON =
	'border border-rose-500/40 bg-rose-500/15 text-rose-200';

const SEND_BTN =
	'border border-(--text)/10 bg-(--text) text-(--bg) text-base font-semibold shadow-[0_8px_20px_-12px_rgba(0,0,0,0.5)] hover:scale-105 hover:brightness-95';

export default function ConversationComposer({
	onSubmit,
	placeholder = APP_COPY.convComposerPlaceholder,
	disabled = false,
	initialValue,
	onConsumeInitial,
	isLive = false,
	muted = false,
	onToggleMute,
}: ConversationComposerProps) {
	const [value, setValue] = useState('');

	useEffect(() => {
		if (initialValue && initialValue.length > 0) {
			setValue(initialValue);
			onConsumeInitial?.();
		}
	}, [initialValue, onConsumeInitial]);

	const submit = () => {
		const trimmed = value.trim();
		if (!trimmed) return;
		onSubmit(trimmed);
		setValue('');
	};

	const onKeyDown = (e: KeyboardEvent<HTMLInputElement>) => {
		if (e.key === 'Enter' && !e.shiftKey) {
			e.preventDefault();
			submit();
		}
	};

	return (
		<div className={WRAP}>
			<div className={PILL}>
				<input
					type="text"
					value={value}
					onChange={(e) => setValue(e.target.value)}
					onKeyDown={onKeyDown}
					placeholder={placeholder}
					disabled={disabled}
					aria-label={placeholder}
					className={INPUT}
				/>
				{isLive && onToggleMute ? (
					<button
						type="button"
						onClick={onToggleMute}
						aria-pressed={muted}
						aria-label={muted ? APP_COPY.convUnmute : APP_COPY.convMute}
						title={muted ? APP_COPY.convUnmute : APP_COPY.convMute}
						className={`${ICON_BTN_BASE} ${muted ? MUTE_BTN_ON : MUTE_BTN}`}
					>
						{muted ? '🔇' : '🎙'}
					</button>
				) : null}
				<button
					type="button"
					onClick={submit}
					disabled={disabled || !value.trim()}
					aria-label={APP_COPY.convComposerSend}
					title={APP_COPY.convComposerSend}
					className={`${ICON_BTN_BASE} ${SEND_BTN}`}
				>
					↑
				</button>
			</div>
		</div>
	);
}
