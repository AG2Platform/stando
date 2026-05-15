/**
 * Lightweight toast store. Auto-expires entries after TOAST_TTL_MS (matches
 * the legacy 4-second linger). Subscribers re-render the toast overlay
 * organism whenever the active toast list changes.
 */

import type { Toast, ToastKind, ToastSnapshot } from '@/types/toast';

const TOAST_TTL_MS = 4000;
const EMPTY: ToastSnapshot = { toasts: [] };

class ToastStore {
	private snapshot: ToastSnapshot = EMPTY;
	private listeners = new Set<() => void>();
	private seq = 0;

	getSnapshot = (): ToastSnapshot => this.snapshot;

	subscribe = (listener: () => void): (() => void) => {
		this.listeners.add(listener);
		return () => this.listeners.delete(listener);
	};

	push(kind: ToastKind, message: string, label?: string): string {
		this.seq += 1;
		const id = `toast-${Date.now()}-${this.seq}`;
		const toast: Toast = { id, kind, message, label, createdAt: Date.now() };
		this.commit({ toasts: [...this.snapshot.toasts, toast] });
		window.setTimeout(() => this.dismiss(id), TOAST_TTL_MS);
		return id;
	}

	dismiss(id: string): void {
		const next = this.snapshot.toasts.filter((t) => t.id !== id);
		if (next.length === this.snapshot.toasts.length) return;
		this.commit({ toasts: next });
	}

	private commit(next: ToastSnapshot): void {
		this.snapshot = next;
		this.listeners.forEach((l) => l());
	}
}

export const toastStore = new ToastStore();
