import AvatarSvgDefault from '@/components/atoms/avatar-svg-default';

/**
 * Big animated orb used at the top of the conversation hero. Wraps the
 * generated PNG avatar (or the inline SVG default) in the `.s-{state}`
 * class chain so the legacy.css ring + halo animations keep working.
 *
 * Visual layering:
 *   .voice-orb               positioning + state class (kept as a marker
 *                            for legacy avatar animations)
 *   .voice-orb-halo          ::before-style soft glow (now a sibling div
 *                            so the styling is plain Tailwind)
 *   .voice-orb-inner         circular surface holding the SVG/img
 */

export type VoiceOrbState = 'idle' | 'listening' | 'speaking' | 'working' | 'seeing';

export interface VoiceOrbProps {
	agentState: VoiceOrbState;
	avatarPngUrl?: string;
	alt?: string;
}

export default function VoiceOrb({ agentState, avatarPngUrl, alt = 'Sutando' }: VoiceOrbProps) {
	return (
		<div className={`voice-orb relative mb-6 flex h-[116px] w-[116px] items-center justify-center s-${agentState}`}>
			<div
				aria-hidden
				className="pointer-events-none absolute -inset-3 z-0 rounded-full bg-(--text)/8 blur-lg"
			/>
			<div
				className="voice-orb-inner relative z-10 flex h-full w-full items-center justify-center overflow-hidden rounded-full border border-(--border) bg-(--surface-elev) shadow-[inset_0_1px_0_rgba(255,255,255,0.04),0_24px_60px_-30px_rgba(0,0,0,0.55)]"
			>
				{avatarPngUrl ? (
					<img src={avatarPngUrl} alt={alt} className="h-full w-full rounded-full object-cover" />
				) : (
					<div className="h-[78%] w-[78%]">
						<AvatarSvgDefault />
					</div>
				)}
			</div>
		</div>
	);
}
