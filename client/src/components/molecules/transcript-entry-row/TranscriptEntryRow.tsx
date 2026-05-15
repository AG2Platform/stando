import CopyButton from '@/components/atoms/copy-button';
import type { TranscriptEntry } from '@/types/conversation';

export interface TranscriptEntryRowProps {
	entry: TranscriptEntry;
}

const ROLE_LABEL: Record<TranscriptEntry['role'], string> = {
	user: 'You',
	assistant: 'Sutando',
	system: 'System',
};

const ROW_TONE: Record<TranscriptEntry['role'], string> = {
	user: 'border-l-[color:var(--color-accent)]/60 bg-[color:var(--color-accent)]/[0.04]',
	assistant: 'border-l-emerald-400/50 bg-emerald-500/[0.04]',
	system: 'border-l-neutral-700 bg-neutral-900/40 text-[color:var(--color-text-dim)] italic',
};

export default function TranscriptEntryRow({ entry }: TranscriptEntryRowProps) {
	const tone = ROW_TONE[entry.role];
	const interim = entry.interim;

	return (
		<article
			className={`group relative rounded-md border-l-2 px-3 py-2 text-sm transition-opacity ${tone} ${
				interim ? 'opacity-70' : ''
			}`}
			data-role={entry.role}
			data-interim={interim}
		>
			<header className="flex items-center justify-between gap-2 text-[11px] uppercase tracking-wide text-[color:var(--color-text-mute)]">
				<span>
					{ROLE_LABEL[entry.role]}
					{interim ? ' · transcribing…' : ''}
				</span>
				{!interim && entry.role !== 'system' ? <CopyButton value={entry.text} /> : null}
			</header>
			<p className="mt-1 whitespace-pre-wrap break-words leading-relaxed">{entry.text}</p>
		</article>
	);
}
