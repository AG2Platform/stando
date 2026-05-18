import type { TranscriptMedia } from '@/types/conversation';

export interface TranscriptMediaViewProps {
	media: TranscriptMedia;
}

const DEFAULT_MIME: Record<TranscriptMedia['type'], string> = {
	image: 'image/png',
	video: 'video/mp4',
};

const downloadName = (media: TranscriptMedia): string => {
	const ext = (media.mimeType ?? DEFAULT_MIME[media.type]).split('/')[1] ?? media.type;
	return `generated-${media.type}-${Date.now()}.${ext}`;
};

/**
 * Inline image / video renderer for gui.update payloads. Builds the data
 * URL once per mount — base64 strings can be MB-large, so re-running the
 * concat on every render would be wasteful.
 */
export default function TranscriptMediaView({ media }: TranscriptMediaViewProps) {
	const mime = media.mimeType ?? DEFAULT_MIME[media.type];
	const dataUrl = `data:${mime};base64,${media.base64}`;

	return (
		<div className="mt-2 space-y-1">
			{media.type === 'image' ? (
				<img src={dataUrl} alt={media.description ?? 'Generated image'} className="max-w-full rounded-md" />
			) : (
				<video src={dataUrl} controls autoPlay muted className="max-w-full rounded-md" />
			)}
			<a
				href={dataUrl}
				download={downloadName(media)}
				className="inline-block text-[11px] uppercase tracking-wide text-[color:var(--color-text-mute)] hover:text-[color:var(--color-text)]"
			>
				Download {media.type}
			</a>
		</div>
	);
}
