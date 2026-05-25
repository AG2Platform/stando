import { describe, it, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { OpenAIWhisperSTTProvider, buildWavHeader } from '../src/openai-whisper-stt-provider.js';

/** Create a base64 PCM chunk of given decoded byte size. */
function makeChunk(decodedBytes: number): string {
	return Buffer.alloc(decodedBytes).toString('base64');
}

describe('buildWavHeader', () => {
	it('writes a 44-byte RIFF/WAVE header for 16-bit mono 16 kHz', () => {
		const pcmBytes = 32_000; // 1 s of 16 kHz/16-bit/mono
		const h = buildWavHeader(pcmBytes, 16000, 1, 16);
		assert.equal(h.length, 44, 'header must be exactly 44 bytes');
		assert.equal(h.subarray(0, 4).toString(), 'RIFF');
		assert.equal(h.subarray(8, 12).toString(), 'WAVE');
		assert.equal(h.subarray(12, 16).toString(), 'fmt ');
		assert.equal(h.subarray(36, 40).toString(), 'data');
	});

	it('encodes RIFF chunk size as 36 + pcmByteLength (LE)', () => {
		const pcmBytes = 1024;
		const h = buildWavHeader(pcmBytes, 16000, 1, 16);
		assert.equal(h.readUInt32LE(4), 36 + pcmBytes);
	});

	it('encodes sample rate, channels, bit depth correctly', () => {
		const h = buildWavHeader(0, 24000, 1, 16);
		assert.equal(h.readUInt16LE(20), 1, 'PCM format code');
		assert.equal(h.readUInt16LE(22), 1, 'channels');
		assert.equal(h.readUInt32LE(24), 24000, 'sample rate');
		// byteRate = sampleRate * channels * bitDepth / 8
		assert.equal(h.readUInt32LE(28), 24000 * 1 * 16 / 8, 'byte rate');
		// blockAlign = channels * bitDepth / 8
		assert.equal(h.readUInt16LE(32), 1 * 16 / 8, 'block align');
		assert.equal(h.readUInt16LE(34), 16, 'bit depth');
	});

	it('encodes data chunk size as pcmByteLength (LE)', () => {
		const pcmBytes = 12345;
		const h = buildWavHeader(pcmBytes, 16000, 1, 16);
		assert.equal(h.readUInt32LE(40), pcmBytes);
	});
});

describe('OpenAIWhisperSTTProvider', () => {
	let provider: OpenAIWhisperSTTProvider;
	let originalFetch: typeof globalThis.fetch;
	let fetchCalls: Array<{ url: string; init: RequestInit }>;

	beforeEach(() => {
		provider = new OpenAIWhisperSTTProvider({ apiKey: 'test-key' });
		fetchCalls = [];
		originalFetch = globalThis.fetch;
		// Default mock: success with `{ text: 'hello world' }`
		globalThis.fetch = ((url: string, init: RequestInit) => {
			fetchCalls.push({ url, init });
			return Promise.resolve(
				new Response(JSON.stringify({ text: 'hello world' }), {
					status: 200,
					headers: { 'Content-Type': 'application/json' },
				}),
			);
		}) as typeof globalThis.fetch;
	});

	afterEach(() => {
		globalThis.fetch = originalFetch;
	});

	describe('constructor', () => {
		it('defaults model to gpt-4o-mini-transcribe', () => {
			assert.equal((provider as any).model, 'gpt-4o-mini-transcribe');
		});

		it('omits language by default (Whisper auto-detect)', () => {
			assert.equal((provider as any).language, undefined);
		});

		it('treats empty-string language as unset', () => {
			const p = new OpenAIWhisperSTTProvider({ apiKey: 'k', language: '' });
			assert.equal((p as any).language, undefined);
		});

		it('accepts a language hint when provided', () => {
			const p = new OpenAIWhisperSTTProvider({ apiKey: 'k', language: 'es' });
			assert.equal((p as any).language, 'es');
		});

		it('strips trailing slashes from baseUrl', () => {
			const p = new OpenAIWhisperSTTProvider({ apiKey: 'k', baseUrl: 'https://proxy.example/' });
			assert.equal((p as any).baseUrl, 'https://proxy.example');
		});

		it('defaults timeout to 15s', () => {
			assert.equal((provider as any).timeoutMs, 15_000);
		});
	});

	describe('configure', () => {
		it('rejects bitDepth !== 16', () => {
			assert.throws(
				() => provider.configure({ sampleRate: 16000, bitDepth: 8, channels: 1 }),
				/bitDepth=16, got 8/,
			);
		});

		it('rejects channels !== 1', () => {
			assert.throws(
				() => provider.configure({ sampleRate: 16000, bitDepth: 16, channels: 2 }),
				/channels=1, got 2/,
			);
		});

		it('stores the sample rate', () => {
			provider.configure({ sampleRate: 24000, bitDepth: 16, channels: 1 });
			assert.equal((provider as any).sampleRate, 24000);
		});
	});

	describe('feedAudio', () => {
		it('buffers chunks', () => {
			provider.feedAudio(makeChunk(1000));
			provider.feedAudio(makeChunk(2000));
			assert.equal(provider.chunkCount, 2);
			assert.equal(provider.currentBufferBytes, 3000);
		});

		it('drops oversized chunks (above 25 MB cap)', () => {
			const over = makeChunk(26 * 1024 * 1024);
			provider.feedAudio(over);
			assert.equal(provider.chunkCount, 0);
		});

		it('evicts oldest chunks when the buffer exceeds the cap', () => {
			// Push 10 chunks of 3 MB each — first one must be evicted at chunk 9.
			for (let i = 0; i < 10; i++) {
				provider.feedAudio(makeChunk(3 * 1024 * 1024));
			}
			// After 10 × 3 MB pushes (30 MB total), we should still be under 25 MB.
			assert.ok(provider.currentBufferBytes <= 25 * 1024 * 1024);
			assert.ok(provider.chunkCount < 10, `expected fewer than 10 chunks after eviction, got ${provider.chunkCount}`);
		});
	});

	describe('commit', () => {
		it('is a no-op when the buffer is empty', () => {
			provider.commit(1);
			assert.equal(fetchCalls.length, 0);
		});

		it('skips near-silent buffers (< 320 bytes)', () => {
			provider.feedAudio(makeChunk(200));
			provider.commit(1);
			// fetch shouldn't fire because pcm.length < 320
			assert.equal(fetchCalls.length, 0);
		});

		it('POSTs to /v1/audio/transcriptions with bearer auth', async () => {
			provider.feedAudio(makeChunk(32_000)); // 1s of audio
			provider.commit(1);
			// fetch is fire-and-forget; let the microtask queue drain.
			await new Promise(r => setTimeout(r, 50));
			assert.equal(fetchCalls.length, 1);
			const { url, init } = fetchCalls[0];
			assert.match(url, /\/v1\/audio\/transcriptions$/);
			assert.equal((init.headers as Record<string, string>).Authorization, 'Bearer test-key');
			assert.match((init.headers as Record<string, string>)['Content-Type'], /multipart\/form-data; boundary=/);
		});

		it('uses configured baseUrl when set', async () => {
			const p = new OpenAIWhisperSTTProvider({ apiKey: 'k', baseUrl: 'https://proxy.example' });
			p.feedAudio(makeChunk(32_000));
			p.commit(1);
			await new Promise(r => setTimeout(r, 50));
			assert.equal(fetchCalls.length, 1);
			assert.ok(fetchCalls[0].url.startsWith('https://proxy.example/v1/audio/transcriptions'));
		});

		it('emits transcript via onTranscript callback', async () => {
			let received: { text: string; turnId: number | undefined } | null = null;
			provider.onTranscript = (text, turnId) => { received = { text, turnId }; };
			provider.feedAudio(makeChunk(32_000));
			provider.commit(42);
			await new Promise(r => setTimeout(r, 50));
			assert.ok(received, 'onTranscript should fire');
			assert.equal(received!.text, 'hello world');
			assert.equal(received!.turnId, 42);
		});

		it('discards stale callbacks after stop()', async () => {
			let called = false;
			provider.onTranscript = () => { called = true; };
			provider.feedAudio(makeChunk(32_000));
			provider.commit(1);
			await provider.stop();
			await new Promise(r => setTimeout(r, 50));
			assert.equal(called, false, 'stop() must invalidate in-flight commits');
		});

		it('clears the buffer atomically on commit', () => {
			provider.feedAudio(makeChunk(32_000));
			provider.commit(1);
			assert.equal(provider.chunkCount, 0);
			assert.equal(provider.currentBufferBytes, 0);
		});

		it('includes language field when set', async () => {
			const p = new OpenAIWhisperSTTProvider({ apiKey: 'k', language: 'es' });
			p.feedAudio(makeChunk(32_000));
			p.commit(1);
			await new Promise(r => setTimeout(r, 50));
			const body = fetchCalls[0].init.body as Buffer;
			const bodyText = Buffer.isBuffer(body) ? body.toString('utf-8', 0, 600) : '';
			assert.match(bodyText, /name="language"\r\n\r\nes/);
		});

		it('omits language field when unset (Whisper auto-detect)', async () => {
			provider.feedAudio(makeChunk(32_000));
			provider.commit(1);
			await new Promise(r => setTimeout(r, 50));
			const body = fetchCalls[0].init.body as Buffer;
			const bodyText = Buffer.isBuffer(body) ? body.toString('utf-8', 0, 600) : '';
			assert.doesNotMatch(bodyText, /name="language"/);
		});
	});
});
