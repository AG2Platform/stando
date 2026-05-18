import { useSyncExternalStore } from 'react';
import { taskStore } from '@/lib/task-store';
import type { TaskListSnapshot } from '@/types/task';

/**
 * Subscribe to the shared task store. Components/molecules consume this
 * directly and dispatch via the actions returned alongside the snapshot.
 */
export function useTasks(): TaskListSnapshot {
	return useSyncExternalStore(taskStore.subscribe, taskStore.getSnapshot, taskStore.getSnapshot);
}

export const taskActions = {
	toggleExpanded: (id: string) => taskStore.toggleExpanded(id),
	collapseAll: () => taskStore.collapseAll(),
	expandAll: () => taskStore.expandAll(),
	toggleShowDone: () => taskStore.toggleShowDone(),
};
