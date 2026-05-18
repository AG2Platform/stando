import { APP_ROUTES, APP_ROUTE_IDS, type AppRouteId } from '@/const-values/app-routes';

export interface NavTabsProps {
	activeId: AppRouteId;
	onSelect: (id: AppRouteId) => void;
}

export default function NavTabs({ activeId, onSelect }: NavTabsProps) {
	return (
		<nav className="flex gap-1 border-b border-neutral-800/80 px-2" aria-label="Sutando pages">
			{APP_ROUTE_IDS.map((id) => {
				const route = APP_ROUTES[id];
				const isActive = id === activeId;
				return (
					<button
						key={id}
						type="button"
						onClick={() => onSelect(id)}
						className={`relative px-3 py-2 text-sm transition-colors ${
							isActive
								? 'text-[color:var(--color-text)]'
								: 'text-[color:var(--color-text-mute)] hover:text-[color:var(--color-text-dim)]'
						}`}
						aria-current={isActive ? 'page' : undefined}
					>
						{route.label}
						{isActive ? (
							<span className="absolute inset-x-2 bottom-0 h-px bg-[color:var(--color-accent)]" />
						) : null}
					</button>
				);
			})}
		</nav>
	);
}
