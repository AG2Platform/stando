/**
 * Conversation domain types shared between the framework-free store, the
 * useConversation React hook, and the UI components. Keep this small —
 * if a field is presentation-only, put it on the React component prop, not
 * on the store entry.
 */

export type TranscriptRole = 'user' | 'assistant' | 'system';

export type MediaType = 'image' | 'video';

export interface TranscriptMedia {
	type: MediaType;
	/** e.g. image/png, video/mp4 — defaults applied at render time. */
	mimeType?: string;
	/** Raw base64 (no data: prefix). The renderer builds the data URL. */
	base64: string;
	description?: string;
}

export interface TranscriptEntry {
	id: string;
	role: TranscriptRole;
	text: string;
	/** True while the server is still streaming partial tokens. Drops to false
	 *  on the final delta or via the turn.end housekeeping path. */
	interim: boolean;
	/** ms since epoch — used for stable React keys + ordering tests. */
	ts: number;
	/** Optional inline media for system entries created from gui.update or
	 *  top-level `image` / `video` WS frames. */
	media?: TranscriptMedia;
}

export interface ConversationSnapshot {
	entries: readonly TranscriptEntry[];
}
