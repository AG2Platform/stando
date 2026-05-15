import { useMemo } from 'react';
import TaskRow from '@/components/molecules/task-row';
import { APP_COPY } from '@/const-values/app-copy';
import { MAX_DISPLAYED_TASKS } from '@/const-values/task-config';
import { taskActions, useTasks } from '@/hooks/useTasks';
import { useTaskPolling } from '@/hooks/useTaskPolling';
import type { Task } from '@/types/task';

/**
 * Task list organism. Subscribes to the task store and drives the polling
 * loop. Visual rules ported from web-client-html.ts renderTasks:
 *   - Sort by time desc, cap at MAX_DISPLAYED_TASKS.
 *   - Hide `done` tasks by default; toggle in the header reveals the count.
 *   - "collapse all" / "expand all" toggle reflects current expansion state.
 *   - Empty state when nothing has come through the agent API yet.
 */

const sortByMostRecent = (a: Task, b: Task): number => b.time - a.time;

export default function TaskList() {
	useTaskPolling();
	const { tasks, expanded, showDone, system } = useTasks();

	const { allEntries, doneCount, visible } = useMemo(() => {
		const allEntriesArr = Object.values(tasks);
		const doneCountArr = allEntriesArr.filter((t) => t.status === 'done').length;
		const visibleArr = (showDone ? allEntriesArr : allEntriesArr.filter((t) => t.status !== 'done'))
			.slice()
			.sort(sortByMostRecent)
			.slice(0, MAX_DISPLAYED_TASKS);
		return { allEntries: allEntriesArr, doneCount: doneCountArr, visible: visibleArr };
	}, [tasks, showDone]);

	const hasExpanded = expanded.size > 0;
	const isEmpty = allEntries.length === 0;
	const systemBadges: string[] = [
		!system.claudeOk ? APP_COPY.taskSystemBrainOffline : null,
		!system.watcherOk ? APP_COPY.taskSystemWatcherOffline : null,
	].filter((s) => s !== null);

	return (
		<div className="tasks">
			<div style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '4px 0 8px' }}>
				<span className="section-label" style={{ margin: 0 }}>{APP_COPY.taskListTitle}</span>
				{!isEmpty && doneCount > 0 ? (
					<button type="button" className="btn-subtle" onClick={taskActions.toggleShowDone}>
						{showDone ? `${APP_COPY.taskHideDone} ${doneCount}` : `${APP_COPY.taskShowDone} ${doneCount}`}
					</button>
				) : null}
				{!isEmpty ? (
					<button
						type="button"
						className="btn-subtle"
						onClick={hasExpanded ? taskActions.collapseAll : taskActions.expandAll}
					>
						{hasExpanded ? APP_COPY.taskCollapseAll : APP_COPY.taskExpandAll}
					</button>
				) : null}
				{systemBadges.length > 0 ? (
					<span style={{ marginLeft: 'auto', fontSize: 11, color: '#e94560' }}>{systemBadges.join(' · ')}</span>
				) : null}
			</div>

			{isEmpty ? (
				<div style={{ color: '#666', fontSize: 12, textAlign: 'center', padding: 12 }}>
					{APP_COPY.taskListEmpty}
				</div>
			) : visible.length === 0 ? (
				<div style={{ color: '#666', fontSize: 12, textAlign: 'center', padding: 12 }}>
					{APP_COPY.taskListAllDoneHidden}
				</div>
			) : (
				visible.map((task) => (
					<TaskRow
						key={task.id}
						task={task}
						isExpanded={expanded.has(task.id)}
						onToggle={taskActions.toggleExpanded}
					/>
				))
			)}
		</div>
	);
}
