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
		<section className="rounded-lg border border-neutral-800/80 bg-[color:var(--color-surface)]/40 p-4">
			<header className="flex flex-wrap items-center gap-3">
				<h2 className="text-sm font-semibold text-[color:var(--color-text)]">{APP_COPY.taskListTitle}</h2>
				{!isEmpty ? (
					<>
						{doneCount > 0 ? (
							<button
								type="button"
								onClick={taskActions.toggleShowDone}
								className="text-[11px] uppercase tracking-wide text-[color:var(--color-text-mute)] hover:text-[color:var(--color-text)]"
							>
								{showDone
									? `${APP_COPY.taskHideDone} ${doneCount}`
									: `${APP_COPY.taskShowDone} ${doneCount}`}
							</button>
						) : null}
						<button
							type="button"
							onClick={hasExpanded ? taskActions.collapseAll : taskActions.expandAll}
							className="text-[11px] uppercase tracking-wide text-[color:var(--color-text-mute)] hover:text-[color:var(--color-text)]"
						>
							{hasExpanded ? APP_COPY.taskCollapseAll : APP_COPY.taskExpandAll}
						</button>
					</>
				) : null}
				{systemBadges.length > 0 ? (
					<span className="ml-auto text-[11px] text-[color:var(--color-danger)]">{systemBadges.join(' · ')}</span>
				) : null}
			</header>

			<div className="mt-3 flex flex-col gap-2">
				{isEmpty ? (
					<p className="px-1 text-xs text-[color:var(--color-text-mute)]">{APP_COPY.taskListEmpty}</p>
				) : visible.length === 0 ? (
					<p className="px-1 text-xs text-[color:var(--color-text-mute)]">{APP_COPY.taskListAllDoneHidden}</p>
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
		</section>
	);
}
