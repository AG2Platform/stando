// Layered .env loader.
//
// Priority (later overrides earlier, but never overrides existing process.env):
//   1. Repo .env (dev fallback)
//   2. $SUTANDO_WORKSPACE/.env (per-machine config)
//
// Importing this module has the same shape as `import 'dotenv/config'` —
// side-effecting, no exports needed by callers.

import { config } from 'dotenv';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { resolveWorkspace } from './workspace_default.js';

const REPO_DIR = new URL('..', import.meta.url).pathname.replace(/\/$/, '');

// Step 1: repo .env (dev workflow). dotenv does not override existing
// process.env entries, so anything already set wins over the file.
const repoEnv = join(REPO_DIR, '.env');
if (existsSync(repoEnv)) config({ path: repoEnv });

// Step 2: $SUTANDO_WORKSPACE/.env. Loaded second so it takes precedence
// over the repo .env for keys not already in process.env.
const workspaceEnv = join(resolveWorkspace(), '.env');
if (existsSync(workspaceEnv)) config({ path: workspaceEnv, override: true });
