/**
 * POST /answer on the Python agent API. Used by the questions panel to
 * resolve a pending decision; the next /tasks/active poll reconciles the
 * local question list.
 */

export interface PostQuestionAnswerResult {
	ok: boolean;
	error?: string;
}

export async function postQuestionAnswer(
	agentApiOrigin: string,
	id: string,
	answer: string,
	signal?: AbortSignal
): Promise<PostQuestionAnswerResult> {
	const trimmed = answer.trim();
	if (!trimmed) return { ok: false, error: 'empty answer' };
	try {
		const response = await fetch(`${agentApiOrigin.replace(/\/$/, '')}/answer`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({ id, answer: trimmed }),
			signal,
		});
		const data = (await response.json()) as PostQuestionAnswerResult;
		return { ok: !!data.ok, error: data.error };
	} catch (err) {
		return { ok: false, error: (err as Error).message };
	}
}
