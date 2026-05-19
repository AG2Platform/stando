import { useState } from 'react';
import PanelTabBar, { type PanelTabDef } from '@/components/molecules/panel-tab-bar';
import ActivityPanel from '@/components/organisms/activity-panel';
import NotesPanel from '@/components/organisms/notes-panel';
import QuestionsPanel from '@/components/organisms/questions-panel';
import TaskList from '@/components/organisms/task-list';
import { APP_COPY } from '@/const-values/app-copy';
import { useTasks } from '@/hooks/useTasks';

/**
 * Tabbed "active work" card sitting under the hero / stream. Reuses the
 * existing panel organisms (TaskList, NotesPanel, QuestionsPanel,
 * ActivityPanel) verbatim — only the chrome (segmented tab bar + card
 * surface) is new.
 *
 * The legacy "Starter" tab is gone: starter prompts live in the hero's
 * quick-start grid in this layout, which is always visible. That keeps
 * this panel focused on dynamic work the agent is actively tracking.
 *
 * `.conv-panel-body` is preserved as a class-name marker so the small
 * legacy reset in conversation.css (strip inner card chrome from the
 * legacy panel CSS) keeps targeting these children.
 */

type PanelId = 'tasks' | 'notes' | 'questions' | 'activity';

const DEFAULT_TAB: PanelId = 'tasks';

export default function ConversationPanels() {
	const [active, setActive] = useState<PanelId>(DEFAULT_TAB);
	const { tasks, questions } = useTasks();
	const taskCount = Object.values(tasks).filter((t) => t.status !== 'done').length;
	const questionCount = questions.length;

	const tabs: readonly PanelTabDef[] = [
		{
			id: 'tasks',
			label: APP_COPY.convPanelTasks,
			count: taskCount,
			unseen: taskCount > 0 ? 'tasks' : null,
		},
		{ id: 'notes', label: APP_COPY.convPanelNotes },
		{
			id: 'questions',
			label: APP_COPY.convPanelQuestions,
			count: questionCount,
			unseen: questionCount > 0 ? 'asks' : null,
		},
		{ id: 'activity', label: APP_COPY.convPanelActivity },
	];

	return (
		<div className="rounded-[20px] border border-(--border)/80 bg-(--surface)/85 p-1.5">
			<PanelTabBar tabs={tabs} activeId={active} onSelect={(id) => setActive(id as PanelId)} />
			<div className="conv-panel-body px-4 pb-1.5 pt-3.5">
				{active === 'tasks' ? <TaskList /> : null}
				{active === 'notes' ? <NotesPanel /> : null}
				{active === 'questions' ? <QuestionsPanel /> : null}
				{active === 'activity' ? <ActivityPanel /> : null}
			</div>
		</div>
	);
}
