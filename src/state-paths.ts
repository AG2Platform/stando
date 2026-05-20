// Per-machine runtime-state paths (tasks/, results/, state/, logs/, …).
//
// Thin wrapper over resolveWorkspace() from workspace_default.ts. Kept in its
// own module so util_paths.ts stays identical to upstream sonichi/sutando —
// canonical workspace resolution lives in workspace_default, this file only
// adds the fork's directory-ensuring convenience.
//
//   statePath(name)         — file path under the workspace (no mkdir).
//   statePathEnsured(name)  — like statePath() but ensures the parent exists.
//   stateDir(name)          — directory under the workspace; ensures it exists.
//
// All resolve under $SUTANDO_WORKSPACE (default ~/.sutando/workspace/).

import { mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { resolveWorkspace } from './workspace_default.js';

/** Runtime-state file path under the workspace. Does not create anything. */
export function statePath(name: string): string {
	return join(resolveWorkspace(), name);
}

/** Like statePath() but ensures the parent directory exists. Use before a write. */
export function statePathEnsured(name: string): string {
	const p = statePath(name);
	mkdirSync(dirname(p), { recursive: true });
	return p;
}

/** Runtime-state directory under the workspace. Ensures the directory exists. */
export function stateDir(name: string): string {
	const p = statePath(name);
	mkdirSync(p, { recursive: true });
	return p;
}
