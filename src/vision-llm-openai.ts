/**
 * OpenAI vision (chat-completions with image_url) — shared helper for the
 * three vision call sites in Sutando:
 *   - src/recording-tools.ts (screen-recording narration)
 *   - src/browser-tools.ts (browse + describe)
 *   - skills/screenshot-explain/tools.ts (one-shot screen Q&A)
 *
 * Single POST to /v1/chat/completions; no SDK dependency. Mirrors the same
 * "send base64 image + prompt → get text" contract that each site already
 * uses against Gemini's generateContent.
 *
 * Defaults to gpt-4.1-mini (good vision quality, low cost for 800-px-wide
 * screenshots). Override via VISION_OPENAI_MODEL.
 */

export interface AnalyzeImageOpenAIOpts {
	apiKey: string;
	base64Image: string;
	mimeType: 'image/png' | 'image/jpeg' | 'image/webp';
	prompt: string;
	model?: string;
	maxOutputTokens?: number;
	temperature?: number;
}

export type AnalyzeImageOpenAIResult =
	| { ok: true; text: string }
	| { ok: false; error: string };

export async function analyzeImageOpenAI(opts: AnalyzeImageOpenAIOpts): Promise<AnalyzeImageOpenAIResult> {
	const model = opts.model || process.env.VISION_OPENAI_MODEL || 'gpt-4.1-mini';
	const body = JSON.stringify({
		model,
		messages: [
			{
				role: 'user',
				content: [
					{ type: 'text', text: opts.prompt },
					{
						type: 'image_url',
						image_url: { url: `data:${opts.mimeType};base64,${opts.base64Image}` },
					},
				],
			},
		],
		max_tokens: opts.maxOutputTokens ?? 400,
		temperature: opts.temperature ?? 0.3,
	});

	try {
		const res = await fetch('https://api.openai.com/v1/chat/completions', {
			method: 'POST',
			headers: {
				'Content-Type': 'application/json',
				Authorization: `Bearer ${opts.apiKey}`,
			},
			body,
		});
		if (!res.ok) {
			const detail = await res.text().catch(() => '');
			return { ok: false, error: `OpenAI vision ${res.status}: ${detail.slice(0, 200)}` };
		}
		const data = (await res.json()) as {
			choices?: Array<{ message?: { content?: string } }>;
		};
		const text = data.choices?.[0]?.message?.content?.trim();
		if (!text) return { ok: false, error: 'empty response from OpenAI vision' };
		return { ok: true, text };
	} catch (err) {
		return { ok: false, error: err instanceof Error ? err.message : String(err) };
	}
}

/** Read VISION_PROVIDER env. Default 'gemini' (no behavior change for existing
 * setups); set to 'openai' to route vision calls through gpt-4.1-mini. */
export function visionProvider(): 'openai' | 'gemini' {
	const v = (process.env.VISION_PROVIDER || 'gemini').toLowerCase();
	if (v !== 'openai' && v !== 'gemini') {
		console.error(`[vision] VISION_PROVIDER must be 'openai' or 'gemini' (got "${v}") — defaulting to gemini`);
		return 'gemini';
	}
	return v;
}
