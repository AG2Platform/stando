export interface PageHeaderProps {
	title: string;
	hint?: string;
}

export default function PageHeader({ title, hint }: PageHeaderProps) {
	return (
		<header className="border-b border-neutral-900/80 px-6 py-4">
			<h1 className="text-lg font-semibold text-[color:var(--color-text)]">{title}</h1>
			{hint ? <p className="mt-1 text-sm text-[color:var(--color-text-mute)]">{hint}</p> : null}
		</header>
	);
}
