import KbdHint from '@/components/atoms/kbd-hint';
import { APP_COPY } from '@/const-values/app-copy';

/**
 * The four global hotkeys announced visually under the hero. Hotkeys
 * themselves are bound by the Sutando macOS menu-bar app; this row is
 * purely a hint — same as the legacy status-bar.
 */

const SHORTCUTS: readonly { keys: string; label: string }[] = [
	{ keys: '⌃C', label: APP_COPY.convShortcutDropContext },
	{ keys: '⌃S', label: APP_COPY.convShortcutDropScreenshot },
	{ keys: '⌃V', label: APP_COPY.convShortcutVoice },
	{ keys: '⌃M', label: APP_COPY.convShortcutMute },
];

export default function KbdHintsRow() {
	return (
		<div className="-mt-2 flex flex-wrap justify-center gap-2.5" aria-label="Keyboard shortcuts">
			{SHORTCUTS.map((s) => (
				<KbdHint key={s.keys} keys={s.keys} label={s.label} />
			))}
		</div>
	);
}
