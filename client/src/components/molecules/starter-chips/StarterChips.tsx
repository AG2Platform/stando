import { useMemo } from 'react';

/**
 * Suggestion chips for the Starter tab. Mirrors getSuggestionChips() in
 * src/web-client-html.ts (time-of-day, basic actions, context-aware
 * suggestions). Capped at 5 to match "show fewer cards, don't shrink them"
 * design rule. Each chip text-truncates at ~32 chars; the full label is
 * available via the title attribute.
 */

interface ChipDef {
	label: string;
	desc?: string;
}

function getSuggestionChips(connected: boolean): ChipDef[] {
	const chips: ChipDef[] = [];
	const hour = new Date().getHours();
	if (hour < 12) chips.push({ label: 'Morning briefing' });
	else chips.push({ label: 'What is on my calendar today?' });
	chips.push({ label: 'Check my email' });
	chips.push({ label: 'What is on my screen?' });
	chips.push({ label: 'Summon', desc: 'share screen on Zoom' });
	chips.push({ label: 'Join my next meeting' });
	chips.push({ label: 'Take a note' });
	chips.push({ label: 'Read my reminders' });
	chips.push({ label: 'Show tasks' });
	chips.push({ label: 'Show notes' });
	if (hour >= 17) chips.push({ label: 'What did I accomplish today?' });
	if (connected) chips.push({ label: 'Bye', desc: 'disconnect voice' });
	else chips.push({ label: 'Tutorial' });
	return chips;
}

function truncate(text: string, max = 32): string {
	return text.length > max ? text.slice(0, max - 1) + '…' : text;
}

export interface StarterChipsProps {
	connected: boolean;
	onPickChip: (label: string) => void;
}

export default function StarterChips({ connected, onPickChip }: StarterChipsProps) {
	const chips = useMemo(() => getSuggestionChips(connected).slice(0, 5), [connected]);
	return (
		<div className="dr-chips">
			<div className="suggestions-label">Try saying or typing</div>
			{chips.map((chip) => {
				const full = chip.desc ? `${chip.label} — ${chip.desc}` : chip.label;
				return (
					<span
						key={full}
						className="suggestion"
						title={full}
						onClick={() => onPickChip(chip.label)}
					>
						{truncate(full)}
					</span>
				);
			})}
		</div>
	);
}
