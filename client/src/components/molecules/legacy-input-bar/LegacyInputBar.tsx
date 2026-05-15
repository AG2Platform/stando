import { useEffect, useState, type KeyboardEvent } from 'react';

/**
 * "Type a message…" + Send button row from the legacy bottom panel.
 * Pure controlled input — the parent decides what happens on submit
 * (typically: open WS connection, send a `user_input` frame).
 *
 * `initialValue` lets a starter-chip pre-fill the input; once consumed
 * the parent should clear it via `onConsumeInitial` so subsequent typing
 * is editable.
 */

export interface LegacyInputBarProps {
	placeholder?: string;
	onSubmit: (text: string) => void;
	disabled?: boolean;
	initialValue?: string | null;
	onConsumeInitial?: () => void;
}

export default function LegacyInputBar({
	placeholder = 'Type a message…',
	onSubmit,
	disabled = false,
	initialValue,
	onConsumeInitial,
}: LegacyInputBarProps) {
	const [value, setValue] = useState('');

	useEffect(() => {
		if (initialValue && initialValue.length > 0) {
			setValue(initialValue);
			onConsumeInitial?.();
		}
	}, [initialValue, onConsumeInitial]);

	const submit = () => {
		const trimmed = value.trim();
		if (!trimmed) return;
		onSubmit(trimmed);
		setValue('');
	};

	const onKeyDown = (e: KeyboardEvent<HTMLInputElement>) => {
		if (e.key === 'Enter' && !e.shiftKey) {
			e.preventDefault();
			submit();
		}
	};

	return (
		<div className="input-bar">
			<input
				type="text"
				value={value}
				onChange={(e) => setValue(e.target.value)}
				onKeyDown={onKeyDown}
				placeholder={placeholder}
				disabled={disabled}
			/>
			<button className="btn-send" type="button" onClick={submit} disabled={disabled || !value.trim()}>
				Send
			</button>
		</div>
	);
}
