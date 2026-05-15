import type { VoiceSessionStatus } from '@/lib/voice-session';

export interface ConnectButtonProps {
	status: VoiceSessionStatus;
	connectLabel: string;
	connectingLabel: string;
	requestingMicLabel: string;
	disconnectLabel: string;
	onConnect: () => void;
	onDisconnect: () => void;
}

export default function ConnectButton({
	status,
	connectLabel,
	connectingLabel,
	requestingMicLabel,
	disconnectLabel,
	onConnect,
	onDisconnect,
}: ConnectButtonProps) {
	const isLive = status === 'live';
	const isBusy = status === 'connecting' || status === 'requesting-mic';

	const label = isLive
		? disconnectLabel
		: status === 'connecting'
			? connectingLabel
			: status === 'requesting-mic'
				? requestingMicLabel
				: connectLabel;

	const handler = isLive ? onDisconnect : onConnect;
	const tone = isLive
		? 'bg-neutral-800 text-[color:var(--color-text)] hover:bg-neutral-700'
		: 'bg-[color:var(--color-accent)] text-neutral-950 hover:bg-[color:var(--color-accent-soft)]';

	return (
		<button
			type="button"
			onClick={handler}
			disabled={isBusy}
			className={`inline-flex items-center justify-center rounded-md px-4 py-2 text-sm font-medium transition-colors disabled:opacity-60 ${tone}`}
		>
			{label}
		</button>
	);
}
