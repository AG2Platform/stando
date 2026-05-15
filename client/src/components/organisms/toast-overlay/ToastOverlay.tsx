import ToastItem from '@/components/atoms/toast-item';
import { toastActions, useToasts } from '@/hooks/useToasts';

/**
 * Floating toast stack rendered once at the app shell level. Toasts
 * self-expire via the store; this organism just reflects the live list.
 * Bottom-right positioning matches the legacy #toast-container.
 */
export default function ToastOverlay() {
	const { toasts } = useToasts();
	if (toasts.length === 0) return null;
	return (
		<div className="toast-container">
			{toasts.map((toast) => (
				<ToastItem key={toast.id} toast={toast} onDismiss={toastActions.dismiss} />
			))}
		</div>
	);
}
