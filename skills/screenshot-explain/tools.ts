// Voice-callable: capture the screen + ask Gemini Vision to answer
// a question about what's visible. The killer demo for Sutando's
// local-screen + voice + cloud-gateway stack — one keystroke beats
// any web GPT's screenshot-upload flow.

import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { z } from 'zod';
import type { ToolDefinition } from 'bodhi-realtime-agent';

const CAPTURE_URL = 'http://localhost:7845/capture';
const GATEWAY_KIND_HEADER = 'X-Sutando-Kind';
const VISION_KIND = 'vision';

async function captureScreen(display?: number): Promise<
	{ ok: true; path: string } | { ok: false; error: string }
> {
	const query = display ? `?display=${display}` : '?all=true';
	try {
		const res = await fetch(`${CAPTURE_URL}${query}`);
		if (!res.ok) return { ok: false, error: `capture ${res.status}` };
		const body = (await res.json()) as { status: string; path?: string; error?: string };
		if (body.status !== 'ok' || !body.path) {
			return { ok: false, error: body.error ?? 'no path' };
		}
		return { ok: true, path: body.path };
	} catch (err) {
		return {
			ok: false,
			error: err instanceof Error ? err.message : String(err),
		};
	}
}

function resizeForVision(path: string): string {
	// sips ships with macOS — no extra deps. Resize to 800px-wide JPEG
	// to keep the upload small (Gemini Vision tokens scale with pixels,
	// and high-res screenshots add cost without information).
	const safe = path.replace(/[^a-zA-Z0-9_\-./]/g, '');
	const out = safe.endsWith('.png') ? safe.replace(/\.png$/, '-sm.jpg') : safe + '-sm.jpg';
	try {
		execFileSync('sips', ['-Z', '800', '-s', 'format', 'jpeg', safe, '--out', out], {
			timeout: 3_000,
			stdio: 'ignore',
		});
		return existsSync(out) ? out : path;
	} catch {
		return path;
	}
}

async function askGeminiAboutImage(
	imagePath: string,
	question: string,
): Promise<{ ok: true; answer: string } | { ok: false; error: string }> {
	const { gatewayBaseUrl } = await import('../../src/cloud-client.js');
	const gateway = gatewayBaseUrl('llm');
	const apiKey = process.env.GEMINI_API_KEY;
	if (!gateway && !apiKey) {
		return {
			ok: false,
			error:
				'Vision unavailable — not signed in to Sutando cloud and GEMINI_API_KEY not set. Open the Sutando menu bar → Sign in, or set GEMINI_API_KEY in your env.',
		};
	}

	const mimeType = imagePath.endsWith('.jpg') ? 'image/jpeg' : 'image/png';
	const imageData = readFileSync(imagePath).toString('base64');

	const prompt = `User question about what's currently on their screen: "${question.trim()}"

Answer based ONLY on what you can see in the screenshot. Keep the answer conversational and tight — this will be spoken aloud. If the answer is short, give it directly. If it requires steps, give 2-3 numbered steps. If the question can't be answered from the screen alone, say "I can see [what's visible] but I'd need [missing info] to answer that."`;

	const body = JSON.stringify({
		contents: [
			{
				parts: [
					{ text: prompt },
					{ inlineData: { mimeType, data: imageData } },
				],
			},
		],
		generationConfig: { maxOutputTokens: 400, temperature: 0.3 },
	});

	// Prefer gateway (signed-in users get billed via cap_group=vision).
	// Fall back to BYO key. Either way the request shape is identical.
	const headers: Record<string, string> = { 'Content-Type': 'application/json' };
	let url: string;
	if (gateway) {
		url = `${gateway}/v1beta/models/gemini-3-flash-preview:generateContent`;
		headers[GATEWAY_KIND_HEADER] = VISION_KIND;
	} else {
		url = `https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash-preview:generateContent?key=${apiKey}`;
	}

	try {
		const res = await fetch(url, { method: 'POST', headers, body });
		if (!res.ok) {
			const detail = await res.text().catch(() => '');
			return { ok: false, error: `vision ${res.status}: ${detail.slice(0, 200)}` };
		}
		const data = (await res.json()) as {
			candidates?: Array<{ content?: { parts?: Array<{ text?: string }> } }>;
		};
		const text = data.candidates?.[0]?.content?.parts?.[0]?.text?.trim();
		if (!text) return { ok: false, error: 'empty response from vision model' };
		return { ok: true, answer: text };
	} catch (err) {
		return { ok: false, error: err instanceof Error ? err.message : String(err) };
	}
}

export const screenshotExplainTool: ToolDefinition = {
	name: 'screenshot_explain',
	description:
		'Capture the screen and answer a question about what is visible. Use when the user asks "what does this mean", "explain this error", "what is this chart showing", "help me with this", "what should I do here" — any question whose answer depends on what is on the screen right now. Pass the user\'s question verbatim.',
	parameters: z.object({
		question: z
			.string()
			.min(1)
			.max(500)
			.describe('The user question, quoted verbatim when possible.'),
		display: z
			.number()
			.optional()
			.describe('Specific display to capture (1=main, 2=secondary). Omit to capture all displays.'),
	}),
	execution: 'inline',
	async execute(args) {
		const { question, display } = args as { question: string; display?: number };
		const cap = await captureScreen(display);
		if (!cap.ok) {
			return {
				error: `Could not capture screen: ${cap.error}. Is the Sutando menu bar app running?`,
			};
		}
		const resized = resizeForVision(cap.path);
		const answer = await askGeminiAboutImage(resized, question);
		if (!answer.ok) {
			return { error: answer.error };
		}
		return {
			question,
			answer: answer.answer,
			capturePath: cap.path,
		};
	},
};

export const tools: ToolDefinition[] = [screenshotExplainTool];
