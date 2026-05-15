import PageHeader from '@/components/atoms/PageHeader';
import { APP_COPY } from '@/const-values/app-copy';
import { APP_ROUTES } from '@/const-values/app-routes';

export default function CoreCLIPage() {
	return (
		<section className="flex h-full flex-col">
			<PageHeader title={APP_ROUTES['core-cli'].label} hint={APP_ROUTES['core-cli'].hint} />
			<div className="flex-1 px-6 py-6">
				<p className="max-w-prose text-sm text-[color:var(--color-text-dim)]">
					{APP_COPY.scaffoldNotice}
				</p>
				<p className="mt-4 text-xs text-[color:var(--color-text-mute)]">
					Future: hosts the xterm.js terminal that talks to <code className="font-mono">src/terminal-server.ts</code>{' '}
					on port 7847.
				</p>
			</div>
		</section>
	);
}
