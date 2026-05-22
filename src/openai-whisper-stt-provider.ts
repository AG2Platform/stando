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
 */

import type { STTProvider, STTAudioConfig } from 'bodhi-realtime-agent';

const ts = () => new Date().toLocaleTimeString('en-US', { hour12: false });
const MAX_BUFFER_BYTES = 25 * 1024 * 1024; // 25 MB safety cap (OpenAI hard limit)

export interface OpenAIWhisperSTTConfig {
	apiKey: string;
	/** Transcription model id (default: 'gpt-4o-mini-transcribe'). */
	model?: string;
	/** BCP-47 language hint (default: 'en'). */
	language?: string;
}

function buildWavHeader(pcmByteLength: number, sampleRate: number, channels: number, bitDepth: number): Buffer {
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
	private readonly language: string;
	private sampleRate = 16000;
	private channels = 1;
	private bitDepth = 16;
	private audioChunks: { data: string; bytes: number }[] = [];
	private bufferBytes = 0;
	private wasInterrupted = false;
	private stopped = false;
	private generation = 0;

	onTranscript?: (text: string, turnId: number | undefined) => void;
	onPartialTranscript?: (text: string) => void;

	constructor(config: OpenAIWhisperSTTConfig) {
		this.apiKey = config.apiKey;
		this.model = config.model || 'gpt-4o-mini-transcribe';
		this.language = config.language || 'en';
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
		console.log(`${ts()} [WhisperSTT] Started (model: ${this.model}, sampleRate: ${this.sampleRate})`);
	}

	async stop(): Promise<void> {
		this.stopped = true;
		this.generation++;
		this.audioChunks = [];
		this.bufferBytes = 0;
		this.wasInterrupted = false;
		console.log(`${ts()} [WhisperSTT] Stopped`);
	}

	feedAudio(base64Pcm: string): void {
		if (this.stopped) return;
		const chunkBytes = Buffer.byteLength(base64Pcm, 'base64');
		if (chunkBytes > MAX_BUFFER_BYTES) {
			console.warn(`${ts()} [WhisperSTT] Dropping oversized chunk (${chunkBytes} > ${MAX_BUFFER_BYTES})`);
			return;
		}
		while (this.bufferBytes + chunkBytes > MAX_BUFFER_BYTES && this.audioChunks.length > 0) {
			const dropped = this.audioChunks.shift();
			if (dropped) this.bufferBytes -= dropped.bytes;
		}
		this.audioChunks.push({ data: base64Pcm, bytes: chunkBytes });
		this.bufferBytes += chunkBytes;
	}

	commit(turnId: number): void {
		if (this.audioChunks.length === 0) return;

		const chunks = this.audioChunks;
		this.audioChunks = [];
		this.bufferBytes = 0;

		const pcm = Buffer.concat(chunks.map(c => Buffer.from(c.data, 'base64')));
		if (pcm.length < 320) return; // < 10ms at 16kHz — silence

		const wav = Buffer.concat([
			buildWavHeader(pcm.length, this.sampleRate, this.channels, this.bitDepth),
			pcm,
		]);

		const gen = this.generation;
		const boundary = `----sutando-whisper-${Date.now()}-${turnId}`;
		const enc = (s: string) => Buffer.from(s, 'utf-8');
		const body = Buffer.concat([
			enc(`--${boundary}\r\nContent-Disposition: form-data; name="model"\r\n\r\n${this.model}\r\n`),
			enc(`--${boundary}\r\nContent-Disposition: form-data; name="language"\r\n\r\n${this.language}\r\n`),
			enc(`--${boundary}\r\nContent-Disposition: form-data; name="response_format"\r\n\r\njson\r\n`),
			enc(`--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="audio.wav"\r\nContent-Type: audio/wav\r\n\r\n`),
			wav,
			enc(`\r\n--${boundary}--\r\n`),
		]);

		fetch('https://api.openai.com/v1/audio/transcriptions', {
			method: 'POST',
			headers: {
				'Authorization': `Bearer ${this.apiKey}`,
				'Content-Type': `multipart/form-data; boundary=${boundary}`,
			},
			body,
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
				console.error(`${ts()} [WhisperSTT] Transcription error:`, err instanceof Error ? err.message : err);
			});
	}

	handleInterrupted(): void {
		this.wasInterrupted = true;
	}

	handleTurnComplete(): void {
		if (!this.wasInterrupted) {
			this.audioChunks = [];
			this.bufferBytes = 0;
		}
		this.wasInterrupted = false;
	}

	get currentBufferBytes(): number { return this.bufferBytes; }
	get chunkCount(): number { return this.audioChunks.length; }
}
