import logoUrl from '@/assets/sutando-logo.png';

/**
 * Sutando brand mark — the canonical Sutando logo, sourced from
 * `app/branding/menubar-source.png` and bundled into the client via
 * Vite asset hashing. Same image powers the macOS menubar template and
 * the .app icon, so desktop chrome and the web UI share one identity.
 *
 * The logo is white-on-transparent, so it sits cleanly on both the dark
 * and light variants of `var(--bg)`. On light mode we drop a subtle
 * mix-blend so the white strokes inherit the foreground tint instead of
 * blowing out against a light surface.
 */

export interface BrandMarkProps {
	/** Pixel size of the rendered logo. Defaults to 22 (top-bar height). */
	size?: number;
	alt?: string;
}

export default function BrandMark({ size = 22, alt = 'Sutando' }: BrandMarkProps) {
	return (
		<img
			src={logoUrl}
			alt={alt}
			width={size}
			height={size}
			className="block select-none object-contain"
			style={{ height: size, width: size }}
			draggable={false}
		/>
	);
}
