import { useSyncExternalStore } from 'react';
import { toastStore } from '@/lib/toast-store';
import type { ToastSnapshot } from '@/types/toast';

export function useToasts(): ToastSnapshot {
	return useSyncExternalStore(toastStore.subscribe, toastStore.getSnapshot, toastStore.getSnapshot);
}

export const toastActions = {
	push: (kind: Parameters<typeof toastStore.push>[0], message: string, label?: string) =>
		toastStore.push(kind, message, label),
	dismiss: (id: string) => toastStore.dismiss(id),
};
