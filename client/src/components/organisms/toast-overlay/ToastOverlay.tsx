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
		<div className="pointer-events-none fixed bottom-4 right-4 z-50 flex flex-col gap-2">
			{toasts.map((toast) => (
				<div key={toast.id} className="pointer-events-auto">
					<ToastItem toast={toast} onDismiss={toastActions.dismiss} />
				</div>
			))}
		</div>
	);
}
