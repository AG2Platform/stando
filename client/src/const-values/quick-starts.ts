/**
 * Quick-start suggestions for the conversation hero. Each card is a single
 * action the user can fire by clicking — the label gets dropped into the
 * composer (the legacy "starter chip" behavior). Icons are plain emoji so
 * they render without a font dependency on both light and dark themes.
 *
 * Per CLAUDE.md § Frontend Conventions: no hardcoded copy in components,
 * so the previous getSuggestionChips() inlined list lives here.
 */

export type QuickStartSlot = 'morning' | 'day' | 'evening' | 'always' | 'live' | 'idle';

export interface QuickStart {
	id: string;
	icon: string;
	title: string;
	subtitle: string;
	/** What gets sent to the agent when the card is clicked. */
	prompt: string;
	slot: QuickStartSlot;
}

export const QUICK_STARTS: readonly QuickStart[] = [
	{
		id: 'briefing',
		icon: '☀️',
		title: 'Morning briefing',
		subtitle: 'Calendar, email, what matters today',
		prompt: 'Morning briefing',
		slot: 'morning',
	},
	{
		id: 'calendar',
		icon: '📅',
		title: 'Today’s calendar',
		subtitle: 'What’s coming up next',
		prompt: 'What is on my calendar today?',
		slot: 'day',
	},
	{
		id: 'email',
		icon: '✉️',
		title: 'Triage email',
		subtitle: 'Urgent threads + draft replies',
		prompt: 'Check my email',
		slot: 'always',
	},
	{
		id: 'screen',
		icon: '👀',
		title: 'Read my screen',
		subtitle: 'Explain what I’m looking at',
		prompt: 'What is on my screen?',
		slot: 'always',
	},
	{
		id: 'summon',
		icon: '🎥',
		title: 'Summon',
		subtitle: 'Share screen on Zoom',
		prompt: 'Summon — share screen on Zoom',
		slot: 'always',
	},
	{
		id: 'meeting',
		icon: '📞',
		title: 'Join my next meeting',
		subtitle: 'Hop into Zoom or Google Meet',
		prompt: 'Join my next meeting',
		slot: 'always',
	},
	{
		id: 'note',
		icon: '📝',
		title: 'Take a note',
		subtitle: 'Save an idea to your second brain',
		prompt: 'Take a note',
		slot: 'always',
	},
	{
		id: 'recap',
		icon: '🌙',
		title: 'Recap today',
		subtitle: 'What did I accomplish?',
		prompt: 'What did I accomplish today?',
		slot: 'evening',
	},
	{
		id: 'bye',
		icon: '👋',
		title: 'Disconnect voice',
		subtitle: 'Drop the voice session',
		prompt: 'Bye',
		slot: 'live',
	},
	{
		id: 'tutorial',
		icon: '✨',
		title: 'Tutorial',
		subtitle: 'Walk me through what you can do',
		prompt: 'Tutorial',
		slot: 'idle',
	},
];

const MAX_CARDS = 6;

/**
 * Pick the quick starts to show given the time of day + voice state.
 * Mirrors the legacy getSuggestionChips heuristics but returns rich card
 * defs instead of plain labels.
 */
export const pickQuickStarts = (hour: number, isLive: boolean): readonly QuickStart[] => {
	const slotFilter = (q: QuickStart): boolean => {
		if (q.slot === 'always') return true;
		if (q.slot === 'morning') return hour < 12;
		if (q.slot === 'day') return hour >= 12;
		if (q.slot === 'evening') return hour >= 17;
		if (q.slot === 'live') return isLive;
		if (q.slot === 'idle') return !isLive;
		return false;
	};
	return QUICK_STARTS.filter(slotFilter).slice(0, MAX_CARDS);
};
