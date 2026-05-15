import { useEffect, useRef } from 'react';
import { useConversation } from '@/hooks/useConversation';
import type { TranscriptEntry } from '@/types/conversation';

/**
 * Transcript styled to match src/web-client-html.ts — `.transcript` container
 * with `.t-user` / `.t-assistant` / `.t-system` entries. The "You:" /
 * "Sutando:" prefixes come from legacy.css `::before` pseudo-elements,
 * not from this component.
 *
 * Auto-stick to bottom when the user is already near the bottom (the legacy
 * behavior). When the user scrolls up to read history, we stop auto-pinning
 * until they scroll back near the bottom.
 */

const STICK_THRESHOLD_PX = 64;

function entryClass(entry: TranscriptEntry): string {
	if (entry.role === 'system') return 't-entry t-system';
	if (entry.interim && entry.role === 'user') return 't-entry t-interim';
	if (entry.role === 'user') return 't-entry t-user';
	return 't-entry t-assistant';
}

function renderMedia(entry: TranscriptEntry) {
	if (!entry.media) return null;
	const mimeType = entry.media.mimeType ?? (entry.media.type === 'video' ? 'video/mp4' : 'image/png');
	const src = `data:${mimeType};base64,${entry.media.base64}`;
	const caption = entry.media.description;
	if (entry.media.type === 'video') {
		return (
			<div style={{ marginTop: 6 }}>
				<video src={src} controls style={{ maxWidth: '100%', borderRadius: 8 }} />
				{caption ? <div style={{ fontSize: 11, color: '#666', marginTop: 4 }}>{caption}</div> : null}
			</div>
		);
	}
	return (
		<div style={{ marginTop: 6 }}>
			<img src={src} alt={caption ?? 'inline image'} style={{ maxWidth: '100%', borderRadius: 8 }} />
			{caption ? <div style={{ fontSize: 11, color: '#666', marginTop: 4 }}>{caption}</div> : null}
		</div>
	);
}

export default function LegacyTranscript() {
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
		<div ref={scrollerRef} className="transcript">
			{entries.length === 0 ? (
				<div className="t-entry t-system">Ask Sutando anything.</div>
			) : (
				entries.map((entry) => (
					<div key={entry.id} className={entryClass(entry)}>
						{entry.text}
						{renderMedia(entry)}
					</div>
				))
			)}
		</div>
	);
}
