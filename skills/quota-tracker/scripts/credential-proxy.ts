/**
 * Sutando credential proxy — intercepts Anthropic API calls to read rate limit headers.
 *
 * Based on nanoclaw's credential-proxy.ts approach:
 * - Runs as a local HTTP proxy between Claude Code and api.anthropic.com
 * - Injects OAuth credentials from macOS keychain
 * - Reads `anthropic-ratelimit-unified-*` headers from responses
 * - Writes quota state to <workspace>/state/quota-state.json for the dashboard
 *
 * Usage:
 *   npx tsx src/credential-proxy.ts              # start on port 7846
 *   ANTHROPIC_BASE_URL=http://localhost:7846 claude ...  # route Claude through proxy
 */

import { createServer, request as httpRequest, type RequestOptions } from 'node:http';
import { request as httpsRequest } from 'node:https';
import { execSync } from 'node:child_process';
import { writeFileSync, readFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { statusPath } from '../../../src/workspace_default.js';

const PORT = 7846;
const UPSTREAM = 'https://api.anthropic.com';
// Inactivity guard on the upstream socket. Claude streams tokens, so a healthy
// request keeps the socket active and this never fires; it only trips when NO
// bytes flow for the window — the silently-dead-socket case (sleep/wake, wifi
// drop) that otherwise leaves an in-flight request hanging forever and wedges
// the core. Tunable via PROXY_IDLE_TIMEOUT_MS (default 120s — comfortably longer
// than the worst-case time-to-first-token on a 1M-context prompt).
const IDLE_TIMEOUT_MS = Number(process.env.PROXY_IDLE_TIMEOUT_MS) || 120_000;
// Quota state is per-user runtime state — canonical home is <workspace>/state/.
// Historically written into the skill dir; readers (dashboard.py, read-quota.py)
// keep the skill-dir path as a last-resort fallback for one release.
const QUOTA_FILE = statusPath('quota-state.json');

function ts(): string { return new Date().toISOString().slice(11, 23); }

// Read OAuth token from macOS keychain
function getOAuthToken(): string | null {
	try {
		const cred = execSync('security find-generic-password -s "Claude Code-credentials" -w', {
			encoding: 'utf-8',
			timeout: 5000,
		}).trim();
		const parsed = JSON.parse(cred);
		return parsed?.claudeAiOauth?.accessToken ?? null;
	} catch {
		return null;
	}
}

function updateQuotaState(headers: Record<string, string>): void {
	try {
		const state: Record<string, unknown> = {
			available: true,
			last_checked: new Date().toISOString(),
			headers,
		};

		// Parse specific headers
		const status5h = headers['anthropic-ratelimit-unified-5h-status'];
		const util5h = headers['anthropic-ratelimit-unified-5h-utilization'];
		const reset5h = headers['anthropic-ratelimit-unified-5h-reset'];
		const util7d = headers['anthropic-ratelimit-unified-7d-utilization'];
		const reset7d = headers['anthropic-ratelimit-unified-7d-reset'];
		const overallStatus = headers['anthropic-ratelimit-unified-status'];

		if (util5h) state.utilization_5h = parseFloat(util5h);
		if (util7d) state.utilization_7d = parseFloat(util7d);
		if (reset5h) state.resets_at_5h = new Date(parseInt(reset5h) * 1000).toISOString();
		if (reset7d) state.resets_at_7d = new Date(parseInt(reset7d) * 1000).toISOString();

		if (overallStatus === 'rejected' || status5h === 'rejected') {
			state.available = false;
			state.exhausted_since = new Date().toISOString();
		}

		mkdirSync(dirname(QUOTA_FILE), { recursive: true });
		writeFileSync(QUOTA_FILE, JSON.stringify(state, null, 2));
	} catch { /* best effort */ }
}

// Verify token exists at startup
const initToken = getOAuthToken();
if (!initToken) {
	console.error('No OAuth token found in macOS keychain. Is Claude Code logged in?');
	process.exit(1);
}
console.log(`${ts()} [Proxy] OAuth token loaded from keychain (will re-read on each request)`);

const upstreamUrl = new URL(UPSTREAM);

const server = createServer((req, res) => {
	const chunks: Buffer[] = [];
	req.on('data', (c) => chunks.push(c));
	req.on('end', () => {
		const body = Buffer.concat(chunks);

		// Read token fresh from keychain each request (tokens get refreshed by active sessions)
		const oauthToken = getOAuthToken();
		if (!oauthToken) {
			res.writeHead(502);
			res.end('No OAuth token in keychain');
			return;
		}

		const headers: Record<string, string | number | string[] | undefined> = {
			...(req.headers as Record<string, string>),
			host: upstreamUrl.host,
			'content-length': body.length,
		};

		// Strip hop-by-hop headers
		delete headers['connection'];
		delete headers['keep-alive'];
		delete headers['transfer-encoding'];

		// Inject OAuth token for auth requests
		if (headers['authorization']) {
			delete headers['authorization'];
			headers['authorization'] = `Bearer ${oauthToken}`;
		}

		const upstream = httpsRequest(
			{
				hostname: upstreamUrl.hostname,
				port: 443,
				path: req.url,
				method: req.method,
				headers,
			} as RequestOptions,
			(upRes) => {
				// Extract rate limit headers
				const quotaHeaders: Record<string, string> = {};
				for (const [key, val] of Object.entries(upRes.headers)) {
					if (key.startsWith('anthropic-ratelimit')) {
						quotaHeaders[key] = String(val);
					}
				}
				if (Object.keys(quotaHeaders).length > 0) {
					console.log(`${ts()} [Quota]`, quotaHeaders);
					updateQuotaState(quotaHeaders);
				}

				res.writeHead(upRes.statusCode!, upRes.headers);
				upRes.pipe(res);
				// Disarm the idle guard once the response completes, so a pooled
				// keep-alive socket sitting idle later can't fire it spuriously.
				upRes.on('end', () => upstream.setTimeout(0));
			},
		);

		// Streaming-safe inactivity guard. socket.setTimeout fires only when the
		// socket has been idle (no read/write) for the window — token streaming
		// resets it continuously, so legitimate long generations are unaffected,
		// but a silently dead socket trips it. Without this an in-flight request
		// hangs forever and the core sits on the dead socket (the indefinite
		// "agent went silent" freeze). On trip, destroy upstream → 'error' below.
		upstream.setTimeout(IDLE_TIMEOUT_MS, () => {
			console.error(`${ts()} [Proxy] Upstream idle >${IDLE_TIMEOUT_MS}ms — aborting (dead socket?)`);
			upstream.destroy(new Error('upstream idle timeout'));
		});

		upstream.on('error', (err) => {
			console.error(`${ts()} [Proxy] Upstream error:`, err.message);
			if (!res.headersSent) {
				// 504 for the idle-timeout trip, 502 for other upstream failures —
				// both are retryable by Claude Code, which is the whole point: surface
				// a normal error it can retry, never an infinite hang.
				res.writeHead(err.message === 'upstream idle timeout' ? 504 : 502);
				res.end('Bad Gateway');
			} else {
				// Headers already flushed mid-stream — status can't change. Abort the
				// client socket so Claude Code's HTTP layer sees a broken stream and
				// retries, instead of blocking on a half-open connection forever.
				res.destroy(err);
			}
		});

		upstream.write(body);
		upstream.end();
	});
});

server.listen(PORT, '127.0.0.1', () => {
	console.log(`${ts()} [Proxy] Credential proxy → http://localhost:${PORT}`);
	console.log(`${ts()} [Proxy] Upstream: ${UPSTREAM}`);
	console.log(`${ts()} [Proxy] Set ANTHROPIC_BASE_URL=http://localhost:${PORT} to route through proxy`);
});
