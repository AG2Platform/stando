/**
 * Single segment inside the panel tab strip. The badge slot shows a
 * compact count (e.g. unanswered question count, in-flight task count)
 * and gets an "unseen" color when the tab is not active so the user
 * notices new activity without the layout shifting.
 */

export type PanelTabUnseen = 'tasks' | 'asks' | null;

export interface PanelTabProps {
	id: string;
	label: string;
	count?: number;
	isActive: boolean;
	unseen?: PanelTabUnseen;
	onSelect: (id: string) => void;
}

const TAB_BASE =
	'inline-flex flex-1 items-center justify-center gap-1.5 whitespace-nowrap rounded-[10px] border-0 bg-transparent px-2.5 py-2 text-[13px] font-medium transition-[background,color] duration-150 ease-out';
const TAB_IDLE = 'text-(--text-muted) hover:text-(--text)';
const TAB_ACTIVE = 'bg-(--surface) text-(--text) shadow-[0_6px_14px_-10px_rgba(0,0,0,0.5)]';

const BADGE_BASE = 'min-w-[18px] rounded-full px-1.5 py-px text-[11px] font-semibold';
/**
 * Brand-monochrome badges: the tab label already says what kind of count
 * this is ("Asks · 3", "Tasks · 2"), so the badge itself doesn't need to
 * carry color. Idle counts get a subtle surface tint; unseen counts get
 * the inverted treatment so they read as a notification dot without
 * introducing a new accent color.
 */
const BADGE_DEFAULT = 'bg-(--surface) text-(--text-muted)';
const BADGE_UNSEEN = 'bg-(--text) text-(--bg)';

export default function PanelTab({ id, label, count, isActive, unseen, onSelect }: PanelTabProps) {
	const showUnseen = !isActive && unseen != null;
	const badgeCls = showUnseen ? BADGE_UNSEEN : BADGE_DEFAULT;
	const tabCls = `${TAB_BASE} ${isActive ? TAB_ACTIVE : TAB_IDLE}`;
	return (
		<button type="button" className={tabCls} onClick={() => onSelect(id)} aria-pressed={isActive}>
			<span>{label}</span>
			{count && count > 0 ? <span className={`${BADGE_BASE} ${badgeCls}`}>{count}</span> : null}
		</button>
	);
}
