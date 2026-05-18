import { useState } from 'react';
import StarterChips from '@/components/molecules/starter-chips';
import ActivityPanel from '@/components/organisms/activity-panel';
import NotesPanel from '@/components/organisms/notes-panel';
import QuestionsPanel from '@/components/organisms/questions-panel';
import TaskList from '@/components/organisms/task-list';
import { useTasks } from '@/hooks/useTasks';

/**
 * Dynamic region from the legacy conversation page — a 5-tab area that
 * sits between the keyboard-shortcuts bar and the bottom transcript panel.
 *
 * Tabs: Starter / Tasks / Notes / Questions / Activity. Counts appear in
 * the tab label when non-zero. Mirrors renderDRTabs() + renderTabContent()
 * in src/web-client-html.ts. All five tabs are wired to live data.
 */

type DynamicRegionTab = 'starter' | 'tasks' | 'notes' | 'questions' | 'activity';

export interface DynamicRegionProps {
	connected: boolean;
	onPickChip: (label: string) => void;
}

export default function DynamicRegion({ connected, onPickChip }: DynamicRegionProps) {
	const [active, setActive] = useState<DynamicRegionTab>('starter');
	const { tasks, questions } = useTasks();
	const taskCount = Object.values(tasks).filter((t) => t.status !== 'done').length;
	const questionCount = questions.length;

	const tabs: { id: DynamicRegionTab; label: string }[] = [
		{ id: 'starter', label: 'Starter' },
		{ id: 'tasks', label: `Tasks${taskCount > 0 ? ` (${taskCount})` : ''}` },
		{ id: 'notes', label: 'Notes' },
		{ id: 'questions', label: `Questions${questionCount > 0 ? ` (${questionCount})` : ''}` },
		{ id: 'activity', label: 'Activity' },
	];

	return (
		<div className="dynamic-region">
			<div className="dr-tabs">
				{tabs.map((tab) => {
					const isActive = tab.id === active;
					const unseenClass =
						!isActive && tab.id === 'questions' && questionCount > 0
							? 'unseen-questions'
							: !isActive && tab.id === 'tasks' && taskCount > 0
								? 'unseen-tasks'
								: '';
					return (
						<span
							key={tab.id}
							className={`dr-tab ${isActive ? 'active' : ''} ${unseenClass}`}
							onClick={() => setActive(tab.id)}
						>
							{tab.label}
						</span>
					);
				})}
			</div>
			<div className="dr-content">
				{active === 'starter' ? <StarterChips connected={connected} onPickChip={onPickChip} /> : null}
				{active === 'tasks' ? <TaskList /> : null}
				{active === 'notes' ? <NotesPanel /> : null}
				{active === 'questions' ? <QuestionsPanel /> : null}
				{active === 'activity' ? <ActivityPanel /> : null}
			</div>
		</div>
	);
}
