export interface DecisionOptionButtonProps {
	option: string;
	disabled?: boolean;
	onSelect: (option: string) => void;
}

export default function DecisionOptionButton({ option, disabled, onSelect }: DecisionOptionButtonProps) {
	return (
		<button
			type="button"
			disabled={disabled}
			onClick={() => onSelect(option)}
			className="rounded-md border border-emerald-500/40 bg-emerald-500/[0.08] px-2.5 py-1 text-xs text-emerald-200 transition-colors hover:bg-emerald-500/15 hover:text-emerald-100 disabled:opacity-50"
		>
			{option}
		</button>
	);
}
