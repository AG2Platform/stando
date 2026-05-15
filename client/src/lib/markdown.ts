/**
 * Minimal markdown → HTML transformer, ported from the inline regex chain
 * in src/web-client-html.ts `showNoteContent()`. Same subset of features
 * (headings, code blocks, links, bold/italic, blockquote, hr, lists), no
 * external dependency. Output is wrapped in a `<div>` and rendered via
 * `dangerouslySetInnerHTML` — inputs come from the user's own filesystem
 * (~/.claude/.../notes) so trust matches the legacy behavior.
 *
 * The legacy file had to double-escape backslashes twice (TS template
 * literal → JS string → regex). Here we just write the patterns directly
 * because we're inside a normal .ts file.
 */

export interface ParsedNote {
	title: string;
	bodyHtml: string;
}

const escapeHtml = (s: string): string =>
	s.replace(/&/g, '&amp;')
		.replace(/</g, '&lt;')
		.replace(/>/g, '&gt;')
		.replace(/"/g, '&quot;')
		.replace(/'/g, '&#39;');

const stripFrontmatter = (text: string): { title: string; remainder: string } => {
	const match = text.match(/^---\s*\n([\s\S]*?)\n---\s*\n?/);
	if (!match) return { title: '', remainder: text };
	const titleMatch = match[1]!.match(/^title:\s*(.+)$/m);
	const title = titleMatch ? titleMatch[1]!.trim() : '';
	return { title, remainder: text.slice(match[0].length) };
};

export function parseNoteMarkdown(text: string, fallbackTitle: string): ParsedNote {
	const { title, remainder } = stripFrontmatter(text);
	let html = remainder;

	// Code blocks must run first so headings inside ``` don't get processed.
	html = html.replace(/```([\s\S]*?)```/g, (_m, code: string) => {
		return `<pre style="background:var(--border);padding:8px;border-radius:4px;font-size:12px;overflow-x:auto"><code>${escapeHtml(code)}</code></pre>`;
	});
	html = html.replace(/`([^`]+)`/g, (_m, code: string) => {
		return `<code style="background:var(--border);padding:1px 4px;border-radius:2px">${escapeHtml(code)}</code>`;
	});

	html = html.replace(/^### (.+)$/gm, '<h3>$1</h3>');
	html = html.replace(/^## (.+)$/gm, '<h2>$1</h2>');
	html = html.replace(/^# (.+)$/gm, '<h1 style="font-size:16px">$1</h1>');

	// Images before links — otherwise the link regex eats the `![alt]` form.
	html = html.replace(/!\[([^\]]*)\]\(([^)]+)\)/g,
		'<img src="$2" alt="$1" style="max-width:100%;border-radius:4px;margin:8px 0">');
	html = html.replace(/\[([^\]]+)\]\(([^)]+)\)/g,
		'<a href="$2" target="_blank" rel="noreferrer" style="color:#7c83ff">$1</a>');

	html = html.replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');
	html = html.replace(/(^|[^*])\*([^*\n]+)\*/g, '$1<em>$2</em>');
	html = html.replace(/^> ?(.+)$/gm,
		'<blockquote style="border-left:3px solid #7c83ff;padding-left:10px;color:#a0a0b0;margin:8px 0;font-style:italic">$1</blockquote>');
	html = html.replace(/^---+$/gm,
		'<hr style="border:none;border-top:1px solid var(--border);margin:12px 0">');
	html = html.replace(/^- (.+)$/gm, '<li>$1</li>');
	html = html.replace(/\n\n/g, '<br><br>');

	return { title: title || fallbackTitle, bodyHtml: html };
}
