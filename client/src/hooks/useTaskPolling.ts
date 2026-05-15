import { useEffect } from 'react';
import { TASK_POLL_INTERVAL_MS } from '@/const-values/task-config';
import { resolveConfig } from '@/lib/config';
import { taskStore } from '@/lib/task-store';
import { fetchActiveTasks } from '@/lib/tasks-api';

/**
 * Drive the task store from the Python agent API on a fixed cadence. The
 * fetch is abortable so a cleanup in StrictMode (or on unmount) cancels
 * any in-flight request instead of racing with the next tick.
 *
 * Logs failures to the console but otherwise swallows them — the legacy
 * web client treated /tasks/active as best-effort and never surfaced poll
 * errors in the UI. Network blips shouldn't blank the task list.
 */
export function useTaskPolling(): void {
	useEffect(() => {
		const { agentApiOrigin } = resolveConfig();
		const controller = new AbortController();
		let cancelled = false;

		const tick = async () => {
			try {
				const response = await fetchActiveTasks(agentApiOrigin, controller.signal);
				if (!cancelled) taskStore.handleApiTasks(response);
			} catch (err) {
				if (!cancelled && (err as Error).name !== 'AbortError') {
					console.warn('[task-polling]', (err as Error).message);
				}
			}
		};

		void tick();
		const intervalId = window.setInterval(tick, TASK_POLL_INTERVAL_MS);
		return () => {
			cancelled = true;
			window.clearInterval(intervalId);
			controller.abort();
		};
	}, []);
}
