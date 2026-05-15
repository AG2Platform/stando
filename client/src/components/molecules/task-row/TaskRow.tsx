import RelativeTime from '@/components/atoms/relative-time';
import TaskStatusIcon from '@/components/atoms/task-status-icon';
import { APP_COPY } from '@/const-values/app-copy';
import { summarizeTaskText, tagVoiceFallback } from '@/lib/task-summary';
import type { Task } from '@/types/task';

export interface TaskRowProps {
	task: Task;
	isExpanded: boolean;
	onToggle: (id: string) => void;
}

/**
 * Single task row. Click anywhere on the row (outside the result body) to
 * toggle expansion when the task has a result attached. Tasks without a
 * result render flat — no expand affordance — matching the legacy UX.
 */
export default function TaskRow({ task, isExpanded, onToggle }: TaskRowProps) {
	const hasResult = !!task.result;
	const taggedRaw = tagVoiceFallback(task.text || task.id);
	const displayText = isExpanded ? taggedRaw : summarizeTaskText(taggedRaw);
	const expandChipLabel = hasResult
		? isExpanded
			? APP_COPY.taskHideDetails
			: APP_COPY.taskShowDetails
		: null;

	const handleHeaderClick = () => {
		if (!hasResult) return;
		if (typeof window !== 'undefined' && window.getSelection()?.toString().length) return;
		onToggle(task.id);
	};

	return (
		<article className="overflow-hidden rounded-md border border-neutral-800/60 bg-[color:var(--color-surface)]/60 text-sm">
			<header
				role={hasResult ? 'button' : undefined}
				tabIndex={hasResult ? 0 : undefined}
				onClick={handleHeaderClick}
				onKeyDown={(e) => {
					if (hasResult && (e.key === 'Enter' || e.key === ' ')) {
						e.preventDefault();
						onToggle(task.id);
					}
				}}
				className={`flex items-center gap-2 px-3 py-2 ${hasResult ? 'cursor-pointer hover:bg-neutral-900/60' : ''}`}
			>
				<TaskStatusIcon status={task.status} />
				<span className={`flex-1 truncate ${isExpanded ? 'whitespace-pre-wrap' : ''}`}>{displayText}</span>
				<RelativeTime ts={task.time} />
				{expandChipLabel ? (
					<span className="rounded-full bg-neutral-800/60 px-2 py-0.5 text-[11px] text-[color:var(--color-text-mute)]">
						{expandChipLabel}
					</span>
				) : null}
			</header>
			{hasResult && isExpanded ? (
				<pre
					id={`result-${task.id}`}
					className="m-0 max-h-64 overflow-auto whitespace-pre-wrap break-words border-t border-neutral-800/60 bg-neutral-950/60 px-3 py-2 text-xs leading-relaxed text-[color:var(--color-text-dim)]"
				>
					{task.result}
				</pre>
			) : null}
		</article>
	);
}
