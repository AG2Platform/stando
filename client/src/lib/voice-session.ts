/**
 * Framework-free voice session for the Sutando conversation page.
 *
 * Owns the lifecycle of:
 *   - WebSocket to voice-agent.ts (binary frames = PCM audio).
 *   - AudioContext + mic capture (ScriptProcessor downsampled to 16 kHz int16).
 *   - Gapless playback scheduling for assistant audio (24 kHz int16).
 *
 * Ported from src/web-client-html.ts's connectWs() + startMic() + playChunk().
 * Kept framework-free so React, Solid, or a future Swift WKWebView wrapper can
 * all wire it up without dragging in a renderer. The React adapter lives in
 * src/hooks/useVoiceSession.ts.
 *
 * Out of scope for PR-C (handled in later PRs):
 *   - Transcript / turn.end / turn.interrupted UI events (just logged here).
 *   - gui.update payloads (images, videos, decision options).
 *   - Chrome SpeechRecognition fallback.
 *   - Speaking detection (avatar animation).
 */

import { checkMicAvailability, downsample, float32ToInt16, int16ToFloat32 } from './audio';

export type VoiceSessionStatus =
	| 'idle'
	| 'connecting'
	| 'requesting-mic'
	| 'live'
	| 'error'
	| 'closed';

export interface VoiceSessionState {
	status: VoiceSessionStatus;
	muted: boolean;
	errorMessage: string | null;
	bytesSent: number;
	bytesRecv: number;
}

export interface VoiceSessionEvents {
	onStateChange: (next: VoiceSessionState) => void;
	onLog: (message: string, level: 'info' | 'warn' | 'error') => void;
}

const DEFAULT_INPUT_RATE = 16_000;
const DEFAULT_OUTPUT_RATE = 24_000;
const CAPTURE_BUF = 2048;

export class VoiceSession {
	private state: VoiceSessionState = {
		status: 'idle',
		muted: false,
		errorMessage: null,
		bytesSent: 0,
		bytesRecv: 0,
	};

	private ws: WebSocket | null = null;
	private audioCtx: AudioContext | null = null;
	private micStream: MediaStream | null = null;
	private processor: ScriptProcessorNode | null = null;
	private inputRate = DEFAULT_INPUT_RATE;
	private outputRate = DEFAULT_OUTPUT_RATE;
	private nextPlayTime = 0;
	private activeSources: AudioBufferSourceNode[] = [];

	// Parameter properties (`constructor(private events: …)`) are disallowed
	// when erasableSyntaxOnly is on in tsconfig.app.json — they emit runtime
	// assignments and TS 5.6 enforces "the source has the same shape after
	// type-stripping". Hold the events object in a normal field instead.
	private events: VoiceSessionEvents;

	constructor(events: VoiceSessionEvents) {
		this.events = events;
	}

	getState(): VoiceSessionState {
		return this.state;
	}

	async connect(wsUrl: string): Promise<void> {
		if (this.state.status !== 'idle' && this.state.status !== 'closed' && this.state.status !== 'error') {
			this.events.onLog(`connect() ignored — session in ${this.state.status}`, 'warn');
			return;
		}
		this.updateState({ status: 'connecting', errorMessage: null });

		try {
			this.audioCtx = new AudioContext();
			this.events.onLog(`AudioContext sampleRate=${this.audioCtx.sampleRate}Hz`, 'info');
		} catch (err) {
			this.fail(`Failed to create AudioContext: ${(err as Error).message}`);
			return;
		}

		const ws = new WebSocket(wsUrl);
		ws.binaryType = 'arraybuffer';
		this.ws = ws;
		ws.onopen = () => void this.onWsOpen();
		ws.onmessage = (ev) => this.onWsMessage(ev);
		ws.onerror = () => this.events.onLog('WebSocket error', 'error');
		ws.onclose = () => this.handleClose();
	}

	disconnect(): void {
		if (this.ws && this.ws.readyState === WebSocket.OPEN) {
			this.ws.close();
		}
		this.cleanup();
		this.updateState({ status: 'closed' });
	}

	toggleMute(): void {
		const next = !this.state.muted;
		this.setMuted(next);
	}

	setMuted(muted: boolean): void {
		if (this.micStream) {
			this.micStream.getAudioTracks().forEach((t) => (t.enabled = !muted));
		}
		this.updateState({ muted });
	}

	private async onWsOpen() {
		this.events.onLog('WebSocket connected', 'info');
		this.updateState({ status: 'requesting-mic' });
		const reason = checkMicAvailability(window.location);
		if (reason) {
			this.fail(reason);
			return;
		}
		try {
			this.micStream = await navigator.mediaDevices.getUserMedia({
				audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
			});
		} catch (err) {
			this.fail(`Microphone denied: ${(err as Error).message}`);
			return;
		}
		this.startCapture();
		this.updateState({ status: 'live' });
	}

	private startCapture() {
		const ctx = this.audioCtx;
		const stream = this.micStream;
		if (!ctx || !stream) return;
		const source = ctx.createMediaStreamSource(stream);
		const processor = ctx.createScriptProcessor(CAPTURE_BUF, 1, 1);
		processor.onaudioprocess = (e) => {
			const ws = this.ws;
			if (!ws || ws.readyState !== WebSocket.OPEN) return;
			const raw = e.inputBuffer.getChannelData(0);
			const down = downsample(raw, ctx.sampleRate, this.inputRate);
			const pcm = float32ToInt16(down);
			ws.send(pcm.buffer);
			this.updateState({ bytesSent: this.state.bytesSent + pcm.buffer.byteLength });
		};
		source.connect(processor);
		const silence = ctx.createGain();
		silence.gain.value = 0;
		processor.connect(silence);
		silence.connect(ctx.destination);
		this.processor = processor;
	}

	private onWsMessage(event: MessageEvent) {
		if (event.data instanceof ArrayBuffer) {
			this.updateState({ bytesRecv: this.state.bytesRecv + event.data.byteLength });
			this.playChunk(event.data);
			return;
		}
		try {
			const msg = JSON.parse(event.data) as { type?: string; audioFormat?: { inputSampleRate?: number; outputSampleRate?: number } };
			if (msg.type === 'session.config' && msg.audioFormat) {
				this.inputRate = msg.audioFormat.inputSampleRate ?? this.inputRate;
				this.outputRate = msg.audioFormat.outputSampleRate ?? this.outputRate;
				this.events.onLog(`audio format: in=${this.inputRate} out=${this.outputRate}`, 'info');
			} else if (msg.type === 'turn.interrupted') {
				this.stopActiveSources();
			}
		} catch {
			/* non-JSON text frame */
		}
	}

	private playChunk(buf: ArrayBuffer) {
		const ctx = this.audioCtx;
		if (!ctx || ctx.state === 'closed') return;
		if (ctx.state === 'suspended') void ctx.resume();
		const f32 = int16ToFloat32(buf);
		if (f32.length === 0) return;
		const audioBuf = ctx.createBuffer(1, f32.length, this.outputRate);
		audioBuf.getChannelData(0).set(f32);
		const src = ctx.createBufferSource();
		src.buffer = audioBuf;
		src.connect(ctx.destination);
		const now = ctx.currentTime;
		if (this.nextPlayTime < now) this.nextPlayTime = now + 0.05;
		src.start(this.nextPlayTime);
		this.nextPlayTime += audioBuf.duration;
		this.activeSources.push(src);
		src.onended = () => {
			const idx = this.activeSources.indexOf(src);
			if (idx >= 0) this.activeSources.splice(idx, 1);
		};
	}

	private stopActiveSources() {
		for (const s of this.activeSources) {
			try {
				s.stop();
			} catch {
				/* already stopped */
			}
		}
		this.activeSources = [];
		this.nextPlayTime = 0;
	}

	private handleClose() {
		this.events.onLog('WebSocket closed', 'info');
		this.cleanup();
		if (this.state.status !== 'error') this.updateState({ status: 'closed' });
	}

	private cleanup() {
		if (this.processor) {
			this.processor.disconnect();
			this.processor = null;
		}
		if (this.micStream) {
			this.micStream.getTracks().forEach((t) => t.stop());
			this.micStream = null;
		}
		this.stopActiveSources();
		this.ws = null;
	}

	private fail(message: string) {
		this.events.onLog(message, 'error');
		this.cleanup();
		this.updateState({ status: 'error', errorMessage: message });
	}

	private updateState(patch: Partial<VoiceSessionState>) {
		this.state = { ...this.state, ...patch };
		this.events.onStateChange(this.state);
	}
}
