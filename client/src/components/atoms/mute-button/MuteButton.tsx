export interface MuteButtonProps {
	muted: boolean;
	muteLabel: string;
	unmuteLabel: string;
	onToggle: () => void;
	disabled?: boolean;
}

export default function MuteButton({ muted, muteLabel, unmuteLabel, onToggle, disabled }: MuteButtonProps) {
	return (
		<button
			type="button"
			onClick={onToggle}
			disabled={disabled}
			aria-pressed={muted}
			className="inline-flex items-center justify-center rounded-md border border-neutral-800/80 px-3 py-2 text-sm text-[color:var(--color-text-dim)] transition-colors hover:bg-neutral-800/60 disabled:opacity-50"
		>
			{muted ? unmuteLabel : muteLabel}
		</button>
	);
}
