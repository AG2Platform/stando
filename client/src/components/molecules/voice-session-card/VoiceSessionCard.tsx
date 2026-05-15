import ConnectButton from '@/components/atoms/connect-button';
import MuteButton from '@/components/atoms/mute-button';
import StatusBadge from '@/components/atoms/status-badge';
import { APP_COPY, type VoiceStatusKey } from '@/const-values/app-copy';
import type { VoiceSessionStatus } from '@/lib/voice-session';
import { formatBytes } from '@/utils/format-bytes';

const LABEL_BY_STATUS: Record<VoiceSessionStatus, VoiceStatusKey> = {
	idle: 'voiceIdle',
	connecting: 'voiceConnecting',
	'requesting-mic': 'voiceRequestingMic',
	live: 'voiceLive',
	error: 'voiceError',
	closed: 'voiceClosed',
};

export interface VoiceSessionCardProps {
	status: VoiceSessionStatus;
	muted: boolean;
	bytesSent: number;
	bytesRecv: number;
	errorMessage: string | null;
	onConnect: () => void;
	onDisconnect: () => void;
	onToggleMute: () => void;
}

export default function VoiceSessionCard({
	status,
	muted,
	bytesSent,
	bytesRecv,
	errorMessage,
	onConnect,
	onDisconnect,
	onToggleMute,
}: VoiceSessionCardProps) {
	const isLive = status === 'live';

	return (
		<section className="rounded-lg border border-neutral-800/80 bg-[color:var(--color-surface)]/40 p-5">
			<header className="flex items-center justify-between gap-4">
				<div>
					<h2 className="text-sm font-semibold text-[color:var(--color-text)]">{APP_COPY.voiceSessionTitle}</h2>
					<p className="mt-1 max-w-prose text-xs text-[color:var(--color-text-mute)]">
						{APP_COPY.voiceSessionHint}
					</p>
				</div>
				<StatusBadge status={status} label={APP_COPY[LABEL_BY_STATUS[status]]} />
			</header>

			<div className="mt-4 flex items-center gap-2">
				<ConnectButton
					status={status}
					connectLabel={APP_COPY.voiceConnect}
					connectingLabel={APP_COPY.voiceConnecting}
					requestingMicLabel={APP_COPY.voiceRequestingMic}
					disconnectLabel={APP_COPY.disconnect}
					onConnect={onConnect}
					onDisconnect={onDisconnect}
				/>
				<MuteButton
					muted={muted}
					muteLabel={APP_COPY.mute}
					unmuteLabel={APP_COPY.unmute}
					onToggle={onToggleMute}
					disabled={!isLive}
				/>
			</div>

			{isLive ? (
				<dl className="mt-4 grid max-w-xs grid-cols-2 gap-2 text-xs">
					<dt className="text-[color:var(--color-text-mute)]">Sent</dt>
					<dd className="font-mono">{formatBytes(bytesSent)}</dd>
					<dt className="text-[color:var(--color-text-mute)]">Received</dt>
					<dd className="font-mono">{formatBytes(bytesRecv)}</dd>
				</dl>
			) : null}

			{errorMessage ? (
				<p className="mt-4 rounded-md bg-rose-500/10 px-3 py-2 text-xs text-[color:var(--color-danger)]">
					{errorMessage}
				</p>
			) : null}
		</section>
	);
}
