import { useState } from 'react';
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
			<div className="task-action-sent">
				{APP_COPY.taskReplySent} <strong>{sentAnswer}</strong>
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
		<form onSubmit={handleSubmit} className="task-actions">
			{options
				? options.map((opt) => (
						<button
							key={opt}
							type="button"
							className="task-action-btn"
							disabled={isSending}
							onClick={() => void send(opt)}
						>
							{opt}
						</button>
					))
				: null}
			<input
				type="text"
				className="task-action-input"
				value={draft}
				onChange={(e) => setDraft(e.target.value)}
				placeholder={placeholder}
				disabled={isSending}
			/>
			<button type="submit" className="task-action-btn" disabled={isSending || !draft.trim()}>
				{isSending ? APP_COPY.taskReplySending : APP_COPY.taskReplySend}
			</button>
			{state === 'error' && error ? (
				<span style={{ color: '#e94560', fontSize: 12 }}>{APP_COPY.taskReplyFailed} {error}</span>
			) : null}
		</form>
	);
}
