/**
 * Task list tuning constants and localStorage keys. Persistence key versions
 * match the legacy web-client-html.ts schema so the migration is transparent
 * — users carry their existing taskMap + expanded set from / over to /v2.
 */

export const TASK_POLL_INTERVAL_MS = 3000;
export const MAX_DISPLAYED_TASKS = 30;
export const SUMMARY_MAX_CHARS = 85;

export const TASK_PERSIST_KEYS = {
	taskMap: 'sutando-taskmap-v1',
	expanded: 'sutando-expanded-v1',
	showDone: 'sutando-show-done-v1',
} as const;
