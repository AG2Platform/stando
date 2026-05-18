/**
 * Notes tab content for the dynamic region. Ports the legacy `tab === 'notes'`
 * branch of renderTabContent() plus showNoteContent / deleteNoteFromUI /
 * filterNotes — fetch list, fuzzy filter by title/slug, click to open a
 * single note (markdown rendered via lib/markdown.ts), back button returns
 * to the list, delete button removes it.
 *
 * Opening a note also fires `/note-viewing` so the voice agent can pull the
 * raw markdown into its context — same as the legacy.
 */

import { useEffect, useState } from 'react';
import { resolveConfig } from '@/lib/config';
import { parseNoteMarkdown } from '@/lib/markdown';
import { deleteNote, fetchNoteMarkdown, fetchNotes, notifyNoteViewing, type NoteSummary } from '@/lib/notes-api';

interface ViewState {
	kind: 'list' | 'viewing';
	slug?: string;
}

export default function NotesPanel() {
	const [notes, setNotes] = useState<NoteSummary[] | null>(null);
	const [error, setError] = useState<string | null>(null);
	const [query, setQuery] = useState('');
	const [view, setView] = useState<ViewState>({ kind: 'list' });

	useEffect(() => {
		const controller = new AbortController();
		void (async () => {
			try {
				const list = await fetchNotes(controller.signal);
				setNotes(list);
			} catch (err) {
				if (!controller.signal.aborted) setError((err as Error).message);
			}
		})();
		return () => controller.abort();
	}, []);

	if (view.kind === 'viewing' && view.slug) {
		return <NoteViewer slug={view.slug} onBack={() => setView({ kind: 'list' })} />;
	}

	if (error) {
		return (
			<div style={{ color: '#666', fontSize: 13, textAlign: 'center', padding: 12 }}>
				Couldn't load notes ({error}). Is the dashboard server running on :7844?
			</div>
		);
	}

	if (!notes) {
		return (
			<div style={{ color: '#666', fontSize: 13, textAlign: 'center', padding: 12 }}>Loading…</div>
		);
	}

	const q = query.trim().toLowerCase();
	const filtered = q
		? notes.filter(
				(n) => n.title.toLowerCase().includes(q) || n.slug.toLowerCase().includes(q)
			)
		: notes;

	return (
		<div>
			<div style={{ marginBottom: 8 }}>
				<input
					type="text"
					placeholder="Search notes..."
					value={query}
					onChange={(ev) => setQuery(ev.target.value)}
					style={{
						width: '100%',
						padding: '6px 10px',
						borderRadius: 8,
						border: '1px solid var(--border)',
						background: 'var(--surface)',
						color: 'var(--text)',
						fontSize: 12,
						outline: 'none',
					}}
				/>
			</div>
			{filtered.length === 0 ? (
				<div style={{ color: '#666', fontSize: 12, textAlign: 'center', padding: 12 }}>
					{q ? 'No matching notes' : 'No notes'}
				</div>
			) : (
				filtered.map((n) => (
					<NoteRow
						key={n.slug}
						note={n}
						onOpen={() => setView({ kind: 'viewing', slug: n.slug })}
						onDelete={async () => {
							const ok = await deleteNote(n.slug);
							if (ok) setNotes((curr) => curr?.filter((other) => other.slug !== n.slug) ?? null);
						}}
					/>
				))
			)}
		</div>
	);
}

function NoteRow({
	note,
	onOpen,
	onDelete,
}: {
	note: NoteSummary;
	onOpen: () => void;
	onDelete: () => void;
}) {
	return (
		<div
			style={{
				padding: '12px 10px',
				margin: '0 -10px',
				borderBottom: '1px solid var(--border)',
				display: 'flex',
				alignItems: 'center',
				fontSize: 16,
				lineHeight: 1.6,
				borderRadius: 6,
			}}
		>
			<span style={{ marginRight: 10, flexShrink: 0 }}>📝</span>
			<span style={{ color: '#7c83ff', cursor: 'pointer', flex: 1 }} onClick={onOpen}>
				{note.title}
			</span>
			<span style={{ color: '#666', fontSize: 13, marginRight: 8 }}>
				{new Date(note.modified * 1000).toLocaleDateString()}
			</span>
			<span
				role="button"
				style={{ color: '#e94560', fontSize: 13, cursor: 'pointer', opacity: 0.5 }}
				onClick={(ev) => {
					ev.stopPropagation();
					onDelete();
				}}
				title="Delete note"
			>
				×
			</span>
		</div>
	);
}

function NoteViewer({ slug, onBack }: { slug: string; onBack: () => void }) {
	const [parsed, setParsed] = useState<{ title: string; bodyHtml: string } | null>(null);
	const [error, setError] = useState<string | null>(null);

	useEffect(() => {
		const controller = new AbortController();
		void (async () => {
			try {
				const raw = await fetchNoteMarkdown(slug, controller.signal);
				const { apiOrigin } = resolveConfig();
				void notifyNoteViewing(apiOrigin, slug, raw);
				setParsed(parseNoteMarkdown(raw, slug));
			} catch (err) {
				if (!controller.signal.aborted) setError((err as Error).message);
			}
		})();
		return () => controller.abort();
	}, [slug]);

	return (
		<div>
			<span
				className="suggestion"
				style={{ fontSize: 11, cursor: 'pointer', marginBottom: 8, display: 'inline-block' }}
				onClick={onBack}
			>
				← Back
			</span>
			{error ? (
				<div style={{ color: '#e94560', fontSize: 13, padding: 12 }}>{error}</div>
			) : !parsed ? (
				<div style={{ color: '#666', fontSize: 13, padding: 12 }}>Loading…</div>
			) : (
				<>
					<h2
						style={{
							fontSize: 15,
							color: '#7c83ff',
							margin: '8px 0 10px 0',
							borderBottom: '1px solid var(--border)',
							paddingBottom: 6,
						}}
					>
						{parsed.title}
					</h2>
					<div
						style={{ fontSize: 13, lineHeight: 1.5 }}
						dangerouslySetInnerHTML={{ __html: parsed.bodyHtml }}
					/>
				</>
			)}
		</div>
	);
}
