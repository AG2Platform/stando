/**
 * One "⌃C drop context" hint pill. Replaces the original status-bar
 * <span><kbd>+text+<sep>|</sep></span> trio with a single self-contained
 * atom so the hints row can render via .map() in one component.
 */

export interface KbdHintProps {
	keys: string;
	label: string;
}

export default function KbdHint({ keys, label }: KbdHintProps) {
	return (
		<span className="inline-flex items-center gap-1.5 rounded-full border border-(--border) bg-(--surface-elev)/70 px-2.5 py-1 text-xs text-(--text-muted)">
			<kbd className="rounded border border-(--border) bg-(--surface) px-1.5 py-px font-mono text-[11px] text-(--text)">
				{keys}
			</kbd>
			<span>{label}</span>
		</span>
	);
}
