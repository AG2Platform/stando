/**
 * Thin fetch wrappers around the Python agent API on port 7843. The agent
 * API runs in a separate process from web-server.ts (different lifetime,
 * different language) so this client lives in lib/ — components/hooks never
 * call fetch directly.
 */

import type { ApiTasksResponse } from '@/types/task';

const stripTrailingSlash = (origin: string): string => origin.replace(/\/$/, '');

export async function fetchActiveTasks(agentApiOrigin: string, signal?: AbortSignal): Promise<ApiTasksResponse> {
	const url = `${stripTrailingSlash(agentApiOrigin)}/tasks/active`;
	const response = await fetch(url, { signal });
	if (!response.ok) {
		throw new Error(`fetchActiveTasks ${response.status}`);
	}
	return (await response.json()) as ApiTasksResponse;
}

export interface PostTaskReplyResult {
	ok: boolean;
	error?: string;
}

/**
 * Reply to a task. Posts to /task with `from: 'web-reply:<taskId>'` so the
 * bridge can correlate the new task with the originating result. Mirrors
 * the legacy replyToTask() contract exactly.
 */
export async function postTaskReply(
	agentApiOrigin: string,
	taskId: string,
	answer: string,
	signal?: AbortSignal
): Promise<PostTaskReplyResult> {
	const trimmed = answer.trim();
	if (!trimmed) return { ok: false, error: 'empty answer' };
	try {
		const response = await fetch(`${stripTrailingSlash(agentApiOrigin)}/task`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({ from: `web-reply:${taskId}`, task: trimmed }),
			signal,
		});
		const data = (await response.json()) as PostTaskReplyResult;
		return { ok: !!data.ok, error: data.error };
	} catch (err) {
		return { ok: false, error: (err as Error).message };
	}
}

export interface PostTaskResult {
	ok: boolean;
	task_id?: string;
	error?: string;
}

export interface TaskResultPoll {
	status: 'pending' | 'completed' | 'error';
	result?: string;
}

/**
 * Submit a free-form task as the `web` channel — same path as the
 * legacy `sendText()` voice-disconnected fallback. The Python agent
 * bridge writes a task file; the result lands at /result/<task_id>.
 */
export async function postWebTask(
	agentApiOrigin: string,
	task: string,
	signal?: AbortSignal
): Promise<PostTaskResult> {
	const trimmed = task.trim();
	if (!trimmed) return { ok: false, error: 'empty task' };
	try {
		const response = await fetch(`${stripTrailingSlash(agentApiOrigin)}/task`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({ from: 'web', task: trimmed }),
			signal,
		});
		return (await response.json()) as PostTaskResult;
	} catch (err) {
		return { ok: false, error: (err as Error).message };
	}
}

export async function fetchTaskResult(
	agentApiOrigin: string,
	taskId: string,
	signal?: AbortSignal
): Promise<TaskResultPoll> {
	const response = await fetch(`${stripTrailingSlash(agentApiOrigin)}/result/${taskId}`, { signal });
	if (!response.ok) throw new Error(`fetchTaskResult ${response.status}`);
	return (await response.json()) as TaskResultPoll;
}
