import RelativeTime from '@/components/atoms/relative-time';
import TaskStatusIcon from '@/components/atoms/task-status-icon';
import TaskReplyForm from '@/components/molecules/task-reply-form';
import { APP_COPY } from '@/const-values/app-copy';
import { parseDecisionOptions } from '@/lib/parse-decision-options';
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
		<>
			<div
				className="task-item"
				role={hasResult ? 'button' : undefined}
				tabIndex={hasResult ? 0 : undefined}
				onClick={handleHeaderClick}
				onKeyDown={(e) => {
					if (hasResult && (e.key === 'Enter' || e.key === ' ')) {
						e.preventDefault();
						onToggle(task.id);
					}
				}}
			>
				<TaskStatusIcon status={task.status} />
				<span className={`task-text${isExpanded ? ' expanded' : ''}`}>{displayText}</span>
				<RelativeTime ts={task.time} />
				{expandChipLabel ? <span className="task-expand">{expandChipLabel}</span> : null}
			</div>
			{hasResult && isExpanded ? (
				<>
					<pre
						id={`result-${task.id}`}
						style={{
							display: 'block',
							padding: '8px 12px',
							color: '#b8c8d8',
							fontSize: 12,
							lineHeight: 1.5,
							whiteSpace: 'pre-wrap',
							wordBreak: 'break-word',
							background: '#0d1520',
							borderRadius: 8,
							margin: '4px 0 6px 30px',
							maxHeight: 256,
							overflow: 'auto',
						}}
					>
						{task.result}
					</pre>
					<TaskReplyForm taskId={task.id} options={parseDecisionOptions(task.result)} />
				</>
			) : null}
		</>
	);
}
