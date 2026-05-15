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

const TONE: Record<TaskStatus, string> = {
	pending: 'text-[color:var(--color-text-mute)]',
	working: 'text-[color:var(--color-warning)] animate-spin-slow',
	done: 'text-[color:var(--color-success)]',
	error: 'text-[color:var(--color-danger)]',
};

export default function TaskStatusIcon({ status }: TaskStatusIconProps) {
	return (
		<span
			className={`inline-flex size-5 shrink-0 items-center justify-center text-[13px] leading-none ${TONE[status]}`}
			aria-label={status}
			title={status}
		>
			{GLYPH[status]}
		</span>
	);
}
