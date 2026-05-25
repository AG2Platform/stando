/**
 * OpenAI Whisper STT provider — implements bodhi's STTProvider interface
 * using OpenAI's batch transcription endpoint (/v1/audio/transcriptions).
 *
 * Audio is buffered via feedAudio(), wrapped as a WAV container on commit(),
 * and POSTed as multipart/form-data. OpenAI doesn't expose a streaming
 * transcription API outside the Realtime session, so this is batch-only —
 * a transcript lands shortly after the user stops talking.
 *
 * Model defaults to 'gpt-4o-mini-transcribe' (faster, cheaper than whisper-1
 * for short-utterance voice-agent traffic). Set OPENAI_STT_MODEL to override.
 *
 * For LiteLLM / OpenRouter / Azure-OpenAI users, set OPENAI_BASE_URL to
 * redirect the API host (must include scheme, no trailing slash).
 */

import { randomBytes } from 'node:crypto';
import type { STTProvider, STTAudioConfig } from 'bodhi-realtime-agent';

const ts = () => new Date().toLocaleTimeString('en-US', { hour12: false });
const MAX_BUFFER_BYTES = 25 * 1024 * 1024; // 25 MB safety cap (OpenAI hard limit)
const DEFAULT_TIMEOUT_MS = 15_000;

export interface OpenAIWhisperSTTConfig {
	apiKey: string;
	/** Transcription model id (default: 'gpt-4o-mini-transcribe'). */
	model?: string;
	/** BCP-47 language hint. When omitted, Whisper auto-detects (recommended
	 *  for multilingual users). Caller can pin via the STT_LANGUAGE env. */
	language?: string;
	/** API host override (default: 'https://api.openai.com'). */
	baseUrl?: string;
	/** Request timeout in ms (default: 15000). */
	timeoutMs?: number;
}

export function buildWavHeader(pcmByteLength: number, sampleRate: number, channels: number, bitDepth: number): Buffer {
	const byteRate = (sampleRate * channels * bitDepth) / 8;
	const blockAlign = (channels * bitDepth) / 8;
	const header = Buffer.alloc(44);
	header.write('RIFF', 0);
	header.writeUInt32LE(36 + pcmByteLength, 4);
	header.write('WAVE', 8);
	header.write('fmt ', 12);
	header.writeUInt32LE(16, 16); // fmt chunk size
	header.writeUInt16LE(1, 20);  // PCM format
	header.writeUInt16LE(channels, 22);
	header.writeUInt32LE(sampleRate, 24);
	header.writeUInt32LE(byteRate, 28);
	header.writeUInt16LE(blockAlign, 32);
	header.writeUInt16LE(bitDepth, 34);
	header.write('data', 36);
	header.writeUInt32LE(pcmByteLength, 40);
	return header;
}

export class OpenAIWhisperSTTProvider implements STTProvider {
	private readonly apiKey: string;
	private readonly model: string;
	private readonly language: string | undefined;
	private readonly baseUrl: string;
	private readonly timeoutMs: number;
	private sampleRate = 16000;
	private channels = 1;
	private bitDepth = 16;
	private audioChunks: { data: string; bytes: number }[] = [];
	private bufferBytes = 0;
	private wasInterrupted = false;
	private stopped = false;
	private generation = 0;
	private evictionLoggedForTurn = false;

	onTranscript?: (text: string, turnId: number | undefined) => void;
	onPartialTranscript?: (text: string) => void;

	constructor(config: OpenAIWhisperSTTConfig) {
		this.apiKey = config.apiKey;
		this.model = config.model || 'gpt-4o-mini-transcribe';
		// Omit language entirely when unset — Whisper auto-detects, which is
		// the right default for a multilingual user. Empty string is treated
		// as "unset" too.
		this.language = config.language && config.language.length > 0 ? config.language : undefined;
		this.baseUrl = (config.baseUrl || 'https://api.openai.com').replace(/\/+$/, '');
		this.timeoutMs = config.timeoutMs ?? DEFAULT_TIMEOUT_MS;
	}

	configure(audio: STTAudioConfig): void {
		if (audio.bitDepth !== 16) {
			throw new Error(`OpenAIWhisperSTTProvider requires bitDepth=16, got ${audio.bitDepth}`);
		}
		if (audio.channels !== 1) {
			throw new Error(`OpenAIWhisperSTTProvider requires channels=1, got ${audio.channels}`);
		}
		this.sampleRate = audio.sampleRate;
		this.channels = audio.channels;
		this.bitDepth = audio.bitDepth;
	}

	async start(): Promise<void> {
		this.stopped = false;
		console.log(`${ts()} [WhisperSTT] Started (model: ${this.model}, sampleRate: ${this.sampleRate}, lang: ${this.language ?? 'auto'})`);
	}

	async stop(): Promise<void> {
		this.stopped = true;
		this.generation++;
		this.audioChunks = [];
		this.bufferBytes = 0;
		this.wasInterrupted = false;
		this.evictionLoggedForTurn = false;
		console.log(`${ts()} [WhisperSTT] Stopped`);
	}

	feedAudio(base64Pcm: string): void {
		if (this.stopped) return;
		const chunkBytes = Buffer.byteLength(base64Pcm, 'base64');
		if (chunkBytes > MAX_BUFFER_BYTES) {
			console.warn(`${ts()} [WhisperSTT] Dropping oversized chunk (${chunkBytes} > ${MAX_BUFFER_BYTES})`);
			return;
		}
		// FIFO eviction at the 25 MB cap. ~13 minutes at 16 kHz/16-bit mono.
		// When we evict, the *start* of the utterance gets dropped — prefix
		// words go missing from the eventual transcript. Log once per turn so
		// post-mortems can find the truncation; the actual onTranscript will
		// still fire on whatever audio survives.
		while (this.bufferBytes + chunkBytes > MAX_BUFFER_BYTES && this.audioChunks.length > 0) {
			const dropped = this.audioChunks.shift();
			if (dropped) this.bufferBytes -= dropped.bytes;
			if (!this.evictionLoggedForTurn) {
				console.warn(`${ts()} [WhisperSTT] Buffer cap (${MAX_BUFFER_BYTES} bytes) reached — evicting oldest audio. Earliest words may be missing from transcript.`);
				this.evictionLoggedForTurn = true;
			}
		}
		this.audioChunks.push({ data: base64Pcm, bytes: chunkBytes });
		this.bufferBytes += chunkBytes;
	}

	commit(turnId: number): void {
		if (this.audioChunks.length === 0) return;

		const chunks = this.audioChunks;
		this.audioChunks = [];
		this.bufferBytes = 0;
		// Reset for the next turn's buffer activity.
		this.evictionLoggedForTurn = false;

		const pcm = Buffer.concat(chunks.map(c => Buffer.from(c.data, 'base64')));
		if (pcm.length < 320) return; // < 10ms at 16kHz — silence

		const wav = Buffer.concat([
			buildWavHeader(pcm.length, this.sampleRate, this.channels, this.bitDepth),
			pcm,
		]);

		const gen = this.generation;
		// Random boundary token — avoids the (already vanishingly small) chance
		// of a collision with audio bytes that happen to match a time-based marker.
		const boundary = `----sutando-whisper-${randomBytes(16).toString('hex')}`;
		const enc = (s: string) => Buffer.from(s, 'utf-8');
		const parts: Buffer[] = [
			enc(`--${boundary}\r\nContent-Disposition: form-data; name="model"\r\n\r\n${this.model}\r\n`),
		];
		if (this.language) {
			parts.push(enc(`--${boundary}\r\nContent-Disposition: form-data; name="language"\r\n\r\n${this.language}\r\n`));
		}
		parts.push(
			enc(`--${boundary}\r\nContent-Disposition: form-data; name="response_format"\r\n\r\njson\r\n`),
			enc(`--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="audio.wav"\r\nContent-Type: audio/wav\r\n\r\n`),
			wav,
			enc(`\r\n--${boundary}--\r\n`),
		);
		const body = Buffer.concat(parts);

		fetch(`${this.baseUrl}/v1/audio/transcriptions`, {
			method: 'POST',
			headers: {
				'Authorization': `Bearer ${this.apiKey}`,
				'Content-Type': `multipart/form-data; boundary=${boundary}`,
			},
			body,
			signal: AbortSignal.timeout(this.timeoutMs),
		})
			.then(async res => {
				if (!res.ok) {
					const t = await res.text().catch(() => '');
					throw new Error(`HTTP ${res.status}: ${t.slice(0, 200)}`);
				}
				return res.json();
			})
			.then((data: unknown) => {
				if (this.generation !== gen) return;
				const text = (data as { text?: string })?.text?.trim();
				if (text && this.onTranscript) {
					console.log(`${ts()} [WhisperSTT] Transcript (turn ${turnId}): "${text.slice(0, 80)}${text.length > 80 ? '...' : ''}"`);
					this.onTranscript(text, turnId);
				}
			})
			.catch(err => {
				const msg = err instanceof Error ? err.message : String(err);
				const isAbort = err instanceof Error && (err.name === 'TimeoutError' || err.name === 'AbortError');
				console.error(`${ts()} [WhisperSTT] Transcription error (turn ${turnId}${isAbort ? `, timeout ${this.timeoutMs}ms` : ''}): ${msg}`);
			});
	}

	handleInterrupted(): void {
		this.wasInterrupted = true;
	}

	handleTurnComplete(): void {
		if (!this.wasInterrupted) {
			this.audioChunks = [];
			this.bufferBytes = 0;
			this.evictionLoggedForTurn = false;
		}
		this.wasInterrupted = false;
	}

	get currentBufferBytes(): number { return this.bufferBytes; }
	get chunkCount(): number { return this.audioChunks.length; }
}
