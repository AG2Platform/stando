import { useCallback, useState } from 'react';
import { resolveConfig } from '@/lib/config';
import { postTaskReply } from '@/lib/tasks-api';

export type TaskReplyState = 'idle' | 'sending' | 'sent' | 'error';

export interface UseTaskReplyResult {
	state: TaskReplyState;
	error: string | null;
	sentAnswer: string | null;
	send: (answer: string) => Promise<void>;
}

/**
 * Per-task reply state. Wraps postTaskReply() and tracks idle → sending →
 * sent / error transitions so the molecule can show the "Replied: …" line.
 * One hook instance per task row — when the row unmounts (collapsed), the
 * state evaporates, matching legacy behaviour where the action area was
 * rebuilt on every renderTasks() call.
 */
export function useTaskReply(taskId: string): UseTaskReplyResult {
	const [state, setState] = useState<TaskReplyState>('idle');
	const [error, setError] = useState<string | null>(null);
	const [sentAnswer, setSentAnswer] = useState<string | null>(null);

	const send = useCallback(
		async (answer: string) => {
			const trimmed = answer.trim();
			if (!trimmed) return;
			setState('sending');
			setError(null);
			const { agentApiOrigin } = resolveConfig();
			const result = await postTaskReply(agentApiOrigin, taskId, trimmed);
			if (result.ok) {
				setSentAnswer(trimmed);
				setState('sent');
			} else {
				setError(result.error ?? 'Reply failed');
				setState('error');
			}
		},
		[taskId]
	);

	return { state, error, sentAnswer, send };
}
