// TypeScript twin of src/util_paths.py — personal-asset path resolution.
//
// Three helpers covering the three persistence tiers:
//
//   personalPath(filename)          — `$SUTANDO_PRIVATE_DIR/machine-<host>/<filename>`
//                                     For files where each Mac has its own copy
//                                     synced via the private repo
//                                     (stand-identity.json, pending-questions.md).
//
//   sharedPersonalPath(filename)    — `$SUTANDO_PRIVATE_DIR/<filename>`
//                                     For files synced across the whole fleet
//                                     (notes/, build_log.md).
//
//   statePath(name)                 — `$SUTANDO_HOME/<name>`
//                                     For per-machine runtime state that is NOT
//                                     synced (tasks/, results/, state/, logs/,
//                                     core-status.json, voice-state.json,
//                                     conversation.log). The .app bundle sets
//                                     SUTANDO_HOME to ~/Library/Application
//                                     Support/Sutando so state lives outside
//                                     the read-only bundle.
//
// All fall back to `<workspace>/<filename>` so existing installs keep working
// until they migrate.

import { existsSync, mkdirSync } from 'node:fs';
import { hostname } from 'node:os';
import { dirname, join } from 'node:path';

function expandHome(p: string): string {
	return p.replace(/^~/, process.env.HOME || '');
}

const REPO_ROOT = new URL('..', import.meta.url).pathname.replace(/\/$/, '');

/** Per-machine runtime state path. Resolves to `$SUTANDO_HOME/<name>` when
 * SUTANDO_HOME is set, else `<REPO_ROOT>/<name>` for backwards compatibility. */
export function statePath(name: string): string {
	const home = process.env.SUTANDO_HOME;
	const root = home ? expandHome(home) : REPO_ROOT;
	return join(root, name);
}

/** Like statePath() but also ensures the parent directory exists. Use when
 * the caller is about to write a file. */
export function statePathEnsured(name: string): string {
	const p = statePath(name);
	mkdirSync(dirname(p), { recursive: true });
	return p;
}

/** Like statePath() but ensures the path itself exists as a directory. Use
 * when resolving a directory like 'tasks' or 'results'. */
export function stateDir(name: string): string {
	const p = statePath(name);
	mkdirSync(p, { recursive: true });
	return p;
}

/** Per-machine resolver. */
export function personalPath(filename: string, workspace?: string): string {
	const ws = workspace ?? process.cwd();
	const privateRoot = process.env.SUTANDO_PRIVATE_DIR;
	if (privateRoot) {
		const root = expandHome(privateRoot);
		const host = hostname().split('.')[0];
		const candidate = join(root, `machine-${host}`, filename);
		if (existsSync(candidate)) return candidate;
	}
	// stand-avatar.png lives under assets/ in the public workspace.
	if (filename === 'stand-avatar.png') {
		const inAssets = join(ws, 'assets', filename);
		if (existsSync(inAssets)) return inAssets;
	}
	const wsPath = join(ws, filename);
	if (existsSync(wsPath)) return wsPath;
	// Nothing exists; return preferred private path so caller's existsSync()
	// check fails gracefully.
	if (privateRoot) {
		const root = expandHome(privateRoot);
		const host = hostname().split('.')[0];
		return join(root, `machine-${host}`, filename);
	}
	if (filename === 'stand-avatar.png') return join(ws, 'assets', filename);
	return wsPath;
}

/** Shared-across-fleet resolver (top-level private dir, not per-machine). */
export function sharedPersonalPath(filename: string, workspace?: string): string {
	const ws = workspace ?? process.cwd();
	const privateRoot = process.env.SUTANDO_PRIVATE_DIR;
	if (privateRoot) {
		const root = expandHome(privateRoot);
		const candidate = join(root, filename);
		if (existsSync(candidate)) return candidate;
		const wsPath = join(ws, filename);
		if (existsSync(wsPath)) return wsPath;
		return candidate;
	}
	return join(ws, filename);
}
