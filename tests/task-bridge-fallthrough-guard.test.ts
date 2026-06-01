import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { _shouldFallthrough } from '../src/task-bridge.js';

describe('_shouldFallthrough', () => {
	it('allows task- prefix', () => {
		assert.equal(_shouldFallthrough('task-1748800000000.txt'), true);
	});

	it('allows voice- prefix', () => {
		assert.equal(_shouldFallthrough('voice-1748800000000.txt'), true);
	});

	it('allows proactive- prefix', () => {
		assert.equal(_shouldFallthrough('proactive-1748800000000.txt'), true);
	});

	it('blocks a per-channel pull namespace filename', () => {
		// Future per-channel pull namespace: `<channel-key>.task-{id}.txt`
		// must NOT be consumed by the voice fallthrough path.
		assert.equal(_shouldFallthrough('dvoice-abc123.task-1748800000000.txt'), false);
	});

	it('blocks an arbitrary unknown prefix', () => {
		assert.equal(_shouldFallthrough('result-1748800000000.txt'), false);
	});

	it('blocks empty string', () => {
		assert.equal(_shouldFallthrough(''), false);
	});
});
