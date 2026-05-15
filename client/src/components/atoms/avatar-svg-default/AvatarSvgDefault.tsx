/**
 * Inline-SVG default avatar — the "S" glyph used when no custom avatar has
 * been generated. Ported from src/web-client-html.ts. Animation is driven
 * entirely by `.s-{state}` classes on a parent container (see legacy.css).
 */
export default function AvatarSvgDefault() {
	return (
		<svg className="avatar-svg-default" viewBox="-50 -50 100 100" xmlns="http://www.w3.org/2000/svg">
			<circle className="halo" cx="0" cy="0" r="32" />
			<circle className="halo" cx="0" cy="0" r="32" />
			<circle className="halo" cx="0" cy="0" r="32" />
			<text
				className="stand-glyph"
				x="0"
				y="20"
				textAnchor="middle"
				fontFamily="-apple-system, system-ui, sans-serif"
				fontSize="58"
				fontWeight="500"
			>
				S
			</text>
			<circle className="orbit-dot" cx="0" cy="0" r="2.2" />
			<circle className="orbit-dot" cx="0" cy="0" r="1.6" />
			<rect className="scan-beam" x="-3" y="-30" width="6" height="8" rx="1" />
		</svg>
	);
}
