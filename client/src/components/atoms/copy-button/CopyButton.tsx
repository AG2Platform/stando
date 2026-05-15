import { useCallback, useEffect, useRef, useState } from 'react';

export interface CopyButtonProps {
	value: string;
	idleLabel?: string;
	copiedLabel?: string;
}

const COPIED_MS = 1500;

export default function CopyButton({ value, idleLabel = 'Copy', copiedLabel = 'Copied' }: CopyButtonProps) {
	const [copied, setCopied] = useState(false);
	const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

	useEffect(
		() => () => {
			if (timerRef.current) clearTimeout(timerRef.current);
		},
		[]
	);

	const onClick = useCallback(
		async (e: React.MouseEvent) => {
			e.stopPropagation();
			try {
				await navigator.clipboard.writeText(value);
			} catch {
				/* clipboard may be denied in iframes — fail silently to mirror legacy UX */
			}
			setCopied(true);
			if (timerRef.current) clearTimeout(timerRef.current);
			timerRef.current = setTimeout(() => setCopied(false), COPIED_MS);
		},
		[value]
	);

	return (
		<button
			type="button"
			onClick={onClick}
			className="rounded px-1.5 py-0.5 text-[10px] uppercase tracking-wide text-[color:var(--color-text-mute)] opacity-0 transition-opacity hover:bg-neutral-800/60 hover:text-[color:var(--color-text)] focus:opacity-100 group-hover:opacity-100"
		>
			{copied ? copiedLabel : idleLabel}
		</button>
	);
}
