import type { ReactNode } from 'react';
import NavTabs from '@/components/atoms/NavTabs';
import { APP_COPY } from '@/const-values/app-copy';
import type { AppRouteId } from '@/const-values/app-routes';

export interface AppShellProps {
	activeId: AppRouteId;
	onSelect: (id: AppRouteId) => void;
	children: ReactNode;
}

export default function AppShell({ activeId, onSelect, children }: AppShellProps) {
	return (
		<div className="flex min-h-screen flex-col bg-[color:var(--color-canvas)] text-[color:var(--color-text)]">
			<div className="border-b border-neutral-900/80 px-4 py-2">
				<div className="flex items-center justify-between">
					<div className="flex items-center gap-2">
						<span className="inline-flex h-6 w-6 items-center justify-center rounded-md bg-[color:var(--color-accent)]/20 text-sm font-semibold text-[color:var(--color-accent)]">
							S
						</span>
						<span className="text-sm font-medium tracking-tight">{APP_COPY.appName}</span>
					</div>
					<span className="text-xs text-[color:var(--color-text-mute)]">{APP_COPY.appTagline}</span>
				</div>
			</div>
			<NavTabs activeId={activeId} onSelect={onSelect} />
			<main className="flex-1 overflow-auto">{children}</main>
		</div>
	);
}
