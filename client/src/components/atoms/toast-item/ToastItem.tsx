import type { Toast } from '@/types/toast';

export interface ToastItemProps {
	toast: Toast;
	onDismiss: (id: string) => void;
}

const TONE: Record<Toast['kind'], string> = {
	info: 'border-neutral-700/60 bg-neutral-900/95 text-[color:var(--color-text)]',
	success: 'border-emerald-500/40 bg-emerald-500/15 text-emerald-100',
	warning: 'border-amber-500/40 bg-amber-500/15 text-amber-100',
	error: 'border-rose-500/40 bg-rose-500/15 text-rose-100',
};

export default function ToastItem({ toast, onDismiss }: ToastItemProps) {
	return (
		<div
			role="status"
			className={`flex max-w-sm items-start gap-2 rounded-md border px-3 py-2 text-xs shadow-lg backdrop-blur ${TONE[toast.kind]}`}
		>
			<div className="flex-1">
				{toast.label ? <span className="mr-1 font-semibold uppercase tracking-wide opacity-80">{toast.label}</span> : null}
				<span>{toast.message}</span>
			</div>
			<button
				type="button"
				onClick={() => onDismiss(toast.id)}
				aria-label="Dismiss"
				className="text-[color:var(--color-text-mute)] hover:text-[color:var(--color-text)]"
			>
				×
			</button>
		</div>
	);
}
