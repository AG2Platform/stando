import { homedir } from 'node:os';
import { join } from 'node:path';

export function resolveWorkspace(): string {
	const env = process.env.SUTANDO_WORKSPACE?.trim();
	if (env) return env.replace(/^~/, homedir());
	return join(homedir(), '.sutando', 'workspace');
}
