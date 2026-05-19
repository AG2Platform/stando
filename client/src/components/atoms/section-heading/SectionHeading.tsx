/**
 * Small uppercase section label + rule used between major chunks of the
 * conversation page (between hero and quick-start grid, between stream
 * and panels, etc.).
 */

export interface SectionHeadingProps {
	label: string;
}

export default function SectionHeading({ label }: SectionHeadingProps) {
	return (
		<div className="flex items-baseline gap-2.5 px-1">
			<h2 className="m-0 text-[13px] font-semibold uppercase tracking-[0.08em] text-(--text-muted)">
				{label}
			</h2>
			<span aria-hidden className="h-px flex-1 bg-(--border)/80" />
		</div>
	);
}
