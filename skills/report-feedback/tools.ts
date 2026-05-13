// Submit feedback to the cloud /api/feedback endpoint. Voice-callable.
//
// Pairs with /admin/feedback in agent-universe for triage. Captures
// app version automatically; screenshot capture is opt-in (avoid
// surprising the user with snaps for "feature request" calls).

import { readFileSync, existsSync } from 'node:fs';
import { z } from 'zod';
import type { ToolDefinition } from 'bodhi-realtime-agent';
import { cloudFetch, isCloudSignedIn } from '../../src/cloud-client.js';

function readAppVersion(): string {
	try {
		const pkgPath = new URL('../../package.json', import.meta.url).pathname;
		if (existsSync(pkgPath)) {
			const { version } = JSON.parse(readFileSync(pkgPath, 'utf-8')) as { version?: string };
			if (version) return version;
		}
	} catch {
		/* fall through */
	}
	return '0.0.0';
}

async function captureScreenPath(): Promise<string | null> {
	try {
		const res = await fetch('http://localhost:7845/capture');
		if (!res.ok) return null;
		const body = (await res.json()) as { path?: string };
		return body.path ?? null;
	} catch {
		return null;
	}
}

export const reportFeedbackTool: ToolDefinition = {
	name: 'report_feedback',
	description:
		"Send a bug report, feature request, or other note to the Sutando cloud. Use when the user says 'report a bug', 'send feedback', 'request a feature', or describes something that should be tracked.",
	parameters: z.object({
		kind: z.enum(['bug', 'feature', 'other']),
		title: z.string().min(1).max(200).describe('Short summary, < 10 words.'),
		body: z.string().max(8000).optional().describe('Longer body — what happened, expected behaviour, repro steps.'),
		severity: z.enum(['low', 'medium', 'high', 'critical']).default('medium'),
		withScreen: z
			.boolean()
			.default(false)
			.describe('Attach a screenshot of the current screen (for visual bugs).'),
	}),
	execution: 'inline',
	async execute(args) {
		const { kind, title, body, severity, withScreen } = args as {
			kind: 'bug' | 'feature' | 'other';
			title: string;
			body?: string;
			severity: 'low' | 'medium' | 'high' | 'critical';
			withScreen: boolean;
		};
		if (!isCloudSignedIn()) {
			return {
				error:
					"Can't submit feedback while signed out of cloud. Open the Sutando menu bar → Sign in.",
			};
		}

		const context: Record<string, unknown> = {
			source: 'voice',
		};
		if (withScreen) {
			const screenPath = await captureScreenPath();
			if (screenPath) context.last_screen = screenPath;
		}

		const res = await cloudFetch('/api/feedback', {
			method: 'POST',
			body: JSON.stringify({
				kind,
				severity,
				title,
				body,
				context,
				appVersion: readAppVersion(),
			}),
		});
		if (!res) return { error: 'Not signed in.' };
		if (!res.ok) {
			return { error: `Feedback submit failed (${res.status}).` };
		}
		const replyBody = (await res.json()) as { id?: string };
		return {
			ok: true,
			id: replyBody.id,
			message: 'Feedback recorded. Track it on https://sutando.ag2.ai/admin/feedback (admin) or the user dashboard.',
		};
	},
};

export const tools: ToolDefinition[] = [reportFeedbackTool];
