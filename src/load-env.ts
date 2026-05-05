// Layered .env loader.
//
// Priority (later overrides earlier, but never overrides existing process.env):
//   1. Repo .env (dev fallback)
//   2. $SUTANDO_HOME/.env (per-machine config managed by the .app bundle)
//
// Importing this module has the same shape as `import 'dotenv/config'` —
// side-effecting, no exports needed by callers.

import { config } from 'dotenv';
import { existsSync } from 'node:fs';
import { join } from 'node:path';

function expandHome(p: string): string {
	return p.replace(/^~/, process.env.HOME || '');
}

const REPO_DIR = new URL('..', import.meta.url).pathname.replace(/\/$/, '');

// Step 1: repo .env (dev workflow). dotenv does not override existing
// process.env entries, so anything already set wins over the file.
const repoEnv = join(REPO_DIR, '.env');
if (existsSync(repoEnv)) config({ path: repoEnv });

// Step 2: SUTANDO_HOME/.env, if SUTANDO_HOME is set. Loaded second so it
// takes precedence over the repo .env for keys not already in process.env.
const home = process.env.SUTANDO_HOME;
if (home) {
	const homeEnv = join(expandHome(home), '.env');
	if (existsSync(homeEnv)) config({ path: homeEnv, override: true });
}
