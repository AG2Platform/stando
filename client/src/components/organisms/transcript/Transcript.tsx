import { useEffect, useRef } from 'react';
import TranscriptEntryRow from '@/components/molecules/transcript-entry-row';
import { APP_COPY } from '@/const-values/app-copy';
import { useConversation } from '@/hooks/useConversation';

/**
 * Scrolling transcript list. Auto-pins to the bottom whenever the user is
 * already at (or near) the bottom — pure cosmetic pinning, doesn't fight the
 * user's scroll like a hard scrollIntoView would.
 */
const STICK_THRESHOLD_PX = 64;

export default function Transcript() {
	const { entries } = useConversation();
	const scrollerRef = useRef<HTMLDivElement | null>(null);
	const stickyRef = useRef(true);

	useEffect(() => {
		const el = scrollerRef.current;
		if (!el) return;
		const onScroll = () => {
			const distance = el.scrollHeight - el.scrollTop - el.clientHeight;
			stickyRef.current = distance < STICK_THRESHOLD_PX;
		};
		el.addEventListener('scroll', onScroll, { passive: true });
		return () => el.removeEventListener('scroll', onScroll);
	}, []);

	useEffect(() => {
		const el = scrollerRef.current;
		if (!el || !stickyRef.current) return;
		el.scrollTop = el.scrollHeight;
	}, [entries.length, entries[entries.length - 1]?.text]);

	return (
		<section
			ref={scrollerRef}
			className="h-72 overflow-y-auto rounded-lg border border-neutral-800/80 bg-[color:var(--color-surface)]/40 p-3"
		>
			{entries.length === 0 ? (
				<p className="px-2 py-1 text-xs text-[color:var(--color-text-mute)]">{APP_COPY.transcriptEmpty}</p>
			) : (
				<div className="flex flex-col gap-2">
					{entries.map((entry) => (
						<TranscriptEntryRow key={entry.id} entry={entry} />
					))}
				</div>
			)}
		</section>
	);
}
