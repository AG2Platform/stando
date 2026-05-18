import { useSyncExternalStore } from 'react';
import { conversationStore } from '@/lib/conversation-store';
import type { ConversationSnapshot } from '@/types/conversation';

/**
 * Subscribe to the shared conversation store. Snapshot identity is
 * preserved unless the store actually mutated, so consumers re-render
 * only when transcript content changes.
 */
export function useConversation(): ConversationSnapshot {
	return useSyncExternalStore(conversationStore.subscribe, conversationStore.getSnapshot, conversationStore.getSnapshot);
}
