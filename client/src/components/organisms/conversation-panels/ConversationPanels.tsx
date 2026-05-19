import { useCallback, useEffect, useState } from 'react';
import ActivityPanel from '@/components/organisms/activity-panel';
import NotesPanel from '@/components/organisms/notes-panel';
import QuestionsPanel from '@/components/organisms/questions-panel';
import TaskList from '@/components/organisms/task-list';
import { APP_COPY } from '@/const-values/app-copy';
import { useTasks } from '@/hooks/useTasks';

/**
 * Conversation panel dock. Renders a thin sticky pill row of section
 * launchers (Tasks / Notes / Asks / Activity) that lives inside the
 * conversation chrome and is always reachable while scrolling. Clicking
 * a pill opens a slide-down drawer beneath the dock; clicking the same
 * pill, the backdrop, or pressing Esc closes it.
 *
 * Previously this was a stacked accordion sitting inside the main
 * content column — which left four mostly empty rows in the page flow.
 * This version keeps the page calm and surfaces the panels as global
 * chrome instead.
 *
 * The `.conv-panel-body` class is preserved on the drawer content so
 * the legacy CSS reset in conversation.css continues to strip inner
 * card chrome from the panel organisms it contains.
 */

type PanelId = 'tasks' | 'notes' | 'questions' | 'activity';
type Unseen = 'tasks' | 'asks' | null;

interface LauncherDef {
	readonly id: PanelId;
	readonly label: string;
	readonly count: number;
	readonly unseen: Unseen;
}

const PILL_BASE =
	'inline-flex items-center gap-1.5 whitespace-nowrap rounded-full px-3 py-1.5 text-xs font-medium transition-[background,border-color,color] duration-150 ease-out border';
const PILL_IDLE =
	'border-(--border)/70 bg-(--surface)/80 text-(--text-muted) hover:border-(--text-faint) hover:text-(--text)';
const PILL_OPEN =
	'border-(--text)/40 bg-(--text) text-(--bg) shadow-[0_6px_18px_-12px_rgba(0,0,0,0.5)]';

const BADGE_BASE = 'min-w-[18px] rounded-full px-1.5 py-px text-center text-[10px] font-semibold';
const BADGE_IDLE_DEFAULT = 'bg-(--surface-elev) text-(--text-muted)';
const BADGE_IDLE_UNSEEN = 'bg-(--text) text-(--bg)';
const BADGE_OPEN = 'bg-(--bg)/20 text-(--bg)';

const renderPanel = (id: PanelId) => {
	if (id === 'tasks') return <TaskList />;
	if (id === 'notes') return <NotesPanel />;
	if (id === 'questions') return <QuestionsPanel />;
	return <ActivityPanel />;
};

export default function ConversationPanels() {
	const [openId, setOpenId] = useState<PanelId | null>(null);
	const { tasks, questions } = useTasks();
	const taskCount = Object.values(tasks).filter((t) => t.status !== 'done').length;
	const questionCount = questions.length;

	const toggle = useCallback(
		(id: PanelId) => setOpenId((cur) => (cur === id ? null : id)),
		[],
	);
	const close = useCallback(() => setOpenId(null), []);

	useEffect(() => {
		if (openId === null) return;
		const onKey = (e: KeyboardEvent) => {
			if (e.key === 'Escape') close();
		};
		window.addEventListener('keydown', onKey);
		return () => window.removeEventListener('keydown', onKey);
	}, [openId, close]);

	const launchers: readonly LauncherDef[] = [
		{
			id: 'tasks',
			label: APP_COPY.convPanelTasks,
			count: taskCount,
			unseen: taskCount > 0 ? 'tasks' : null,
		},
		{ id: 'notes', label: APP_COPY.convPanelNotes, count: 0, unseen: null },
		{
			id: 'questions',
			label: APP_COPY.convPanelQuestions,
			count: questionCount,
			unseen: questionCount > 0 ? 'asks' : null,
		},
		{ id: 'activity', label: APP_COPY.convPanelActivity, count: 0, unseen: null },
	];

	return (
		<div className="relative border-b border-(--border)/70 bg-(--surface)/75 backdrop-blur-[14px] backdrop-saturate-140">
			<div className="mx-auto flex w-full max-w-[920px] items-center justify-center gap-1.5 px-5 py-2">
				{launchers.map((l) => {
					const isOpen = openId === l.id;
					const showUnseen = !isOpen && l.unseen != null;
					const badgeCls = isOpen
						? BADGE_OPEN
						: showUnseen
							? BADGE_IDLE_UNSEEN
							: BADGE_IDLE_DEFAULT;
					return (
						<button
							key={l.id}
							type="button"
							className={`${PILL_BASE} ${isOpen ? PILL_OPEN : PILL_IDLE}`}
							onClick={() => toggle(l.id)}
							aria-expanded={isOpen}
							aria-controls={`panel-${l.id}`}
						>
							<span>{l.label}</span>
							{l.count > 0 ? <span className={`${BADGE_BASE} ${badgeCls}`}>{l.count}</span> : null}
						</button>
					);
				})}
			</div>

			{openId !== null ? (
				<>
					<button
						type="button"
						aria-label={APP_COPY.convPanelDrawerClose}
						onClick={close}
						className="fixed inset-0 z-20 cursor-default bg-transparent"
					/>
					<div
						id={`panel-${openId}`}
						role="region"
						className="absolute left-0 right-0 top-full z-30 border-b border-(--border)/80 bg-(--surface)/95 shadow-[0_18px_40px_-22px_rgba(0,0,0,0.55)] backdrop-blur-[14px] backdrop-saturate-140"
					>
						<div className="conv-panel-body mx-auto w-full max-w-[920px] max-h-[60vh] overflow-y-auto px-6 py-5">
							{renderPanel(openId)}
						</div>
					</div>
				</>
			) : null}
		</div>
	);
}
