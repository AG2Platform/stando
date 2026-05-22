/**
 * Cartesia ink-whisper STT provider — drop-in replacement for GeminiBatchSTTProvider.
 *
 * Implements bodhi-realtime-agent's STTProvider interface using the Cartesia
 * bytes endpoint (batch transcription). Audio is buffered via feedAudio(),
 * then transcribed when commit() is called.
 *
 * Optimized for: variable-length chunks, background noise, telephony artifacts,
 * accents, and domain-specific terminology.
 */

import type { STTProvider, STTAudioConfig } from 'bodhi-realtime-agent';

const ts = () => new Date().toLocaleTimeString('en-US', { hour12: false });
const MAX_BUFFER_BYTES = 25 * 1024 * 1024; // 25 MB safety cap

/**
 * Whisper-family STT models (including Cartesia's `ink-whisper`) emit
 * bracketed pseudo-tokens and recurring scraped-subtitle phrases when
 * fed near-silent or non-speech audio. They are not actual user
 * utterances — they're training-data artifacts that leak through.
 *
 * Letting them reach the LLM causes two problems:
 *   1. Gemini treats them as a turn and may echo the literal token
 *      back as a reply (observed: `[BLANK_AUDIO]` showing up in the
 *      assistant transcript).
 *   2. Even when Gemini ignores the content, the empty "user turn"
 *      can trigger spurious tool calls or filler ACKs.
 *
 * The patterns cover the common Whisper hallucinations documented
 * across the openai/whisper issue tracker:
 *   - `[BLANK_AUDIO]`, `[blank_audio]`, `[ blank audio ]`
 *   - `[MUSIC]`, `[Music]`, `[♪ music ♪]`
 *   - `[INAUDIBLE]`, `[silence]`, `(silence)`
 *   - `[LAUGHTER]`, `[APPLAUSE]`, `[NOISE]`, `[BACKGROUND NOISE]`
 *   - "Thanks for watching!" / "Subtitles by ..." subtitle credits
 */
const WHISPER_NOISE_RE = /^(?:\s*[\[(♪]\s*(?:blank[\s_]?audio|music|inaudible|silence|noise|background\s*noise|laughter|applause|cough|sigh|breath(?:ing)?|sound\s*effect|footsteps?|crying|whispering)\s*[\])♪]\s*\.?\s*|thanks?\s+for\s+watching[!.\s]*|subtitles?\s+by\s+.*|please\s+subscribe[!.\s]*)$/i;

/**
 * True when `text` is a Whisper-style transcription hallucination
 * rather than a real user utterance. Exported so unit tests can
 * exercise the pattern list directly.
 */
export function isWhisperHallucination(text: string): boolean {
	const trimmed = text.trim();
	if (trimmed.length === 0) return true;
	return WHISPER_NOISE_RE.test(trimmed);
}

export interface CartesiaSTTConfig {
	apiKey: string;
	model?: string;
	/** Cartesia API version header. */
	apiVersion?: string;
}

export class CartesiaSTTProvider implements STTProvider {
	private readonly apiKey: string;
	private readonly model: string;
	private readonly apiVersion: string;
	private sampleRate = 16000;
	private audioChunks: { data: string; bytes: number }[] = [];
	private bufferBytes = 0;
	private wasInterrupted = false;
	private stopped = false;
	private generation = 0; // incremented on stop() to discard stale callbacks

	onTranscript?: (text: string, turnId: number | undefined) => void;
	onPartialTranscript?: (text: string) => void;

	constructor(config: CartesiaSTTConfig) {
		this.apiKey = config.apiKey;
		this.model = config.model || 'ink-whisper';
		this.apiVersion = config.apiVersion || '2025-04-16';
	}

	configure(audio: STTAudioConfig): void {
		if (audio.bitDepth !== 16) {
			throw new Error(`CartesiaSTTProvider requires bitDepth=16, got ${audio.bitDepth}`);
		}
		if (audio.channels !== 1) {
			throw new Error(`CartesiaSTTProvider requires channels=1, got ${audio.channels}`);
		}
		this.sampleRate = audio.sampleRate;
	}

	async start(): Promise<void> {
		this.stopped = false;
		console.log(`${ts()} [CartesiaSTT] Started (model: ${this.model}, sampleRate: ${this.sampleRate})`);
	}

	async stop(): Promise<void> {
		this.stopped = true;
		this.generation++;
		this.audioChunks = [];
		this.bufferBytes = 0;
		this.wasInterrupted = false;
		console.log(`${ts()} [CartesiaSTT] Stopped`);
	}

	feedAudio(base64Pcm: string): void {
		const chunkBytes = Buffer.byteLength(base64Pcm, 'base64');
		if (chunkBytes > MAX_BUFFER_BYTES) {
			console.warn(`${ts()} [CartesiaSTT] Dropping oversized chunk (${chunkBytes} bytes > ${MAX_BUFFER_BYTES} cap)`);
			return;
		}
		// FIFO eviction: drop oldest chunks to make room (preserves most recent speech)
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

		// Concatenate all buffered PCM chunks
		const allAudio = Buffer.concat(chunks.map(c => Buffer.from(c.data, 'base64')));

		if (allAudio.length < 320) return; // skip near-empty buffers (< 10ms at 16kHz)

		// Capture generation so we can discard results from a stale session
		const gen = this.generation;

		fetch('https://api.cartesia.ai/stt/bytes', {
			method: 'POST',
			headers: {
				'X-API-Key': this.apiKey,
				'Cartesia-Version': this.apiVersion,
				'Content-Type': 'audio/pcm',
				'Sample-Rate': String(this.sampleRate),
				'Encoding': 'pcm_s16le',
				'Language': 'en',
				'Model-Id': this.model,
			},
			body: allAudio,
		})
			.then(async res => {
				if (!res.ok) {
					const body = await res.text().catch(() => '');
					throw new Error(`HTTP ${res.status}: ${body.slice(0, 200)}`);
				}
				return res.json();
			})
			.then((data: any) => {
				if (this.generation !== gen) return; // stale — session was stopped+restarted
				const text = data?.text?.trim();
				if (!text) return;
				if (isWhisperHallucination(text)) {
					console.log(`${ts()} [CartesiaSTT] Dropped Whisper artifact (turn ${turnId}): "${text.slice(0, 80)}"`);
					return;
				}
				if (this.onTranscript) {
					console.log(`${ts()} [CartesiaSTT] Transcript (turn ${turnId}): "${text.slice(0, 80)}${text.length > 80 ? '...' : ''}"`);
					this.onTranscript(text, turnId);
				}
			})
			.catch(err => {
				console.error(`${ts()} [CartesiaSTT] Transcription error:`, err.message);
			});
	}

	handleInterrupted(): void {
		this.wasInterrupted = true;
		// Preserve buffer — audio will be included in next commit()
	}

	handleTurnComplete(): void {
		if (!this.wasInterrupted) {
			this.audioChunks = [];
			this.bufferBytes = 0;
		}
		this.wasInterrupted = false;
	}

	/** Exposed for testing — current buffer byte count. */
	get currentBufferBytes(): number { return this.bufferBytes; }
	get chunkCount(): number { return this.audioChunks.length; }
}
