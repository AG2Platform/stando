import { afterEach, describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { pingAgentApi } from '../client/src/lib/tasks-api.ts';

const originalFetch = globalThis.fetch;

const setFetch = (impl: typeof fetch): void => {
	globalThis.fetch = impl;
};

afterEach(() => {
	globalThis.fetch = originalFetch;
});

describe('pingAgentApi', () => {
	it('returns true on a 200 response from /ping', async () => {
		const calls: string[] = [];
		setFetch((async (input) => {
			calls.push(String(input));
			return new Response('{}', { status: 200 });
		}) as typeof fetch);

		const ok = await pingAgentApi('http://127.0.0.1:7843/');

		assert.equal(ok, true);
		assert.deepEqual(calls, ['http://127.0.0.1:7843/ping']);
	});

	it('returns false on a network error', async () => {
		setFetch((async () => {
			throw new TypeError('Load failed');
		}) as typeof fetch);

		const ok = await pingAgentApi('http://127.0.0.1:7843');

		assert.equal(ok, false);
	});

	it('returns false when the ping times out', async () => {
		setFetch(((_input, init) => new Promise<Response>((_resolve, reject) => {
			const signal = init?.signal;
			if (signal?.aborted) {
				reject(new Error('aborted'));
				return;
			}
			signal?.addEventListener('abort', () => reject(new Error('aborted')), { once: true });
		})) as typeof fetch);

		const ok = await pingAgentApi('http://127.0.0.1:7843', 1);

		assert.equal(ok, false);
	});
});
