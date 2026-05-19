import type { QuickStart } from '@/const-values/quick-starts';

/**
 * One quick-start tile rendered inside the hero grid. Replaces the
 * legacy text-only "suggestion chip" — same click behavior (parent drops
 * the prompt into the composer), but with a proper icon + subtitle so
 * the page reads as a real product rather than a flat list of strings.
 */

export interface QuickStartCardProps {
	quickStart: QuickStart;
	onPick: (prompt: string) => void;
}

export default function QuickStartCard({ quickStart, onPick }: QuickStartCardProps) {
	return (
		<button
			type="button"
			onClick={() => onPick(quickStart.prompt)}
			title={`${quickStart.title} — ${quickStart.subtitle}`}
			className="group flex items-start gap-3.5 rounded-2xl border border-(--border)/80 bg-(--surface)/75 p-4 text-left transition-[transform,border-color,background] duration-150 ease-out hover:-translate-y-px hover:border-(--text)/30 hover:bg-(--surface)"
		>
			<span
				aria-hidden
				className="inline-flex h-9 w-9 shrink-0 items-center justify-center rounded-[10px] border border-(--border) bg-(--surface-elev)/80 text-lg"
			>
				{quickStart.icon}
			</span>
			<span className="flex min-w-0 flex-col gap-0.5">
				<span className="text-sm font-semibold tracking-[-0.01em] text-(--text)">
					{quickStart.title}
				</span>
				<span className="text-xs leading-snug text-(--text-muted)">
					{quickStart.subtitle}
				</span>
			</span>
		</button>
	);
}
