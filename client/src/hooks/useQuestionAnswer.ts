import { useCallback, useState } from 'react';
import { resolveConfig } from '@/lib/config';
import { postQuestionAnswer } from '@/lib/questions-api';
import { taskStore } from '@/lib/task-store';

export type QuestionAnswerState = 'idle' | 'sending' | 'sent' | 'error';

export interface UseQuestionAnswerResult {
	state: QuestionAnswerState;
	error: string | null;
	sentAnswer: string | null;
	send: (answer: string) => Promise<void>;
}

/**
 * Per-question answer state. On success, optimistically drops the question
 * from the local store so the panel shrinks immediately — the next
 * /tasks/active poll reconciles. Mirrors the legacy 1.5s "Answered: …"
 * confirmation delay so the user sees the success state before the row
 * disappears.
 */
const SETTLE_MS = 1500;

export function useQuestionAnswer(questionId: string): UseQuestionAnswerResult {
	const [state, setState] = useState<QuestionAnswerState>('idle');
	const [error, setError] = useState<string | null>(null);
	const [sentAnswer, setSentAnswer] = useState<string | null>(null);

	const send = useCallback(
		async (answer: string) => {
			const trimmed = answer.trim();
			if (!trimmed) return;
			setState('sending');
			setError(null);
			const { agentApiOrigin } = resolveConfig();
			const result = await postQuestionAnswer(agentApiOrigin, questionId, trimmed);
			if (result.ok) {
				setSentAnswer(trimmed);
				setState('sent');
				window.setTimeout(() => taskStore.removeQuestion(questionId), SETTLE_MS);
			} else {
				setError(result.error ?? 'Answer failed');
				setState('error');
			}
		},
		[questionId]
	);

	return { state, error, sentAnswer, send };
}
