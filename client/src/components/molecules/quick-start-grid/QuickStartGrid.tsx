import { useMemo } from 'react';
import QuickStartCard from '@/components/atoms/quick-start-card';
import SectionHeading from '@/components/atoms/section-heading';
import { APP_COPY } from '@/const-values/app-copy';
import { pickQuickStarts } from '@/const-values/quick-starts';

/**
 * The "Quick starts" card grid below the hero. Replaces the legacy
 * StarterChips row — same picking logic (time-of-day + voice state) now
 * sourced from const-values/quick-starts so suggestion content stays
 * out of components.
 */

export interface QuickStartGridProps {
	connected: boolean;
	onPick: (prompt: string) => void;
}

export default function QuickStartGrid({ connected, onPick }: QuickStartGridProps) {
	const items = useMemo(() => pickQuickStarts(new Date().getHours(), connected), [connected]);
	if (items.length === 0) return null;
	return (
		<div className="flex flex-col gap-3">
			<SectionHeading label={APP_COPY.convQuickStartsLabel} />
			<div className="grid grid-cols-[repeat(auto-fill,minmax(220px,1fr))] gap-3">
				{items.map((quickStart) => (
					<QuickStartCard key={quickStart.id} quickStart={quickStart} onPick={onPick} />
				))}
			</div>
		</div>
	);
}
