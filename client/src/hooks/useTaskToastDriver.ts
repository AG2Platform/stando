import { useEffect, useRef } from 'react';
import { toastStore } from '@/lib/toast-store';
import { useTasks } from '@/hooks/useTasks';
import type { TaskStatus } from '@/types/task';

const SNIPPET_LEN = 60;

const snippetFor = (text: string): string => (text.length > SNIPPET_LEN ? `${text.slice(0, SNIPPET_LEN)}…` : text);

/**
 * Diff the task snapshot against last-seen state to fire toasts. Two
 * triggers match legacy parity:
 *
 *   - First sighting of a task id → "Context received".
 *   - Status transition working → done → "Done".
 *
 * Ref state isn't reactive (no re-renders for ref writes) so we don't
 * waste a render cycle just because the diff produced a toast.
 */
export function useTaskToastDriver(): void {
	const { tasks } = useTasks();
	const knownIdsRef = useRef<Set<string>>(new Set(Object.keys(tasks)));
	const lastStatusRef = useRef<Map<string, TaskStatus>>(
		new Map(Object.entries(tasks).map(([id, t]) => [id, t.status]))
	);

	useEffect(() => {
		const known = knownIdsRef.current;
		const lastStatus = lastStatusRef.current;

		Object.values(tasks).forEach((t) => {
			if (!known.has(t.id)) {
				known.add(t.id);
				toastStore.push('info', snippetFor(t.text || t.id), 'Context received');
			}
			const previous = lastStatus.get(t.id);
			if (t.status === 'done' && previous && previous !== 'done') {
				toastStore.push('success', snippetFor(t.text || t.id), 'Done');
			}
			lastStatus.set(t.id, t.status);
		});
	}, [tasks]);
}
