import type { Toast } from '@/types/toast';

export interface ToastItemProps {
	toast: Toast;
	onDismiss: (id: string) => void;
}

/**
 * Single toast pill. Uses the legacy `.toast` class so legacy.css drives
 * the entry/exit animation (toastIn / toastOut). Per-kind border colors
 * are layered on top of the default green palette.
 */
const BORDER_BY_KIND: Record<Toast['kind'], string> = {
	info: '#2a4a36',
	success: '#2a4a36',
	warning: '#f0ad4e88',
	error: '#e9456088',
};

export default function ToastItem({ toast, onDismiss }: ToastItemProps) {
	return (
		<div role="status" className="toast" style={{ borderColor: BORDER_BY_KIND[toast.kind] }}>
			{toast.label ? <span className="toast-label">{toast.label}</span> : null}
			{toast.label ? ' ' : null}
			{toast.message}
			<button
				type="button"
				onClick={() => onDismiss(toast.id)}
				aria-label="Dismiss"
				className="btn-subtle"
				style={{ marginLeft: 8 }}
			>
				×
			</button>
		</div>
	);
}
