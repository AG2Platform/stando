/**
 * Sutando's four page routes. Each matches a UnifiedPane case in
 * src/Sutando/UnifiedMainWindow.swift so the desktop WKWebView can load
 * the right page by setting `?page=<id>` on the bundle URL.
 *
 * The shape (id + label + icon hint) lives in const-values so navigation
 * UI never hardcodes copy. Per CLAUDE.md § Frontend Conventions: "no
 * hardcoded strings — all copy and static values live in const-values/".
 */

export const APP_ROUTE_IDS = ['conversation', 'core-cli', 'dashboard', 'settings'] as const;

export type AppRouteId = (typeof APP_ROUTE_IDS)[number];

export interface AppRoute {
	id: AppRouteId;
	label: string;
	hint: string;
}

export const APP_ROUTES: Record<AppRouteId, AppRoute> = {
	conversation: {
		id: 'conversation',
		label: 'Conversation',
		hint: 'Voice + transcript with the agent.',
	},
	'core-cli': {
		id: 'core-cli',
		label: 'Core CLI',
		hint: 'Claude Code CLI inside Sutando.',
	},
	dashboard: {
		id: 'dashboard',
		label: 'Dashboard',
		hint: 'Quota, sessions, recent tasks.',
	},
	settings: {
		id: 'settings',
		label: 'Settings',
		hint: 'Voice, models, integrations.',
	},
};

export const DEFAULT_ROUTE_ID: AppRouteId = 'conversation';

export const isAppRouteId = (value: string): value is AppRouteId =>
	APP_ROUTE_IDS.includes(value as AppRouteId);
