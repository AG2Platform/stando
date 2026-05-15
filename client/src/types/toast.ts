export type ToastKind = 'info' | 'success' | 'warning' | 'error';

export interface Toast {
	id: string;
	kind: ToastKind;
	label?: string;
	message: string;
	createdAt: number;
}

export interface ToastSnapshot {
	toasts: readonly Toast[];
}
