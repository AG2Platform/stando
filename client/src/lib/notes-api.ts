/**
 * Thin fetch wrappers for the agent-universe dashboard's /notes endpoints
 * (port 7844 by default). Components / hooks never call fetch directly per
 * CLAUDE.md frontend conventions.
 *
 * Endpoints (mirrored from agent-api.py):
 *   GET    /notes           — list { slug, title, modified, tags? }
 *   GET    /notes/<slug>    — raw markdown text (with YAML frontmatter)
 *   DELETE /notes/<slug>    — remove the note
 *   POST   /note-viewing    — notify the voice agent we're viewing slug
 *                             (fire-and-forget, served by web-server.ts on
 *                             the conversation port).
 */

const stripTrailingSlash = (origin: string): string => origin.replace(/\/$/, '');

export interface NoteSummary {
	slug: string;
	title: string;
	modified: number;
	tags?: string[];
}

const notesOrigin = (): string => {
	const host = window.location.hostname || 'localhost';
	return `http://${host}:7844`;
};

export async function fetchNotes(signal?: AbortSignal): Promise<NoteSummary[]> {
	const res = await fetch(`${notesOrigin()}/notes`, { signal });
	if (!res.ok) throw new Error(`fetchNotes ${res.status}`);
	return (await res.json()) as NoteSummary[];
}

export async function fetchNoteMarkdown(slug: string, signal?: AbortSignal): Promise<string> {
	const res = await fetch(`${notesOrigin()}/notes/${encodeURIComponent(slug)}`, { signal });
	if (!res.ok) throw new Error(`fetchNoteMarkdown ${res.status}`);
	return await res.text();
}

export async function deleteNote(slug: string): Promise<boolean> {
	const res = await fetch(`${notesOrigin()}/notes/${encodeURIComponent(slug)}`, {
		method: 'DELETE',
	});
	return res.ok;
}

/**
 * Fire-and-forget notification that the user is reading a note — the voice
 * agent uses this to load the raw markdown into its context. Same plumbing
 * as the legacy `fetch('/note-viewing', {…})` call. Failures are silent.
 */
export async function notifyNoteViewing(apiOrigin: string, slug: string, content: string): Promise<void> {
	try {
		await fetch(`${stripTrailingSlash(apiOrigin)}/note-viewing`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({ slug, content }),
		});
	} catch {
		/* noop — voice agent may not be running */
	}
}
