/**
 * Framework-free task store backing the <TaskList /> organism.
 *
 * Persists across reloads via localStorage under the legacy schema keys
 * (sutando-taskmap-v1 / expanded / show-done) so existing users carry their
 * state seamlessly from / to /v2.
 *
 * Auto-expand rules ported from web-client-html.ts updateTask + polling:
 *   - New task arriving with status `working` → expand (unless userCollapsed).
 *   - Working → done transition → expand (one-shot, unless userCollapsed).
 *   - User toggles individual task → respected absolutely.
 *   - "Collapse all" sets userCollapsed=true; "Expand all" clears it.
 *
 * The store commits a new snapshot reference on every mutation so React's
 * useSyncExternalStore short-circuits cleanly.
 */

import { TASK_PERSIST_KEYS } from '@/const-values/task-config';
import type { ApiTasksResponse, Task, TaskListSnapshot } from '@/types/task';

const INITIAL_SYSTEM = { claudeOk: true, watcherOk: true } as const;

const loadTaskMap = (): Record<string, Task> => {
	try {
		const raw = localStorage.getItem(TASK_PERSIST_KEYS.taskMap);
		if (!raw) return {};
		return JSON.parse(raw) as Record<string, Task>;
	} catch {
		return {};
	}
};

const loadExpanded = (): Set<string> => {
	try {
		const raw = localStorage.getItem(TASK_PERSIST_KEYS.expanded);
		if (!raw) return new Set();
		const parsed = JSON.parse(raw) as readonly string[];
		return new Set(parsed);
	} catch {
		return new Set();
	}
};

const loadShowDone = (): boolean => {
	try {
		return localStorage.getItem(TASK_PERSIST_KEYS.showDone) === '1';
	} catch {
		return false;
	}
};

const persist = (snapshot: TaskListSnapshot): void => {
	try {
		localStorage.setItem(TASK_PERSIST_KEYS.taskMap, JSON.stringify(snapshot.tasks));
		localStorage.setItem(TASK_PERSIST_KEYS.expanded, JSON.stringify(Array.from(snapshot.expanded)));
		localStorage.setItem(TASK_PERSIST_KEYS.showDone, snapshot.showDone ? '1' : '0');
	} catch {
		/* private mode / quota — silently skip */
	}
};

class TaskStore {
	private snapshot: TaskListSnapshot;
	private listeners = new Set<() => void>();

	constructor() {
		this.snapshot = {
			tasks: loadTaskMap(),
			expanded: loadExpanded(),
			userCollapsed: false,
			showDone: loadShowDone(),
			system: INITIAL_SYSTEM,
			questions: [],
		};
	}

	getSnapshot = (): TaskListSnapshot => this.snapshot;

	subscribe = (listener: () => void): (() => void) => {
		this.listeners.add(listener);
		return () => this.listeners.delete(listener);
	};

	handleApiTasks(api: ApiTasksResponse): void {
		const incoming = api.tasks;
		const apiIds = new Set(incoming.map((t) => t.id));
		const nextExpanded = new Set(this.snapshot.expanded);
		const userCollapsed = this.snapshot.userCollapsed;

		const nextTasks = incoming.reduce<Record<string, Task>>((acc, t) => {
			const existing = this.snapshot.tasks[t.id];
			const isNew = !existing;
			const transitionedToDone = t.status === 'done' && existing?.status !== 'done';
			const shouldAutoExpand =
				!userCollapsed && !nextExpanded.has(t.id) && (isNew && t.status === 'working' || transitionedToDone);
			if (shouldAutoExpand) nextExpanded.add(t.id);
			acc[t.id] = {
				id: t.id,
				status: t.status,
				text: t.text,
				time: t.time * 1000,
				result: t.result ?? existing?.result ?? '',
			};
			return acc;
		}, {});

		// Carry over historical tasks the API no longer reports — except stale
		// `working` rows the API has dropped, which the legacy client also pruned.
		const carried = Object.values(this.snapshot.tasks)
			.filter((t) => !apiIds.has(t.id) && t.status !== 'working')
			.reduce<Record<string, Task>>((acc, t) => {
				acc[t.id] = t;
				return acc;
			}, {});

		this.commit({
			tasks: { ...carried, ...nextTasks },
			expanded: nextExpanded,
			userCollapsed,
			showDone: this.snapshot.showDone,
			system: { claudeOk: api.claude !== false, watcherOk: api.watcher !== false },
			questions: api.questions ?? [],
		});
	}

	/** Optimistic local removal after a successful POST /answer. The next
	 *  poll reconciles the truth. */
	removeQuestion(id: string): void {
		this.commit({
			...this.snapshot,
			questions: this.snapshot.questions.filter((q) => q.id !== id),
		});
	}

	toggleExpanded(id: string): void {
		const expanded = new Set(this.snapshot.expanded);
		const wasExpanded = expanded.has(id);
		if (wasExpanded) expanded.delete(id);
		else expanded.add(id);
		this.commit({
			...this.snapshot,
			expanded,
			userCollapsed: wasExpanded ? this.snapshot.userCollapsed : false,
		});
	}

	collapseAll(): void {
		this.commit({ ...this.snapshot, expanded: new Set(), userCollapsed: true });
	}

	expandAll(): void {
		const expanded = new Set(
			Object.values(this.snapshot.tasks)
				.filter((t) => t.result)
				.map((t) => t.id)
		);
		this.commit({ ...this.snapshot, expanded, userCollapsed: false });
	}

	toggleShowDone(): void {
		this.commit({ ...this.snapshot, showDone: !this.snapshot.showDone });
	}

	private commit(next: TaskListSnapshot): void {
		this.snapshot = next;
		persist(next);
		this.listeners.forEach((l) => l());
	}
}

export const taskStore = new TaskStore();
export type { TaskStore };
