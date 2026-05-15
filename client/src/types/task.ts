/**
 * Task domain types. The internal `Task` mirrors what /tasks/active returns
 * but normalises the time field to ms-epoch (the API ships seconds) so the
 * store can serialise to JSON without Date round-trips.
 */

export type TaskStatus = 'pending' | 'working' | 'done' | 'error';

export interface Task {
	id: string;
	status: TaskStatus;
	text: string;
	/** ms since epoch (normalised from the API's seconds). */
	time: number;
	result: string;
}

export interface ApiTask {
	id: string;
	status: TaskStatus;
	text: string;
	/** Unix seconds — convert before storing internally. */
	time: number;
	result?: string;
}

export interface ApiTasksResponse {
	tasks: readonly ApiTask[];
	claude?: boolean;
	watcher?: boolean;
	questions?: readonly unknown[];
}

export interface SystemHealth {
	claudeOk: boolean;
	watcherOk: boolean;
}

export interface TaskListSnapshot {
	tasks: Readonly<Record<string, Task>>;
	expanded: ReadonlySet<string>;
	userCollapsed: boolean;
	showDone: boolean;
	system: SystemHealth;
}
