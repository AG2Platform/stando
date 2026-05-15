import PageHeader from '@/components/atoms/page-header';
import VoiceSessionCard from '@/components/molecules/voice-session-card';
import QuestionsPanel from '@/components/organisms/questions-panel';
import TaskList from '@/components/organisms/task-list';
import Transcript from '@/components/organisms/transcript';
import { APP_COPY } from '@/const-values/app-copy';
import { APP_ROUTES } from '@/const-values/app-routes';
import { useAgentStatus } from '@/hooks/useAgentStatus';
import { useTaskToastDriver } from '@/hooks/useTaskToastDriver';
import { useVoiceSession } from '@/hooks/useVoiceSession';

export default function ConversationPage() {
	const { state, connect, disconnect, toggleMute } = useVoiceSession();
	const { status: serverStatus, error: serverError } = useAgentStatus();
	useTaskToastDriver();

	return (
		<section className="flex h-full flex-col">
			<PageHeader title={APP_ROUTES.conversation.label} hint={APP_ROUTES.conversation.hint} />
			<div className="flex-1 space-y-6 px-6 py-6">
				<p className="max-w-prose text-sm text-[color:var(--color-text-dim)]">{APP_COPY.scaffoldNotice}</p>

				<VoiceSessionCard
					status={state.status}
					muted={state.muted}
					bytesSent={state.bytesSent}
					bytesRecv={state.bytesRecv}
					errorMessage={state.errorMessage}
					onConnect={connect}
					onDisconnect={disconnect}
					onToggleMute={toggleMute}
				/>

				<section className="space-y-2">
					<header>
						<h2 className="text-sm font-semibold text-[color:var(--color-text)]">{APP_COPY.transcriptTitle}</h2>
						<p className="mt-1 max-w-prose text-xs text-[color:var(--color-text-mute)]">{APP_COPY.transcriptHint}</p>
					</header>
					<Transcript />
				</section>

				<QuestionsPanel />

				<TaskList />

				<section className="rounded-lg border border-neutral-800/80 bg-[color:var(--color-surface)]/40 p-5">
					<header>
						<h2 className="text-sm font-semibold text-[color:var(--color-text)]">{APP_COPY.agentStatusTitle}</h2>
						<p className="mt-1 max-w-prose text-xs text-[color:var(--color-text-mute)]">
							{APP_COPY.agentStatusHint}
						</p>
					</header>
					<dl className="mt-4 grid max-w-md grid-cols-2 gap-2 text-xs">
						<dt className="text-[color:var(--color-text-mute)]">Voice connected</dt>
						<dd>{formatBool(serverStatus?.voiceConnected)}</dd>
						<dt className="text-[color:var(--color-text-mute)]">Muted</dt>
						<dd>{formatBool(serverStatus?.muted)}</dd>
						<dt className="text-[color:var(--color-text-mute)]">State</dt>
						<dd className="font-mono">{serverStatus?.state ?? APP_COPY.loading}</dd>
						<dt className="text-[color:var(--color-text-mute)]">Clients</dt>
						<dd className="font-mono">{serverStatus?.clients ?? APP_COPY.loading}</dd>
					</dl>
					{serverError ? (
						<p className="mt-3 text-xs text-[color:var(--color-danger)]">{serverError.message}</p>
					) : null}
				</section>
			</div>
		</section>
	);
}

const formatBool = (value: boolean | undefined): string => {
	if (value === undefined) return APP_COPY.loading;
	return value ? 'yes' : 'no';
};
