/**
 * Cloud skill auto-installer.
 *
 * Diffs the user's server-side install list (GET /api/skills/installed)
 * against the local `cloud-skills/<slug>/` directory. For each skill that
 * the cloud says is installed but isn't on disk locally — verifies the
 * bundle SHA-256, extracts, and logs. Idempotent + safe to run on a
 * recurring loop.
 *
 * Usage:
 *     npx tsx src/cloud-skill-sync.ts        # one-shot pass
 *
 * Loop wrapper: src/cloud-skill-sync-loop.sh runs this on a slow
 * interval, started from src/startup.sh in the background.
 */

import './load-env.js';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, rmSync, writeFileSync, readdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { cloudFetch, isCloudSignedIn, recordEvent as cloudRecordEvent, recordError as cloudRecordError } from './cloud-client.js';
import { withSkillLock } from './cloud-skill-lock.js';

interface InstalledRow {
	skillId: string;
	slug: string;
	name: string;
	version: string;
	kind: string; // 'skill' | 'cloud_tool' (per Phase 1 schema)
	signingHash: string | null;
	bundleUrl: string | null;
	tierRequired: string;
	priceCredits: number;
	installedAt: string;
}

function skillsInstallDir(): string {
	const home = process.env.SUTANDO_HOME;
	if (home) return join(home.replace(/^~/, homedir()), 'cloud-skills');
	return join(homedir(), 'Library', 'Application Support', 'Sutando', 'cloud-skills');
}

async function fetchInstalled(): Promise<InstalledRow[] | null> {
	const res = await cloudFetch('/api/skills/installed');
	if (!res || !res.ok) return null;
	const body = (await res.json().catch(() => null)) as { installed: InstalledRow[] } | null;
	return body?.installed ?? null;
}

function localSkillPresent(slug: string): boolean {
	const path = join(skillsInstallDir(), slug);
	return existsSync(path) && readdirSync(path).length > 0;
}

async function downloadAndExtract(row: InstalledRow): Promise<{ ok: true } | { ok: false; reason: string }> {
	if (!row.bundleUrl) {
		return { ok: false, reason: 'bundle_url_missing' };
	}
	const bundleRes = await fetch(row.bundleUrl);
	if (!bundleRes.ok) {
		return { ok: false, reason: `download_${bundleRes.status}` };
	}
	const buf = Buffer.from(await bundleRes.arrayBuffer());
	if (row.signingHash) {
		const got = createHash('sha256').update(buf).digest('hex');
		if (got !== row.signingHash) {
			return { ok: false, reason: 'hash_mismatch' };
		}
	}
	const root = skillsInstallDir();
	mkdirSync(root, { recursive: true });
	const target = join(root, row.slug);
	const tarPath = join(root, `${row.slug}-${row.version}.tar.gz`);
	try {
		await withSkillLock(row.slug, () => {
			rmSync(target, { recursive: true, force: true });
			writeFileSync(tarPath, buf);
			mkdirSync(target, { recursive: true });
			execFileSync('tar', ['-xzf', tarPath, '-C', target, '--strip-components=1'], {
				stdio: 'pipe',
			});
		});
	} catch (err) {
		return { ok: false, reason: `extract_${err instanceof Error ? err.message.slice(0, 80) : 'unknown'}` };
	} finally {
		try {
			rmSync(tarPath, { force: true });
		} catch {
			/* ignore */
		}
	}
	return { ok: true };
}

export async function syncOnce(): Promise<void> {
	if (!isCloudSignedIn()) {
		console.log('[skill-sync] not signed in — skipping');
		return;
	}
	const installed = await fetchInstalled();
	if (!installed) {
		console.log('[skill-sync] could not fetch installed list — skipping');
		return;
	}
	if (installed.length === 0) {
		console.log('[skill-sync] no skills server-side; nothing to do');
		return;
	}

	// Cloud tools are MCP-gateway-invoked — they don't need a local
	// bundle on disk unless they ship an optional client package
	// (rare). Skip cloud_tool rows that have no bundleUrl entirely
	// instead of routing them through the missing/download path; the
	// previous behavior produced a `skill.install_failed` warn event
	// on every sync pass (every ~10 min) for every cloud-tool the
	// user activated, which polluted error_events.
	const downloadable = installed.filter(
		(row) => row.kind !== 'cloud_tool' || row.bundleUrl,
	);
	const missing = downloadable.filter((row) => !localSkillPresent(row.slug));
	if (missing.length === 0) {
		console.log(`[skill-sync] all ${downloadable.length} downloadable item(s) present locally`);
		return;
	}

	console.log(
		`[skill-sync] ${missing.length} skill(s) missing locally: ${missing.map((m) => m.slug).join(', ')}`,
	);
	let installedCount = 0;
	for (const row of missing) {
		const result = await downloadAndExtract(row);
		if (result.ok) {
			console.log(`[skill-sync] installed ${row.slug}@${row.version}`);
			installedCount += 1;
			// Auto-installs via the dashboard bypass POST /api/skills/{id}/install
			// (which is the analytics counter). Emit a skill.install usage_event
			// so marketplace install counts include this surface too.
			cloudRecordEvent({
				kind: 'skill.install',
				units: 1,
				metadata: { slug: row.slug, version: row.version, surface: 'auto_sync' },
			});
		} else {
			console.log(`[skill-sync] skip ${row.slug}: ${result.reason}`);
			cloudRecordError({
				kind: 'skill.install_failed',
				severity: 'warn',
				message: `${row.slug}: ${result.reason}`,
				metadata: { slug: row.slug, version: row.version },
			});
		}
	}
	if (installedCount > 0) {
		console.log(
			`[skill-sync] installed ${installedCount} skill(s). Restart the voice agent (or sign out + back in) so the new tools load.`,
		);
		// Touch a marker file the menu-bar app can poll, so Settings can
		// surface a "Restart voice agent to load new skills" prompt.
		try {
			const marker = join(skillsInstallDir(), '.new-installs');
			writeFileSync(marker, JSON.stringify({ ts: Date.now(), count: installedCount }));
		} catch {
			/* best-effort, ignore */
		}
	}
}

// CLI entrypoint
if (process.argv[1]?.endsWith('cloud-skill-sync.ts') || process.argv[1]?.endsWith('cloud-skill-sync.js')) {
	syncOnce().catch((err) => {
		console.error('[skill-sync] failed:', err);
		process.exit(1);
	});
}
