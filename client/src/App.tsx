import AppShell from '@/components/molecules/AppShell';
import { APP_COPY } from '@/const-values/app-copy';
import type { AppRouteId } from '@/const-values/app-routes';
import { useCurrentRoute } from '@/hooks/useCurrentRoute';
import ConversationPage from '@/pages/conversation';
import CoreCLIPage from '@/pages/core-cli';
import DashboardPage from '@/pages/dashboard';
import SettingsPage from '@/pages/settings';

const renderPage = (id: AppRouteId) => {
	switch (id) {
		case 'conversation':
			return <ConversationPage />;
		case 'core-cli':
			return <CoreCLIPage />;
		case 'dashboard':
			return <DashboardPage />;
		case 'settings':
			return <SettingsPage />;
		default:
			return <p className="px-6 py-6 text-sm text-[color:var(--color-text-mute)]">{APP_COPY.pageMissing}</p>;
	}
};

export default function App() {
	const { routeId, setRoute } = useCurrentRoute();
	return (
		<AppShell activeId={routeId} onSelect={setRoute}>
			{renderPage(routeId)}
		</AppShell>
	);
}
