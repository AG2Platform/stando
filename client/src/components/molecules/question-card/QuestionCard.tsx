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
			<article className="rounded-md border border-emerald-500/40 bg-emerald-500/[0.06] p-3 text-xs text-emerald-200">
				{APP_COPY.questionAnswered} <span className="font-medium">{sentAnswer}</span>
			</article>
		);
	}

	return (
		<article className="space-y-2 rounded-md border border-neutral-800/80 bg-[color:var(--color-surface)]/60 p-3 text-sm">
			<header>
				<p className="font-medium text-[color:var(--color-text)]">{question.text}</p>
				{question.detail ? (
					<p className="mt-1 whitespace-pre-wrap text-xs text-[color:var(--color-text-mute)]">{question.detail}</p>
				) : null}
			</header>
			<div className="flex flex-wrap gap-1.5">
				{options.map((opt) => (
					<DecisionOptionButton key={opt} option={opt} disabled={isSending} onSelect={(o) => void send(o)} />
				))}
			</div>
			<div className="flex gap-2">
				<input
					type="text"
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
					className="flex-1 rounded-md border border-neutral-800/80 bg-neutral-950/60 px-2.5 py-1.5 text-xs text-[color:var(--color-text)] placeholder:text-[color:var(--color-text-mute)] focus:border-[color:var(--color-accent)] focus:outline-none"
				/>
				<button
					type="button"
					disabled={isSending || !draft.trim()}
					onClick={() => void send(draft)}
					className="rounded-md bg-[color:var(--color-accent)] px-3 py-1.5 text-xs font-medium text-neutral-950 disabled:opacity-50"
				>
					{isSending ? APP_COPY.questionSending : APP_COPY.questionSend}
				</button>
			</div>
			{state === 'error' && error ? (
				<p className="text-xs text-[color:var(--color-danger)]">
					{APP_COPY.questionFailed} {error}
				</p>
			) : null}
		</article>
	);
}
