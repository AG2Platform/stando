/**
 * Active route id, synced with the `?page=` query string.
 *
 * Sutando's first-pass nav is intentionally router-free — every page is
 * a top-level switch case and the URL is the single source of truth.
 * Drop-in `react-router` later if route nesting, params, or scroll-
 * restoration become real needs. Until then, less code, less to learn,
 * fewer dependencies.
 */

import { useCallback, useEffect, useState } from 'react';
import {
	DEFAULT_ROUTE_ID,
	isAppRouteId,
	type AppRouteId,
} from '@/const-values/app-routes';

const readRouteFromLocation = (): AppRouteId => {
	const params = new URLSearchParams(window.location.search);
	const candidate = params.get('page') ?? '';
	return isAppRouteId(candidate) ? candidate : DEFAULT_ROUTE_ID;
};

export interface UseCurrentRouteResult {
	routeId: AppRouteId;
	setRoute: (next: AppRouteId) => void;
}

export function useCurrentRoute(): UseCurrentRouteResult {
	const [routeId, setRouteId] = useState<AppRouteId>(readRouteFromLocation);

	useEffect(() => {
		const onPopState = () => setRouteId(readRouteFromLocation());
		window.addEventListener('popstate', onPopState);
		return () => window.removeEventListener('popstate', onPopState);
	}, []);

	const setRoute = useCallback((next: AppRouteId) => {
		const url = new URL(window.location.href);
		url.searchParams.set('page', next);
		window.history.pushState({}, '', url);
		setRouteId(next);
	}, []);

	return { routeId, setRoute };
}
