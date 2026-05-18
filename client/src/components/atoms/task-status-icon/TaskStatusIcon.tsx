import type { TaskStatus } from '@/types/task';

export interface TaskStatusIconProps {
	status: TaskStatus;
}

const GLYPH: Record<TaskStatus, string> = {
	pending: '⏳',
	working: '⚙',
	done: '✓',
	error: '✗',
};

/**
 * Status dot for a task row. Uses the legacy `.task-status.{status}` class
 * so legacy.css handles the per-state background colors + pulse animation.
 */
export default function TaskStatusIcon({ status }: TaskStatusIconProps) {
	return (
		<div className={`task-status ${status}`} aria-label={status} title={status}>
			{GLYPH[status]}
		</div>
	);
}
