import PageHeader from '@/components/atoms/PageHeader';
import { APP_COPY } from '@/const-values/app-copy';
import { APP_ROUTES } from '@/const-values/app-routes';
import { useAgentStatus } from '@/hooks/useAgentStatus';

export default function ConversationPage() {
	const { status, error } = useAgentStatus();

	return (
		<section className="flex h-full flex-col">
			<PageHeader title={APP_ROUTES.conversation.label} hint={APP_ROUTES.conversation.hint} />
			<div className="flex-1 px-6 py-6">
				<p className="max-w-prose text-sm text-[color:var(--color-text-dim)]">{APP_COPY.scaffoldNotice}</p>
				<div className="mt-6 grid max-w-md grid-cols-2 gap-3 rounded-lg border border-neutral-800/80 p-4 text-xs">
					<dt className="text-[color:var(--color-text-mute)]">Voice connected</dt>
					<dd>{formatBool(status?.voiceConnected)}</dd>
					<dt className="text-[color:var(--color-text-mute)]">Muted</dt>
					<dd>{formatBool(status?.muted)}</dd>
					<dt className="text-[color:var(--color-text-mute)]">State</dt>
					<dd>{status?.state ?? APP_COPY.loading}</dd>
					<dt className="text-[color:var(--color-text-mute)]">Clients</dt>
					<dd>{status?.clients ?? APP_COPY.loading}</dd>
				</div>
				{error ? (
					<p className="mt-4 text-xs text-[color:var(--color-danger)]">{error.message}</p>
				) : null}
			</div>
		</section>
	);
}

const formatBool = (value: boolean | undefined): string => {
	if (value === undefined) return APP_COPY.loading;
	return value ? 'yes' : 'no';
};
