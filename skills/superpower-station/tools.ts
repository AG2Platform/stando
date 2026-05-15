// Superpower Station — voice-callable tools for the unified catalog
// of skills (local) + cloud tools (remote via MCP gateway).
//
// Cloud routes are listed in SKILL.md alongside each tool. Auth is the
// user's Sutando Bearer token (loaded via cloud-client). Multipart
// upload (publish) uses loadCloudAuth() + raw fetch so the boundary
// header is set by the runtime.

import { createHash, randomBytes } from 'node:crypto';
import {
	existsSync,
	mkdirSync,
	readFileSync,
	rmSync,
	statSync,
	writeFileSync,
} from 'node:fs';
import { execFileSync } from 'node:child_process';
import { homedir, tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { z } from 'zod';
import type { ToolDefinition } from 'bodhi-realtime-agent';
import { cloudFetch, isCloudSignedIn, loadCloudAuth } from '../../src/cloud-client.js';

// ============================================================
// Helpers
// ============================================================

function expandHome(p: string): string {
	return p.replace(/^~/, homedir());
}

function skillsInstallDir(): string {
	const home = process.env.SUTANDO_HOME;
	if (home) return join(expandHome(home), 'cloud-skills');
	return join(homedir(), 'Library', 'Application Support', 'Sutando', 'cloud-skills');
}

function ensureSignedIn(): { ok: true } | { ok: false; error: string } {
	if (!isCloudSignedIn()) {
		return {
			ok: false,
			error: 'Not signed in to cloud. Open the Sutando menu bar → Sign in, then try again.',
		};
	}
	return { ok: true };
}

interface ResolvedItem {
	id: string;
	slug: string;
	name: string;
	kind: string;
	priceCredits: number;
	tierRequired: string;
	unitPriceCredits: number | null;
	unitLabel: string | null;
}

async function resolveItem(slug: string): Promise<
	{ ok: true; item: ResolvedItem } | { ok: false; error: string }
> {
	const res = await cloudFetch(`/api/skills/${encodeURIComponent(slug)}`);
	if (!res) return { ok: false, error: 'Not signed in.' };
	if (res.status === 404) {
		return { ok: false, error: `No item named "${slug}" in the catalog.` };
	}
	if (!res.ok) return { ok: false, error: `Lookup failed (${res.status}).` };
	const body = (await res.json()) as {
		skill: {
			id: string;
			slug: string;
			name: string;
			kind?: string;
			priceCredits: number;
			tierRequired: string;
			unitPriceCredits?: string | number | null;
			unitLabel?: string | null;
		};
	};
	const s = body.skill;
	return {
		ok: true,
		item: {
			id: s.id,
			slug: s.slug,
			name: s.name,
			kind: s.kind ?? 'skill',
			priceCredits: s.priceCredits,
			tierRequired: s.tierRequired,
			unitPriceCredits: s.unitPriceCredits != null ? Number(s.unitPriceCredits) : null,
			unitLabel: s.unitLabel ?? null,
		},
	};
}

// Parse SKILL.md frontmatter — just the `name` and `description` fields
// since those are what Anthropic requires for discovery + what our cloud
// upload route validates.
function parseSkillFrontmatter(content: string): { name?: string; description?: string } {
	const text = content.replace(/^﻿/, '');
	if (!text.startsWith('---')) return {};
	const end = text.indexOf('\n---', 3);
	if (end < 0) return {};
	const yaml = text.slice(3, end);
	const fields: Record<string, string> = {};
	for (const line of yaml.split('\n')) {
		const m = line.match(/^([a-zA-Z_]+)\s*:\s*(.+?)\s*$/);
		if (m) {
			let val = m[2];
			if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
				val = val.slice(1, -1);
			}
			fields[m[1]] = val;
		}
	}
	return { name: fields.name, description: fields.description };
}

// ============================================================
// Read-side tools (all users)
// ============================================================

export const findTool: ToolDefinition = {
	name: 'station_find',
	description:
		'Search the Superpower Station catalog (skills + cloud tools) by name or description. Use when the user says "find a skill for X", "what tools are there for Y", or "search for Z".',
	parameters: z.object({
		query: z.string().describe('Free-text query, e.g. "calendar", "deep research"'),
	}),
	execution: 'inline',
	async execute(args) {
		const { query } = args as { query: string };
		const signed = ensureSignedIn();
		if (!signed.ok) return { error: signed.error };
		const res = await cloudFetch('/api/skills/catalog');
		if (!res || !res.ok) {
			return { error: `Catalog fetch failed (${res?.status ?? 'no auth'}).` };
		}
		const body = (await res.json()) as {
			skills: Array<{
				slug: string;
				name: string;
				description: string | null;
				kind?: string;
				tierRequired: string;
				priceCredits: number;
				unitPriceCredits?: string | number | null;
				unitLabel?: string | null;
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
			items: matches.map((s) => ({
				slug: s.slug,
				name: s.name,
				kind: s.kind ?? 'skill',
				description: s.description,
				tier: s.tierRequired,
				price:
					(s.kind ?? 'skill') === 'cloud_tool'
						? `${s.unitPriceCredits ?? 0} cr / ${s.unitLabel ?? 'call'}`
						: s.priceCredits > 0
							? `${s.priceCredits} cr install`
							: 'free',
				rating: s.ratingAvg != null ? `${s.ratingAvg.toFixed(1)} (${s.ratingCount})` : null,
				installs: s.installCount,
			})),
		};
	},
};

export const installTool: ToolDefinition = {
	name: 'station_install',
	description:
		'Install a skill OR activate a cloud tool from the Superpower Station by slug. Wallet is debited if the skill is priced (cloud tools charge per-use, not at install). Mention that the voice agent must be restarted after installing a skill so the new tools load.',
	parameters: z.object({
		slug: z.string().describe('Item slug, e.g. "calendar-helper" or "deep-research"'),
	}),
	execution: 'inline',
	async execute(args) {
		const { slug } = args as { slug: string };
		const signed = ensureSignedIn();
		if (!signed.ok) return { error: signed.error };

		const resolved = await resolveItem(slug);
		if (!resolved.ok) return { error: resolved.error };
		const item = resolved.item;

		const installRes = await cloudFetch(`/api/skills/${item.id}/install`, { method: 'POST' });
		if (!installRes) return { error: 'Not signed in.' };
		if (installRes.status === 402) {
			return {
				error: `Wallet too low. Top up at https://sutando.ag2.ai/dashboard.`,
			};
		}
		if (installRes.status === 403) {
			return {
				error: `Item requires the ${item.tierRequired} tier — upgrade on the dashboard.`,
			};
		}
		if (!installRes.ok) return { error: `Install failed (${installRes.status}).` };

		const installBody = (await installRes.json()) as {
			bundleUrl: string | null;
			signingHash: string | null;
			version: string;
			deduped?: boolean;
		};

		const isCloudTool = item.kind === 'cloud_tool';

		if (installBody.deduped) {
			return {
				ok: true,
				slug,
				name: item.name,
				kind: item.kind,
				note: isCloudTool
					? 'Already activated. Use it via the MCP gateway on next refresh.'
					: 'Already installed at this version. Restart voice agent if tools are missing.',
			};
		}

		// Cloud tools without an optional client package land as a no-bundle
		// install. The install row in skill_installs is what the MCP gateway
		// uses to gate access; nothing to extract locally.
		if (!installBody.bundleUrl) {
			return {
				ok: true,
				slug,
				name: item.name,
				kind: item.kind,
				note: isCloudTool
					? 'Activated. Available via the MCP gateway on next Sutando Core refresh.'
					: 'Install logged; bundle URL not yet hosted — admin needs to upload the tarball.',
			};
		}

		// Download + verify + extract.
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
			name: item.name,
			kind: item.kind,
			version: installBody.version,
			installedTo: target,
			note: isCloudTool
				? 'Client package extracted. Tool comes online via MCP gateway on next Sutando Core refresh.'
				: 'Restart the voice agent (Sutando menu bar → Sign out + back in, or relaunch) so the new tools load.',
		};
	},
};

export const reviewTool: ToolDefinition = {
	name: 'station_review',
	description:
		'Post a 1–5 star review for a Superpower Station item you have installed. Body is optional. Use when the user says "review X" or "rate X N stars".',
	parameters: z.object({
		slug: z.string().describe('Item slug being reviewed'),
		rating: z.number().int().min(1).max(5).describe('1–5 star rating'),
		body: z.string().max(2000).optional().describe('Optional written review'),
	}),
	execution: 'inline',
	async execute(args) {
		const { slug, rating, body } = args as { slug: string; rating: number; body?: string };
		const signed = ensureSignedIn();
		if (!signed.ok) return { error: signed.error };

		const resolved = await resolveItem(slug);
		if (!resolved.ok) return { error: resolved.error };

		const res = await cloudFetch(`/api/skills/${resolved.item.id}/review`, {
			method: 'POST',
			body: JSON.stringify({ rating, body }),
		});
		if (!res) return { error: 'Not signed in.' };
		if (res.status === 403) {
			return { error: 'Install the item before reviewing it.' };
		}
		if (!res.ok) return { error: `Review failed (${res.status}).` };
		return { ok: true, slug, rating };
	},
};

export const myCollectionTool: ToolDefinition = {
	name: 'station_my_collection',
	description:
		'List the user\'s Station collection: items they have installed (default) and submissions they have published. Use when the user says "what have I installed", "show my skills", or "show my submissions".',
	parameters: z.object({
		scope: z
			.enum(['installed', 'submissions', 'all'])
			.default('all')
			.describe('Which slice of the collection to return'),
	}),
	execution: 'inline',
	async execute(args) {
		const { scope } = args as { scope: 'installed' | 'submissions' | 'all' };
		const signed = ensureSignedIn();
		if (!signed.ok) return { error: signed.error };

		const result: { installed?: unknown[]; submissions?: unknown[] } = {};

		if (scope === 'installed' || scope === 'all') {
			const res = await cloudFetch('/api/skills/installed');
			if (res && res.ok) {
				const body = (await res.json()) as {
					installed: Array<{
						slug: string;
						name: string;
						version: string;
						tierRequired: string;
					}>;
				};
				result.installed = body.installed.map((r) => ({
					slug: r.slug,
					name: r.name,
					version: r.version,
					tier: r.tierRequired,
				}));
			}
		}

		if (scope === 'submissions' || scope === 'all') {
			const res = await cloudFetch('/api/superpower/submissions');
			if (res && res.ok) {
				const body = (await res.json()) as {
					submissions: Array<{
						slug: string;
						name: string;
						version: string;
						kind: string;
						status: string;
					}>;
				};
				result.submissions = body.submissions.map((r) => ({
					slug: r.slug,
					name: r.name,
					version: r.version,
					kind: r.kind,
					status: r.status,
				}));
			}
		}

		return result;
	},
};

// ============================================================
// Publish-side tools (paid only — cloud route enforces, we just call)
// ============================================================

const SLUG_PATTERN = /^[a-z][a-z0-9-]{1,62}[a-z0-9]$/;

interface PackagedSkill {
	slug: string;
	version: string;
	name: string;
	description: string;
	manifest: Record<string, unknown>;
	tierRequired: 'free' | 'plus' | 'pro' | 'max';
	priceCredits: number;
	categories: string[];
	tarballPath: string;
	signingHash: string;
	bytes: number;
}

function packageSkillDir(localPath: string): { ok: true; pkg: PackagedSkill } | { ok: false; error: string } {
	const dir = resolve(expandHome(localPath));
	if (!existsSync(dir) || !statSync(dir).isDirectory()) {
		return { ok: false, error: `Not a directory: ${dir}` };
	}

	const skillMdPath = join(dir, 'SKILL.md');
	if (!existsSync(skillMdPath)) {
		return { ok: false, error: `Missing SKILL.md at ${skillMdPath}` };
	}
	const skillMd = readFileSync(skillMdPath, 'utf8');
	const frontmatter = parseSkillFrontmatter(skillMd);
	if (!frontmatter.name) {
		return { ok: false, error: 'SKILL.md frontmatter is missing `name`' };
	}
	if (!frontmatter.description) {
		return { ok: false, error: 'SKILL.md frontmatter is missing `description`' };
	}
	if (!SLUG_PATTERN.test(frontmatter.name)) {
		return {
			ok: false,
			error: `SKILL.md \`name\` must be lowercase-kebab (3–64 chars, a-z 0-9 -), got "${frontmatter.name}"`,
		};
	}
	if (frontmatter.description.length > 1024) {
		return {
			ok: false,
			error: `SKILL.md \`description\` exceeds 1024 chars (got ${frontmatter.description.length})`,
		};
	}

	// Optional manifest.json carries the structured publish fields.
	let manifest: Record<string, unknown> = {};
	const manifestPath = join(dir, 'manifest.json');
	if (existsSync(manifestPath)) {
		try {
			manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
		} catch (err) {
			return { ok: false, error: `manifest.json is not valid JSON: ${String(err)}` };
		}
	}
	const version = String(manifest.version ?? '0.1.0').slice(0, 32);
	const tierRequired = (
		['free', 'plus', 'pro', 'max'].includes(String(manifest.tierRequired))
			? manifest.tierRequired
			: 'free'
	) as 'free' | 'plus' | 'pro' | 'max';
	const priceCredits = Number.isFinite(manifest.priceCredits)
		? Math.max(0, Math.floor(Number(manifest.priceCredits)))
		: 0;
	const categories = Array.isArray(manifest.categories)
		? manifest.categories.map(String).slice(0, 8)
		: [];

	const slug = frontmatter.name;
	const tarballPath = join(
		tmpdir(),
		`station-publish-${slug}-${version}-${randomBytes(4).toString('hex')}.tar.gz`,
	);
	try {
		execFileSync(
			'tar',
			[
				'-czf',
				tarballPath,
				'-C',
				dirname(dir),
				'--exclude=.git',
				'--exclude=node_modules',
				'--exclude=.DS_Store',
				'--exclude=.next',
				'--exclude=__pycache__',
				dir.split('/').pop() ?? '.',
			],
			{ stdio: 'pipe' },
		);
	} catch (err) {
		return { ok: false, error: `tar failed: ${err instanceof Error ? err.message : String(err)}` };
	}

	const buf = readFileSync(tarballPath);
	const signingHash = createHash('sha256').update(buf).digest('hex');

	return {
		ok: true,
		pkg: {
			slug,
			version,
			name: String(manifest.name ?? slug),
			description: frontmatter.description,
			manifest,
			tierRequired,
			priceCredits,
			categories,
			tarballPath,
			signingHash,
			bytes: buf.length,
		},
	};
}

export const packageSkillTool: ToolDefinition = {
	name: 'station_package_skill',
	description:
		'Validate + tarball a local skill directory for the Superpower Station. The directory must contain SKILL.md with valid YAML frontmatter (name, description). Optional manifest.json supplies version, tierRequired, priceCredits, categories. Returns the tarball path + SHA-256 + computed metadata. Use before `station_publish_skill` if the user wants to inspect the package first.',
	parameters: z.object({
		local_path: z.string().describe('Absolute or ~-prefixed path to the skill directory'),
	}),
	execution: 'inline',
	async execute(args) {
		const { local_path } = args as { local_path: string };
		const signed = ensureSignedIn();
		if (!signed.ok) return { error: signed.error };
		const result = packageSkillDir(local_path);
		if (!result.ok) return { error: result.error };
		const { pkg } = result;
		return {
			ok: true,
			slug: pkg.slug,
			version: pkg.version,
			name: pkg.name,
			description: pkg.description,
			tierRequired: pkg.tierRequired,
			priceCredits: pkg.priceCredits,
			categories: pkg.categories,
			tarballPath: pkg.tarballPath,
			signingHash: pkg.signingHash,
			bytes: pkg.bytes,
		};
	},
};

export const publishSkillTool: ToolDefinition = {
	name: 'station_publish_skill',
	description:
		'Publish a skill to the Superpower Station catalog. Accepts either a local directory path (gets packaged automatically) or an already-built tarball path. Optional `metadata` overrides what is read from SKILL.md / manifest.json (e.g. bump tier or price at publish time). Paid tier only — Plus, Pro, or Max subscription required. Submission lands in `status=review` for admin approval.',
	parameters: z.object({
		local_path: z
			.string()
			.optional()
			.describe('Skill directory to package + upload. Mutually exclusive with tarball_path.'),
		tarball_path: z
			.string()
			.optional()
			.describe('Already-built .tar.gz to upload. Mutually exclusive with local_path.'),
		slug: z
			.string()
			.optional()
			.describe('Override slug from SKILL.md frontmatter. Required if tarball_path is given without metadata.'),
		name: z.string().optional(),
		description: z.string().optional(),
		version: z.string().optional(),
		tier_required: z.enum(['free', 'plus', 'pro', 'max']).optional(),
		price_credits: z.number().int().min(0).optional(),
		categories: z.array(z.string()).optional(),
	}),
	execution: 'inline',
	async execute(args) {
		const a = args as {
			local_path?: string;
			tarball_path?: string;
			slug?: string;
			name?: string;
			description?: string;
			version?: string;
			tier_required?: 'free' | 'plus' | 'pro' | 'max';
			price_credits?: number;
			categories?: string[];
		};
		const signed = ensureSignedIn();
		if (!signed.ok) return { error: signed.error };

		let tarballPath: string;
		let metadata: {
			slug: string;
			name: string;
			description: string;
			version: string;
			manifest: Record<string, unknown>;
			tierRequired: 'free' | 'plus' | 'pro' | 'max';
			priceCredits: number;
			categories: string[];
		};
		let cleanupTarball = false;

		if (a.local_path) {
			const result = packageSkillDir(a.local_path);
			if (!result.ok) return { error: result.error };
			tarballPath = result.pkg.tarballPath;
			metadata = {
				slug: a.slug ?? result.pkg.slug,
				name: a.name ?? result.pkg.name,
				description: a.description ?? result.pkg.description,
				version: a.version ?? result.pkg.version,
				manifest: result.pkg.manifest,
				tierRequired: a.tier_required ?? result.pkg.tierRequired,
				priceCredits: a.price_credits ?? result.pkg.priceCredits,
				categories: a.categories ?? result.pkg.categories,
			};
			cleanupTarball = true;
		} else if (a.tarball_path) {
			tarballPath = resolve(expandHome(a.tarball_path));
			if (!existsSync(tarballPath)) {
				return { error: `Tarball not found: ${tarballPath}` };
			}
			if (!a.slug || !a.name || !a.description || !a.version) {
				return {
					error:
						'When uploading a tarball directly, you must provide slug + name + description + version.',
				};
			}
			metadata = {
				slug: a.slug,
				name: a.name,
				description: a.description,
				version: a.version,
				manifest: {},
				tierRequired: a.tier_required ?? 'free',
				priceCredits: a.price_credits ?? 0,
				categories: a.categories ?? [],
			};
		} else {
			return { error: 'Provide either local_path or tarball_path.' };
		}

		const auth = loadCloudAuth();
		if (!auth) return { error: 'Not signed in.' };

		const buf = readFileSync(tarballPath);
		const form = new FormData();
		form.set(
			'tarball',
			new Blob([new Uint8Array(buf)], { type: 'application/gzip' }),
			`${metadata.slug}-${metadata.version}.tar.gz`,
		);
		form.set('metadata', JSON.stringify(metadata));

		const url = new URL('/api/superpower/skills/upload', auth.apiBase).toString();
		let res: Response;
		try {
			res = await fetch(url, {
				method: 'POST',
				headers: { Authorization: `Bearer ${auth.token}` },
				body: form,
			});
		} catch (err) {
			return { error: `Upload network failure: ${String(err)}` };
		} finally {
			if (cleanupTarball) {
				try {
					rmSync(tarballPath, { force: true });
				} catch {
					/* ignore */
				}
			}
		}

		const respBody = (await res.json().catch(() => ({}))) as {
			error?: string;
			detail?: string;
			id?: string;
			slug?: string;
			version?: string;
			signingHash?: string;
			status?: string;
			bytes?: number;
			resubmitted?: boolean;
		};
		if (!res.ok) {
			return {
				error: respBody.error ?? `Upload failed (${res.status})`,
				detail: respBody.detail ?? undefined,
			};
		}
		return {
			ok: true,
			id: respBody.id,
			slug: respBody.slug,
			version: respBody.version,
			signingHash: respBody.signingHash,
			status: respBody.status,
			bytes: respBody.bytes,
			resubmitted: respBody.resubmitted ?? false,
			note:
				'Submission is in admin review. You will receive a Loops email when it is approved or denied.',
		};
	},
};

export const registerCloudToolTool: ToolDefinition = {
	name: 'station_register_cloud_tool',
	description:
		'Register a cloud tool (remote MCP server) in the Superpower Station. The endpoint must be HTTPS and speak MCP. Pricing is per-call or per-unit, denominated in credits. Paid tier only.',
	parameters: z.object({
		slug: z.string().describe('Tool slug (lowercase-kebab, 3-64 chars)'),
		name: z.string(),
		description: z.string().optional(),
		version: z.string().describe('Semver-ish version string, e.g. "0.1.0"'),
		mcp_endpoint_url: z.string().describe('HTTPS URL of the upstream MCP server'),
		mcp_auth_header: z
			.string()
			.optional()
			.describe('Authorization header value we send to the upstream (e.g. "Bearer XXX")'),
		pricing_model: z.enum(['per_call', 'per_unit']),
		unit_price_credits: z.number().min(0).describe('Credits charged per call/unit'),
		unit_label: z
			.string()
			.describe('Label for the unit: "call" | "1k_tokens" | "second" | "image" | …'),
		tier_required: z.enum(['free', 'plus', 'pro', 'max']).default('free'),
		categories: z.array(z.string()).optional(),
	}),
	execution: 'inline',
	async execute(args) {
		const a = args as {
			slug: string;
			name: string;
			description?: string;
			version: string;
			mcp_endpoint_url: string;
			mcp_auth_header?: string;
			pricing_model: 'per_call' | 'per_unit';
			unit_price_credits: number;
			unit_label: string;
			tier_required?: 'free' | 'plus' | 'pro' | 'max';
			categories?: string[];
		};
		const signed = ensureSignedIn();
		if (!signed.ok) return { error: signed.error };

		const res = await cloudFetch('/api/superpower/cloud-tools/register', {
			method: 'POST',
			body: JSON.stringify({
				slug: a.slug,
				name: a.name,
				description: a.description,
				version: a.version,
				mcpEndpointUrl: a.mcp_endpoint_url,
				mcpAuthHeader: a.mcp_auth_header,
				pricingModel: a.pricing_model,
				unitPriceCredits: a.unit_price_credits,
				unitLabel: a.unit_label,
				tierRequired: a.tier_required ?? 'free',
				categories: a.categories ?? [],
			}),
		});
		if (!res) return { error: 'Not signed in.' };
		const body = (await res.json().catch(() => ({}))) as {
			error?: string;
			detail?: string;
			id?: string;
			slug?: string;
			status?: string;
			resubmitted?: boolean;
		};
		if (!res.ok) {
			return {
				error: body.error ?? `Register failed (${res.status})`,
				detail: body.detail ?? undefined,
			};
		}
		return {
			ok: true,
			id: body.id,
			slug: body.slug,
			status: body.status,
			resubmitted: body.resubmitted ?? false,
			note: 'Submission is in admin review. Once approved, the MCP gateway will introspect your endpoint and cache the tool list.',
		};
	},
};

export const resubmitTool: ToolDefinition = {
	name: 'station_resubmit_submission',
	description:
		'Re-trigger admin review on one of your existing submissions. Use after editing metadata (description, pricing) following a denial.',
	parameters: z.object({
		id: z.string().describe('Submission UUID — returned by a previous publish/register call'),
	}),
	execution: 'inline',
	async execute(args) {
		const { id } = args as { id: string };
		const signed = ensureSignedIn();
		if (!signed.ok) return { error: signed.error };

		const res = await cloudFetch(`/api/superpower/submissions/${encodeURIComponent(id)}/resubmit`, {
			method: 'POST',
		});
		if (!res) return { error: 'Not signed in.' };
		const body = (await res.json().catch(() => ({}))) as {
			ok?: boolean;
			error?: string;
			status?: string;
			noop?: boolean;
		};
		if (!res.ok) return { error: body.error ?? `Resubmit failed (${res.status})` };
		return {
			ok: true,
			id,
			status: body.status,
			noop: body.noop ?? false,
		};
	},
};

// ============================================================
// Export
// ============================================================

export const tools: ToolDefinition[] = [
	findTool,
	installTool,
	reviewTool,
	myCollectionTool,
	packageSkillTool,
	publishSkillTool,
	registerCloudToolTool,
	resubmitTool,
];
