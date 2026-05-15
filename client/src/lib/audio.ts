/**
 * Audio utilities shared by the voice session (mic capture + playback).
 *
 * Ported verbatim from src/web-client-html.ts so PR-C keeps audio behavior
 * byte-for-byte identical to the legacy HTML — same downsample math, same
 * float32 ↔ int16 conversion, same clamping. Anything that drifted here
 * would show up immediately as garbled audio in voice testing, so don't
 * "improve" without an audio quality regression check.
 *
 * AudioWorkletNode is the modern replacement for ScriptProcessor used in
 * voice-session.ts — defer the migration until we have a parity test.
 */

/** Linear-interpolation downsampler. Used to feed Gemini Live at 16 kHz from
 *  a typically 48 kHz mic AudioContext. */
export function downsample(input: Float32Array, fromRate: number, toRate: number): Float32Array {
	if (fromRate === toRate) return input;
	const ratio = fromRate / toRate;
	const len = Math.floor(input.length / ratio);
	const out = new Float32Array(len);
	for (let i = 0; i < len; i++) {
		const pos = i * ratio;
		const idx = Math.floor(pos);
		const frac = pos - idx;
		out[i] = input[idx] * (1 - frac) + (input[idx + 1] ?? 0) * frac;
	}
	return out;
}

/** Convert a Float32 PCM sample buffer to little-endian Int16. */
export function float32ToInt16(f32: Float32Array): Int16Array {
	const i16 = new Int16Array(f32.length);
	for (let i = 0; i < f32.length; i++) {
		const s = Math.max(-1, Math.min(1, f32[i] ?? 0));
		i16[i] = s < 0 ? (s * 0x8000) | 0 : (s * 0x7fff) | 0;
	}
	return i16;
}

/** Convert a little-endian Int16 PCM buffer to Float32 in the range [-1, 1]. */
export function int16ToFloat32(buf: ArrayBuffer): Float32Array {
	const view = new DataView(buf);
	const len = buf.byteLength / 2;
	const out = new Float32Array(len);
	for (let i = 0; i < len; i++) {
		out[i] = view.getInt16(i * 2, true) / 32768;
	}
	return out;
}

/**
 * Detect environments where getUserMedia is unavailable. Surfaces a helpful
 * error message instead of the browser's generic "undefined is not a function".
 * Returns null when capture should succeed.
 */
export function checkMicAvailability(location: Pick<Location, 'hostname' | 'protocol'>): string | null {
	// Look up mediaDevices directly — `getUserMedia` is typed as always-defined
	// on MediaDevices so probing the method triggers a TS 2774 always-true
	// warning. The runtime presence of `mediaDevices` is the real signal:
	// HTTP-served pages on non-localhost get an undefined `navigator.mediaDevices`,
	// which is exactly the case we want to surface.
	const mediaDevices = typeof navigator !== 'undefined' ? navigator.mediaDevices : undefined;
	if (mediaDevices) return null;
	const isLocalhost =
		location.hostname === 'localhost' ||
		location.hostname === '127.0.0.1' ||
		location.hostname === '[::1]';
	const isHttps = location.protocol === 'https:';
	if (!isLocalhost && !isHttps) {
		return 'Microphone access requires HTTPS. Access this page via https:// or from localhost — modern browsers block getUserMedia on plain HTTP.';
	}
	return 'getUserMedia is not available. Use a modern browser (Chrome, Safari, Firefox).';
}
