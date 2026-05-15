/**
 * Server-agnostic runtime config.
 *
 * Sutando's frontend ships in four very different shells:
 *   1. Local desktop — WKWebView in src/Sutando/UnifiedMainWindow.swift
 *      points at `http://localhost:8080/v2/`.
 *   2. Remote browser — same URL but resolved over LAN / Tailscale /
 *      EC2 DNS. WebSocket host needs to match whatever the browser is
 *      currently rendering from, not a hardcoded localhost.
 *   3. Future mobile thin-client — iOS WKWebView pointing at the same
 *      bundle hosted from the user's Sutando server.
 *   4. Vite dev server (port 5173) — proxies to the real backend on 8080.
 *
 * The resolution order below makes none of those shells need a custom
 * build: query string > globalThis injection > current window location.
 * No environment variables, no rebuilds.
 */

export interface SutandoConfig {
	/** WebSocket URL for the voice agent (default: ws://<current host>:9900). */
	wsUrl: string;
	/** HTTP origin for the conversation HTTP API (default: <current origin>). */
	apiOrigin: string;
	/** Active route id from `?page=`, falling back to the default. */
	initialRouteId: string;
}

const DEFAULT_WS_PORT = 9900;

/**
 * Browser-side config resolution. Re-runs on every call — cheap (no
 * network, no parsing surprises), and lets the test harness reset
 * `window.location` between cases without stale memoization.
 */
export function resolveConfig(): SutandoConfig {
	const params = new URLSearchParams(window.location.search);
	const injected = (window as unknown as { __SUTANDO_CONFIG__?: Partial<SutandoConfig> }).__SUTANDO_CONFIG__ ?? {};

	const wsUrl = params.get('ws') ?? injected.wsUrl ?? defaultWsUrlForCurrentHost();
	const apiOrigin = params.get('api') ?? injected.apiOrigin ?? window.location.origin;
	const initialRouteId = params.get('page') ?? injected.initialRouteId ?? 'conversation';

	return { wsUrl, apiOrigin, initialRouteId };
}

const defaultWsUrlForCurrentHost = (): string => {
	const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
	const host = window.location.hostname || 'localhost';
	return `${protocol}//${host}:${DEFAULT_WS_PORT}`;
};
