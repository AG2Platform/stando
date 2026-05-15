/**
 * App-wide copy strings. Kept in const-values per CLAUDE.md so components
 * stay strictly presentational. When packages/ui ships (PR-D) the cloud
 * + desktop apps can swap in their own copy without touching components.
 */

export const APP_COPY = {
	appName: 'Sutando',
	appTagline: 'Your personal agent.',
	scaffoldNotice:
		'PR-C in progress — voice now connects from /v2. Transcript, task list, and dynamic region migrate in follow-up PRs; the legacy / route still ships those.',
	pageMissing: 'No page matched. Use the nav above to pick one.',
	loading: 'Loading…',
	voiceConnect: 'Connect',
	voiceConnecting: 'Connecting…',
	voiceRequestingMic: 'Requesting mic…',
	voiceLive: 'Live',
	voiceError: 'Error',
	voiceIdle: 'Disconnected',
	voiceClosed: 'Disconnected',
	disconnect: 'Disconnect',
	mute: 'Mute',
	unmute: 'Unmute',
	voiceSessionTitle: 'Voice session',
	voiceSessionHint:
		'Connect to start streaming audio to the voice agent on the same machine. Mute pauses outbound audio without dropping the WebSocket.',
	agentStatusTitle: 'Server view',
	agentStatusHint:
		"What voice-agent.ts reports about its own connection state — independent of this browser's mic capture.",
	transcriptTitle: 'Transcript',
	transcriptHint:
		'Live user + assistant transcript. Server-final entries can be copied; in-progress lines fade in as the model speaks.',
	transcriptEmpty: 'No transcript yet — connect and speak to populate.',
	taskListTitle: 'Tasks',
	taskListEmpty: 'No tasks yet — drop something via Discord, Telegram, or the voice agent.',
	taskListAllDoneHidden: 'All tasks complete (hidden). Toggle "show done" to reveal.',
	taskShowDetails: 'Show details ▸',
	taskHideDetails: 'Hide ▾',
	taskShowDone: 'show done',
	taskHideDone: 'hide done',
	taskCollapseAll: 'collapse all',
	taskExpandAll: 'expand all',
	taskSystemBrainOffline: 'brain offline',
	taskSystemWatcherOffline: 'watcher offline',
	taskReplyPlaceholder: 'Type a reply…',
	taskReplyPlaceholderOrType: 'or type a reply…',
	taskReplySend: 'Send',
	taskReplySending: 'Sending…',
	taskReplySent: 'Replied:',
	taskReplyFailed: 'Reply failed —',
	questionsTitle: 'Pending questions',
	questionPlaceholder: 'Or type a response…',
	questionSend: 'Send',
	questionSending: 'Sending…',
	questionAnswered: 'Answered:',
	questionFailed: 'Answer failed —',
} as const;

export type VoiceStatusKey =
	| 'voiceIdle'
	| 'voiceConnecting'
	| 'voiceRequestingMic'
	| 'voiceLive'
	| 'voiceError'
	| 'voiceClosed';
