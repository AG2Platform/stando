/**
 * One-shot fetch of the agent-universe `/stand-identity` endpoint
 * (port 7844 — the dashboard server, optional). When present:
 *   - `name` becomes the header + hero display name (e.g. "Mochi").
 *   - `avatarUrl` (when `avatarGenerated === true`) replaces the inline
 *     "S" SVG with a generated PNG so the page reflects the user's
 *     personal stand identity.
 *
 * Failure-safe: returns null when the dashboard isn't running, matching
 * the legacy `.catch(() => {})` swallow. Components fall back to the
 * default "Sutando" name and inline SVG when null.
 */

import { useEffect, useState } from 'react';
import { fetchStandIdentity, type StandIdentity } from '@/lib/api';

export function useStandIdentity(): StandIdentity | null {
	const [identity, setIdentity] = useState<StandIdentity | null>(null);

	useEffect(() => {
		const controller = new AbortController();
		void (async () => {
			const result = await fetchStandIdentity(controller.signal);
			if (result) setIdentity(result);
		})();
		return () => controller.abort();
	}, []);

	return identity;
}
