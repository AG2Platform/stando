import { useState } from 'react';
import DecisionOptionButton from '@/components/atoms/decision-option-button';
import { APP_COPY } from '@/const-values/app-copy';
import { useQuestionAnswer } from '@/hooks/useQuestionAnswer';
import type { PendingQuestion } from '@/types/task';

export interface QuestionCardProps {
	question: PendingQuestion;
}

const DEFAULT_OPTIONS = ['Yes', 'No'] as const;

/** Renders a single pending question with answer chips and a free-form input. */
export default function QuestionCard({ question }: QuestionCardProps) {
	const { state, error, sentAnswer, send } = useQuestionAnswer(question.id);
	const [draft, setDraft] = useState('');
	const options = question.options ?? DEFAULT_OPTIONS;
	const isSending = state === 'sending';

	if (state === 'sent' && sentAnswer) {
		return (
			<div style={{ color: '#4ecca3', fontSize: 14 }}>
				{APP_COPY.questionAnswered} <strong>{sentAnswer}</strong>
			</div>
		);
	}

	return (
		<>
			<div>{question.text}</div>
			{question.detail ? (
				<div style={{ marginTop: 4, fontSize: 13, color: '#999', whiteSpace: 'pre-wrap' }}>
					{question.detail}
				</div>
			) : null}
			<div className="q-actions">
				{options.map((opt) => (
					<DecisionOptionButton key={opt} option={opt} disabled={isSending} onSelect={(o) => void send(o)} />
				))}
				<input
					type="text"
					className="q-input"
					value={draft}
					onChange={(e) => setDraft(e.target.value)}
					placeholder={APP_COPY.questionPlaceholder}
					disabled={isSending}
					onKeyDown={(e) => {
						if (e.key === 'Enter' && draft.trim()) {
							e.preventDefault();
							void send(draft);
						}
					}}
				/>
				<button
					type="button"
					className="q-btn"
					disabled={isSending || !draft.trim()}
					onClick={() => void send(draft)}
				>
					{isSending ? APP_COPY.questionSending : APP_COPY.questionSend}
				</button>
			</div>
			{state === 'error' && error ? (
				<div style={{ marginTop: 6, color: '#e94560', fontSize: 13 }}>
					{APP_COPY.questionFailed} {error}
				</div>
			) : null}
		</>
	);
}
