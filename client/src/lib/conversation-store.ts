/**
 * Module-level conversation store. Holds the transcript entries that drive
 * the <Transcript /> organism. Framework-free (snapshot + subscribe) so it
 * composes with React's useSyncExternalStore and can later be exercised
 * from unit tests without rendering anything.
 *
 * Lifecycle rules (ported from src/web-client-html.ts handleTranscript +
 * turn.end / turn.interrupted handlers — keep behavior identical):
 *   - User partial:    create or update `currentUserId` entry (interim=true).
 *   - User final:      finalize `currentUserId` entry (interim=false), drop ptr.
 *   - Assistant text:  create or update `currentAssistantId`. Assistants don't
 *                      visually show an interim state, but we still track the
 *                      `interim` flag for symmetry/testing.
 *   - turn.end:        drop the user entry IF it's still interim (orphan), keep
 *                      finalized entries, clear both pointers.
 *   - turn.interrupted: same housekeeping as turn.end. Audio cleanup happens
 *                       in VoiceSession.
 *
 * The store mutates its `entries` array via a fresh snapshot reference on
 * every change so React's referential-equality short-circuit fires.
 */

import type { ConversationSnapshot, TranscriptEntry } from '@/types/conversation';

const EMPTY_SNAPSHOT: ConversationSnapshot = { entries: [] };

class ConversationStore {
	private snapshot: ConversationSnapshot = EMPTY_SNAPSHOT;
	private listeners = new Set<() => void>();
	private currentUserId: string | null = null;
	private currentAssistantId: string | null = null;
	private seq = 0;

	getSnapshot = (): ConversationSnapshot => this.snapshot;

	subscribe = (listener: () => void): (() => void) => {
		this.listeners.add(listener);
		return () => this.listeners.delete(listener);
	};

	handleTranscript(role: 'user' | 'assistant', text: string, partial: boolean): void {
		const pointerKey = role === 'user' ? 'currentUserId' : 'currentAssistantId';
		const currentId = this[pointerKey];
		const entries = [...this.snapshot.entries];

		if (currentId) {
			const idx = entries.findIndex((e) => e.id === currentId);
			if (idx >= 0) {
				entries[idx] = { ...entries[idx]!, text, interim: partial };
			}
		} else {
			const entry: TranscriptEntry = {
				id: this.nextId(),
				role,
				text,
				interim: partial,
				ts: Date.now(),
			};
			entries.push(entry);
			this[pointerKey] = entry.id;
		}

		if (!partial) this[pointerKey] = null;
		this.commit({ entries });
	}

	appendSystem(text: string): void {
		const entry: TranscriptEntry = {
			id: this.nextId(),
			role: 'system',
			text,
			interim: false,
			ts: Date.now(),
		};
		this.commit({ entries: [...this.snapshot.entries, entry] });
	}

	endTurn(): void {
		this.dropOrphanedInterim();
	}

	interruptTurn(): void {
		this.dropOrphanedInterim();
	}

	reset(): void {
		this.currentUserId = null;
		this.currentAssistantId = null;
		this.commit(EMPTY_SNAPSHOT);
	}

	private dropOrphanedInterim(): void {
		const orphan = this.currentUserId;
		let entries = this.snapshot.entries;
		if (orphan) {
			const idx = entries.findIndex((e) => e.id === orphan);
			if (idx >= 0 && entries[idx]!.interim) {
				entries = entries.filter((e) => e.id !== orphan);
			}
		}
		this.currentUserId = null;
		this.currentAssistantId = null;
		this.commit({ entries: [...entries] });
	}

	private commit(next: ConversationSnapshot): void {
		this.snapshot = next;
		this.listeners.forEach((l) => l());
	}

	private nextId(): string {
		this.seq += 1;
		return `t-${Date.now()}-${this.seq}`;
	}
}

export const conversationStore = new ConversationStore();
export type { ConversationStore };
