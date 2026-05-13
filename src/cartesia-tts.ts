/**
 * Cartesia sonic-3 TTS — generates WAV audio files from text.
 *
 * Used for non-realtime speech: task results, briefings, proactive messages.
 * Does NOT replace Gemini native audio for live voice conversation.
 *
 * Usage as module:
 *   import { generateSpeech } from './cartesia-tts.js';
 *   const wavPath = await generateSpeech('Hello world');
 *
 * Usage as CLI:
 *   npx tsx src/cartesia-tts.ts "Hello world"
 */

// `@cartesia/cartesia-js` is an optional dependency. voice-agent.ts only
// dynamically imports this file when CARTESIA_API_KEY is set, so the module
// missing is never a runtime error for Gemini-only users. We use @ts-ignore
// (not @ts-expect-error) so tsc tolerates both states:
//   - package NOT installed → ignore suppresses the "cannot find module" error
//   - package IS installed   → ignore is a no-op (@ts-expect-error would
//                                fail here with "unused directive")
// @ts-ignore -- optional dependency, resolved at runtime
import Cartesia from '@cartesia/cartesia-js';
import { writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import {
	recordEvent as cloudRecordEvent,
	gatewayBaseUrl,
} from './cloud-client.js';

const getCartesiaApiKey = () => process.env.CARTESIA_API_KEY || '';
const getCartesiaVoiceId = () => process.env.CARTESIA_VOICE_ID || 'f786b574-daa5-4673-aa0c-cbe3e8534c02';
const getWorkspace = () => process.env.WORKSPACE_DIR || process.cwd();

const SAMPLE_RATE = 24000;
const CHANNELS = 1;
const BIT_DEPTH = 16;

/** Split text into sentences for chunked TTS. Captures trailing non-punctuated text. */
export function splitSentences(text: string): string[] {
	const matched = text.match(/[^.!?]+[.!?]+/g) || [];
	const matchedText = matched.join('');
	const tail = text.slice(matchedText.length).trim();
	return matched.length > 0
		? (tail ? [...matched, tail] : matched)
		: [text];
}

/**
 * Generate speech audio from text.
 * @param text Text to speak
 * @param options.outputPath Override the output file path
 * @param options.category Organize into subdirectory (e.g., 'briefing', 'result', 'proactive')
 * @param options.label Human-readable label for the filename (e.g., 'morning-briefing')
 */
export async function generateSpeech(
	text: string,
	options: { outputPath?: string; category?: string; label?: string } = {},
): Promise<string> {
	if (!text.trim()) throw new Error('Empty text');

	// Managed-gateway path: when the user is signed in, route through
	// /api/gateway/tts/. The cloud uses our master key and bills the
	// paid tier; on 403 (Free) or 503 (gateway unconfigured) we fall
	// back to the BYOK websocket path below.
	const gateway = gatewayBaseUrl('tts');
	if (gateway) {
		try {
			return await generateSpeechViaGateway(text, options, gateway);
		} catch (err) {
			const msg = err instanceof Error ? err.message : String(err);
			// Falling back is safe for "gateway not configured" and "free
			// tier" responses. For cap-hits (402 / 429) we rethrow so the
			// caller can surface "top up" / "rate limited" rather than
			// silently burning the user's BYOK key. For any other gateway
			// failure (502, network, etc.) fall back so paid users don't
			// lose TTS to a cloud outage.
			if (/_cap_/.test(msg)) throw err;
			console.warn(`[cartesia] gateway path failed, falling back to BYOK: ${msg}`);
		}
	}

	if (!getCartesiaApiKey()) {
		throw new Error(
			'CARTESIA_API_KEY not set. Set it in .env (BYOK) or sign in to a paid Sutando tier.',
		);
	}

	// Organize: results/audio/{category}/{label}-{timestamp}.wav
	const category = options.category || 'general';
	const label = options.label || 'tts';
	const outDir = join(getWorkspace(), 'results', 'audio', category);
	mkdirSync(outDir, { recursive: true });
	const outPath = options.outputPath || join(outDir, `${label}-${Date.now()}.wav`);

	const client = new Cartesia({ apiKey: getCartesiaApiKey() });
	const ws = await client.tts.websocket();
	try {
		const ctx = ws.context({
			model_id: 'sonic-3',
			voice: { mode: 'id', id: getCartesiaVoiceId() },
			output_format: {
				container: 'raw',
				encoding: 'pcm_s16le',
				sample_rate: SAMPLE_RATE,
			},
		});

		// Push text in sentence chunks for natural prosody
		const sentences = splitSentences(text);
		for (const s of sentences) {
			await ctx.push({ transcript: s.trim() + ' ' });
		}
		await ctx.no_more_inputs();

		const chunks: Buffer[] = [];
		for await (const event of ctx.receive()) {
			if (event.type === 'chunk' && event.audio) {
				chunks.push(Buffer.isBuffer(event.audio) ? event.audio : Buffer.from(event.audio));
			} else if (event.type === 'done') {
				break;
			}
		}

		// Write WAV with header
		const pcm = Buffer.concat(chunks);
		const header = createWavHeader(pcm.length, SAMPLE_RATE, CHANNELS, BIT_DEPTH);
		writeFileSync(outPath, Buffer.concat([header, pcm]));

		// Cloud telemetry: emit one tts.cartesia event per generation. Audio
		// duration = pcm.length / (sample_rate * channels * bytes_per_sample).
		const durationSec = pcm.length / (SAMPLE_RATE * CHANNELS * (BIT_DEPTH / 8));
		if (durationSec > 0.05) {
			cloudRecordEvent({
				kind: 'tts.cartesia',
				units: durationSec,
				metadata: { model: 'sonic-3', category, label },
			});
		}
		return outPath;
	} finally {
		ws.close();
	}
}

/**
 * Cartesia generation via Sutando's HTTP gateway. Used by paid-tier
 * sign-ins. Single REST request returning raw PCM (or WAV-wrapped),
 * matching the existing on-disk format the BYOK path produces.
 *
 * Why not WebSocket? The cloud gateway proxies HTTP only — adding WS
 * proxy support is post-beta. REST is fine for our use case (non-
 * realtime TTS for task results, briefings, proactive messages).
 *
 * Cap-hit handling: 402 (insufficient credits) and 429 (burst limit)
 * are rethrown with `_cap_` in the message so the caller knows not
 * to fall back to BYOK silently.
 */
async function generateSpeechViaGateway(
	text: string,
	options: { outputPath?: string; category?: string; label?: string },
	gateway: { url: string; token: string },
): Promise<string> {
	const category = options.category || 'general';
	const label = options.label || 'tts';
	const outDir = join(getWorkspace(), 'results', 'audio', category);
	mkdirSync(outDir, { recursive: true });
	const outPath = options.outputPath || join(outDir, `${label}-${Date.now()}.wav`);

	const body = {
		model_id: 'sonic-3',
		transcript: text,
		voice: { mode: 'id', id: getCartesiaVoiceId() },
		language: 'en',
		output_format: {
			container: 'raw',
			encoding: 'pcm_s16le',
			sample_rate: SAMPLE_RATE,
		},
	};

	const res = await fetch(`${gateway.url}tts/bytes`, {
		method: 'POST',
		headers: {
			Authorization: `Bearer ${gateway.token}`,
			'Content-Type': 'application/json',
			'Cartesia-Version': '2024-06-10',
			'X-Sutando-Kind': 'tts.cartesia',
		},
		body: JSON.stringify(body),
	});

	if (!res.ok) {
		const errBody = await res.text().catch(() => '');
		if (res.status === 402) {
			throw new Error(
				`Cartesia gateway _cap_402: wallet empty — top up at sutando.ag2.ai/billing`,
			);
		}
		if (res.status === 429) {
			throw new Error(`Cartesia gateway _cap_429: rate limited — try again in a minute`);
		}
		// 403 = free tier; 503 = master key missing. Caller catches and
		// falls back to the BYOK websocket path.
		throw new Error(`Cartesia gateway ${res.status}: ${errBody.slice(0, 200)}`);
	}

	const pcm = Buffer.from(await res.arrayBuffer());
	const header = createWavHeader(pcm.length, SAMPLE_RATE, CHANNELS, BIT_DEPTH);
	writeFileSync(outPath, Buffer.concat([header, pcm]));

	const durationSec = pcm.length / (SAMPLE_RATE * CHANNELS * (BIT_DEPTH / 8));
	if (durationSec > 0.05) {
		// The gateway logs its own usage_events row for billing. We emit a
		// second one keyed `tts.cartesia` from desktop so the admin view
		// keeps tracking time-grain attribution (the gateway row is
		// count-grain only).
		cloudRecordEvent({
			kind: 'tts.cartesia',
			units: durationSec,
			metadata: { model: 'sonic-3', category, label, via: 'gateway' },
		});
	}
	return outPath;
}

export function createWavHeader(dataSize: number, sampleRate: number, channels: number, bitDepth: number): Buffer {
	const header = Buffer.alloc(44);
	header.write('RIFF', 0);
	header.writeUInt32LE(36 + dataSize, 4);
	header.write('WAVE', 8);
	header.write('fmt ', 12);
	header.writeUInt32LE(16, 16);           // fmt chunk size
	header.writeUInt16LE(1, 20);            // PCM format
	header.writeUInt16LE(channels, 22);
	header.writeUInt32LE(sampleRate, 24);
	header.writeUInt32LE(sampleRate * channels * bitDepth / 8, 28); // byte rate
	header.writeUInt16LE(channels * bitDepth / 8, 32);              // block align
	header.writeUInt16LE(bitDepth, 34);
	header.write('data', 36);
	header.writeUInt32LE(dataSize, 40);
	return header;
}

// CLI entrypoint
if (process.argv[1]?.endsWith('cartesia-tts.ts') || process.argv[1]?.endsWith('cartesia-tts.js')) {
	const text = process.argv[2];
	if (!text) {
		console.error('Usage: npx tsx src/cartesia-tts.ts "text to speak"');
		process.exit(1);
	}
	generateSpeech(text, { category: 'cli', label: 'speech' })
		.then(path => console.log(path))
		.catch(err => { console.error(err.message); process.exit(1); });
}
