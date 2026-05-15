import { useState } from 'react';
import DecisionOptionButton from '@/components/atoms/decision-option-button';
import { APP_COPY } from '@/const-values/app-copy';
import { useTaskReply } from '@/hooks/useTaskReply';

export interface TaskReplyFormProps {
	taskId: string;
	/** Detected decision options (parseDecisionOptions). When non-null, the
	 *  form shows them as quick-pick buttons in addition to the free-form
	 *  input. */
	options: readonly string[] | null;
}

/**
 * Inline reply form rendered under an expanded task. Sends via the agent
 * API (`POST /task` with `from: web-reply:<taskId>`). On success, collapses
 * itself into a "Replied: …" line so the user can't double-send.
 */
export default function TaskReplyForm({ taskId, options }: TaskReplyFormProps) {
	const { state, error, sentAnswer, send } = useTaskReply(taskId);
	const [draft, setDraft] = useState('');

	if (state === 'sent' && sentAnswer) {
		return (
			<div className="mt-2 rounded-md bg-emerald-500/10 px-3 py-2 text-xs text-emerald-200">
				{APP_COPY.taskReplySent} <span className="font-medium">{sentAnswer}</span>
			</div>
		);
	}

	const isSending = state === 'sending';
	const placeholder = options ? APP_COPY.taskReplyPlaceholderOrType : APP_COPY.taskReplyPlaceholder;

	const handleSubmit = (e: React.FormEvent) => {
		e.preventDefault();
		void send(draft);
	};

	return (
		<form onSubmit={handleSubmit} className="mt-2 space-y-2">
			{options ? (
				<div className="flex flex-wrap gap-1.5">
					{options.map((opt) => (
						<DecisionOptionButton key={opt} option={opt} disabled={isSending} onSelect={(o) => void send(o)} />
					))}
				</div>
			) : null}
			<div className="flex gap-2">
				<input
					type="text"
					value={draft}
					onChange={(e) => setDraft(e.target.value)}
					placeholder={placeholder}
					disabled={isSending}
					className="flex-1 rounded-md border border-neutral-800/80 bg-neutral-950/60 px-2.5 py-1.5 text-xs text-[color:var(--color-text)] placeholder:text-[color:var(--color-text-mute)] focus:border-[color:var(--color-accent)] focus:outline-none"
				/>
				<button
					type="submit"
					disabled={isSending || !draft.trim()}
					className="rounded-md bg-[color:var(--color-accent)] px-3 py-1.5 text-xs font-medium text-neutral-950 disabled:opacity-50"
				>
					{isSending ? APP_COPY.taskReplySending : APP_COPY.taskReplySend}
				</button>
			</div>
			{state === 'error' && error ? (
				<p className="text-xs text-[color:var(--color-danger)]">
					{APP_COPY.taskReplyFailed} {error}
				</p>
			) : null}
		</form>
	);
}
