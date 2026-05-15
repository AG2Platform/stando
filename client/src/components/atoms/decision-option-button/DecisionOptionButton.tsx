export interface DecisionOptionButtonProps {
	option: string;
	disabled?: boolean;
	onSelect: (option: string) => void;
}

// Tint Yes / No specially per the legacy `.q-btn.q-yes/.q-no` rules.
function variantClass(option: string): string {
	const normalized = option.trim().toLowerCase();
	if (normalized === 'yes') return 'q-btn q-yes';
	if (normalized === 'no') return 'q-btn q-no';
	return 'q-btn';
}

export default function DecisionOptionButton({ option, disabled, onSelect }: DecisionOptionButtonProps) {
	return (
		<button
			type="button"
			className={variantClass(option)}
			disabled={disabled}
			onClick={() => onSelect(option)}
		>
			{option}
		</button>
	);
}
