/**
 * The "⌃C drop context | ⌃S drop screenshot | ⌃V voice | ⌃M mute" bar
 * from the legacy. Reads as a visual hint — hotkeys are bound globally
 * by the macOS menu-bar app (src/Sutando/main.swift), not by this page.
 */

const SHORTCUTS: readonly { keys: string; label: string }[] = [
	{ keys: '⌃C', label: 'drop context' },
	{ keys: '⌃S', label: 'drop screenshot' },
	{ keys: '⌃V', label: 'voice' },
	{ keys: '⌃M', label: 'mute' },
];

export default function KeyboardShortcutsBar() {
	return (
		<div className="status-bar">
			{SHORTCUTS.map((shortcut) => (
				<span key={shortcut.keys}>
					<kbd>{shortcut.keys}</kbd> {shortcut.label}
					<span className="sep">|</span>
				</span>
			))}
		</div>
	);
}
