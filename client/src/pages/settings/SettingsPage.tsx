import PageHeader from '@/components/atoms/page-header';
import { APP_COPY } from '@/const-values/app-copy';
import { APP_ROUTES } from '@/const-values/app-routes';

export default function SettingsPage() {
	return (
		<section className="flex h-full flex-col">
			<PageHeader title={APP_ROUTES.settings.label} hint={APP_ROUTES.settings.hint} />
			<div className="flex-1 px-6 py-6">
				<p className="max-w-prose text-sm text-[color:var(--color-text-dim)]">
					{APP_COPY.scaffoldNotice}
				</p>
				<p className="mt-4 text-xs text-[color:var(--color-text-mute)]">
					Future: voice config, model picker, integrations toggles — mirrors{' '}
					<code className="font-mono">src/Sutando/SettingsWindow.swift</code>.
				</p>
			</div>
		</section>
	);
}
