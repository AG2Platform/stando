import PageHeader from '@/components/atoms/PageHeader';
import { APP_COPY } from '@/const-values/app-copy';
import { APP_ROUTES } from '@/const-values/app-routes';

export default function DashboardPage() {
	return (
		<section className="flex h-full flex-col">
			<PageHeader title={APP_ROUTES.dashboard.label} hint={APP_ROUTES.dashboard.hint} />
			<div className="flex-1 px-6 py-6">
				<p className="max-w-prose text-sm text-[color:var(--color-text-dim)]">
					{APP_COPY.scaffoldNotice}
				</p>
				<p className="mt-4 text-xs text-[color:var(--color-text-mute)]">
					Future: replaces <code className="font-mono">src/dashboard.py</code>'s HTML with native React panels.
				</p>
			</div>
		</section>
	);
}
