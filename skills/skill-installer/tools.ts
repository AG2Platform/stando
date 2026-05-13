// Marketplace skill installer — voice-callable.
//
// Operates against the cloud `agent-universe` catalog. Three tools:
//   find_skill(query)             — search published skills
//   install_skill(slug)           — debit wallet if priced, download + verify
//   review_skill(slug, rating, body?) — post a 1–5 rating
//
// Bundle install path:
//   1. GET /api/skills/{slug}                  → resolve UUID
//   2. POST /api/skills/{id}/install (Bearer)  → debit + bundleUrl + signingHash
//   3. fetch bundleUrl (tarball)               → buffer
//   4. SHA-256 vs signingHash                  → abort on mismatch
//   5. tar -xzf into $SKILLS_DIR/<slug>/
//
// Restart caveat: voice-agent loads inline tools at startup. New tools
// won't be callable until the agent restarts.

import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { z } from 'zod';
import type { ToolDefinition } from 'bodhi-realtime-agent';
import { cloudFetch, isCloudSignedIn } from '../../src/cloud-client.js';

function skillsInstallDir(): string {
	const home = process.env.SUTANDO_HOME;
	if (home) return join(home.replace(/^~/, homedir()), 'cloud-skills');
	return join(homedir(), 'Library', 'Application Support', 'Sutando', 'cloud-skills');
}

function ensureSignedIn(): { ok: true } | { ok: false; message: string } {
	if (!isCloudSignedIn()) {
		return {
			ok: false,
			message:
				'Not signed in to cloud. Open the Sutando menu bar → Sign in, then try again.',
		};
	}
	return { ok: true };
}

async function resolveSkill(slug: string): Promise<
	| { ok: true; id: string; name: string; priceCredits: number; tierRequired: string }
	| { ok: false; message: string }
> {
	const res = await cloudFetch(`/api/skills/${encodeURIComponent(slug)}`);
	if (!res) return { ok: false, message: 'Not signed in.' };
	if (res.status === 404) return { ok: false, message: `No skill named "${slug}" in the catalog.` };
	if (!res.ok) return { ok: false, message: `Lookup failed (${res.status}).` };
	const body = (await res.json()) as {
		skill: { id: string; name: string; priceCredits: number; tierRequired: string };
	};
	return {
		ok: true,
		id: body.skill.id,
		name: body.skill.name,
		priceCredits: body.skill.priceCredits,
		tierRequired: body.skill.tierRequired,
	};
}

export const findSkillTool: ToolDefinition = {
	name: 'find_skill',
	description:
		'Search the cloud skill marketplace. Returns top matches by name + description. Use when the user says "find a skill for X" or "what skills are there for Y".',
	parameters: z.object({
		query: z.string().describe('Free-text query, e.g. "calendar", "research assistant"'),
	}),
	execution: 'inline',
	async execute(args) {
		const { query } = args as { query: string };
		const signed = ensureSignedIn();
		if (!signed.ok) return { error: signed.message };
		const res = await cloudFetch('/api/skills/catalog');
		if (!res || !res.ok) return { error: `Catalog fetch failed (${res?.status ?? 'no auth'}).` };
		const body = (await res.json()) as {
			skills: Array<{
				id: string;
				slug: string;
				name: string;
				description: string | null;
				tierRequired: string;
				priceCredits: number;
				installCount: number;
				ratingAvg: number | null;
				ratingCount: number;
			}>;
		};
		const q = query.toLowerCase();
		const matches = body.skills
			.filter(
				(s) =>
					s.name.toLowerCase().includes(q) ||
					(s.description ?? '').toLowerCase().includes(q),
			)
			.slice(0, 8);
		return {
			query,
			count: matches.length,
			skills: matches.map((s) => ({
				slug: s.slug,
				name: s.name,
				description: s.description,
				tier: s.tierRequired,
				priceCredits: s.priceCredits,
				rating: s.ratingAvg != null ? `${s.ratingAvg.toFixed(1)} (${s.ratingCount})` : null,
				installs: s.installCount,
			})),
		};
	},
};

export const installSkillTool: ToolDefinition = {
	name: 'install_skill',
	description:
		'Install a marketplace skill by slug. Wallet is debited if the skill is priced. The voice agent must be restarted to pick up the new tools (mention this to the user after a successful install).',
	parameters: z.object({
		slug: z.string().describe('Skill slug, e.g. "calendar-helper"'),
	}),
	execution: 'inline',
	async execute(args) {
		const { slug } = args as { slug: string };
		const signed = ensureSignedIn();
		if (!signed.ok) return { error: signed.message };

		const resolved = await resolveSkill(slug);
		if (!resolved.ok) return { error: resolved.message };

		const installRes = await cloudFetch(`/api/skills/${resolved.id}/install`, {
			method: 'POST',
		});
		if (!installRes) return { error: 'Not signed in.' };
		if (installRes.status === 402) {
			return {
				error: `Skill requires credits you don't have. Top up at https://sutando.ag2.ai/dashboard.`,
			};
		}
		if (installRes.status === 403) {
			return {
				error: `Skill requires the ${resolved.tierRequired} tier — upgrade on the dashboard.`,
			};
		}
		if (!installRes.ok) {
			return { error: `Install failed (${installRes.status}).` };
		}
		const installBody = (await installRes.json()) as {
			bundleUrl: string | null;
			signingHash: string | null;
			version: string;
			deduped?: boolean;
		};

		if (installBody.deduped) {
			return {
				ok: true,
				slug,
				name: resolved.name,
				note: 'Already installed at this version. Restart voice agent if tools are missing.',
			};
		}

		// Bundle url + hash are required for the actual byte download. If
		// they're not populated yet (catalog seeded before bundles uploaded)
		// log the install and surface a soft success — the install row is
		// in skill_installs and revenue is debited.
		if (!installBody.bundleUrl) {
			return {
				ok: true,
				slug,
				name: resolved.name,
				warning:
					'Install logged but bundle URL not yet hosted — admin needs to upload the tarball.',
			};
		}

		// Download + verify.
		const bundleRes = await fetch(installBody.bundleUrl);
		if (!bundleRes.ok) {
			return { error: `Bundle fetch failed (${bundleRes.status}).` };
		}
		const buf = Buffer.from(await bundleRes.arrayBuffer());
		if (installBody.signingHash) {
			const got = createHash('sha256').update(buf).digest('hex');
			if (got !== installBody.signingHash) {
				return {
					error: `Bundle hash mismatch — refusing to install. Expected ${installBody.signingHash}, got ${got}.`,
				};
			}
		}

		// Extract into $SKILLS_DIR/<slug>/. Use system tar — handles tar.gz
		// without an npm dep.
		const root = skillsInstallDir();
		mkdirSync(root, { recursive: true });
		const target = join(root, slug);
		const tarPath = join(root, `${slug}-${installBody.version}.tar.gz`);
		try {
			rmSync(target, { recursive: true, force: true });
			writeFileSync(tarPath, buf);
			mkdirSync(target, { recursive: true });
			execFileSync('tar', ['-xzf', tarPath, '-C', target, '--strip-components=1'], {
				stdio: 'pipe',
			});
		} catch (err) {
			return { error: `Extract failed: ${err instanceof Error ? err.message : String(err)}` };
		} finally {
			try {
				rmSync(tarPath, { force: true });
			} catch {
				/* ignore */
			}
		}

		return {
			ok: true,
			slug,
			name: resolved.name,
			version: installBody.version,
			installedTo: target,
			note: 'Restart the voice agent (Sutando menu bar → Sign out + back in, or relaunch the app) so the new tools load.',
		};
	},
};

export const reviewSkillTool: ToolDefinition = {
	name: 'review_skill',
	description:
		'Post a 1–5 star review for an installed skill. Body is optional. Use when the user says "review X" or "rate X N stars".',
	parameters: z.object({
		slug: z.string().describe('Skill slug being reviewed'),
		rating: z.number().int().min(1).max(5).describe('1–5 star rating'),
		body: z.string().max(2000).optional().describe('Optional written review'),
	}),
	execution: 'inline',
	async execute(args) {
		const { slug, rating, body } = args as { slug: string; rating: number; body?: string };
		const signed = ensureSignedIn();
		if (!signed.ok) return { error: signed.message };

		const resolved = await resolveSkill(slug);
		if (!resolved.ok) return { error: resolved.message };

		const res = await cloudFetch(`/api/skills/${resolved.id}/review`, {
			method: 'POST',
			body: JSON.stringify({ rating, body }),
		});
		if (!res) return { error: 'Not signed in.' };
		if (res.status === 403) {
			return { error: 'Install the skill before reviewing it.' };
		}
		if (!res.ok) {
			return { error: `Review failed (${res.status}).` };
		}
		return { ok: true, slug, rating };
	},
};

export const tools: ToolDefinition[] = [findSkillTool, installSkillTool, reviewSkillTool];

// Silence linter for fs imports that may not be hit on every code path.
void existsSync;
