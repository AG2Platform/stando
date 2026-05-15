/**
 * App-wide copy strings. Kept in const-values per CLAUDE.md so components
 * stay strictly presentational. When packages/ui ships (PR-D) the cloud
 * + desktop apps can swap in their own copy without touching components.
 */

export const APP_COPY = {
	appName: 'Sutando',
	appTagline: 'Your personal agent.',
	scaffoldNotice:
		'PR-B scaffold — the legacy HTML at GET / still ships the full conversation UI. PR-C migrates the real features into this React tree.',
	pageMissing: 'No page matched. Use the nav above to pick one.',
	loading: 'Loading…',
} as const;
