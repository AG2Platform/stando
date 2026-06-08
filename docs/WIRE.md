# Stando UI Wire Contract

This document is the **contract between any Stando UI and the Stando
backend.** The conversation UI lives in the private
[stando-ui](https://github.com/AG2Platform/stando-ui) repo — it is one
implementation of this contract. A different UI (a branded build, a
different framework, a thin mobile client) swaps itself in by:

1. Building its own bundle (any framework — React, Vue, Svelte, plain
   HTML, doesn't matter).
2. Pointing the voice-agent process at it:
   ```bash
   CLIENT_DIST_DIR=/abs/path/to/your/dist bash src/startup.sh
   ```
3. Honoring the wire contract below.

The server side never has to change.

---

## Runtime topology

Four local origins make up the runtime:

| Origin | Default | Owner | Lifetime |
|---|---|---|---|
| `apiOrigin` | `http://<host>:8080` | `src/web-server.ts` (Node, in-process with voice-agent) | Voice-agent process |
| `agentApiOrigin` | `http://<host>:7843` | `src/agent-api.py` (Python) | Separate process |
| `wsUrl` | `ws://<host>:9900` | bodhi `VoiceSession` (Node, in voice-agent) | Voice-agent process |
| dashboard | `http://<host>:7844` | `src/dashboard.py` (Python) | Separate process, optional |

A UI can override all four via query string or `window.__SUTANDO_CONFIG__`
injection — see `stando-ui/src/lib/config.ts` for the resolution shape.
The defaults assume the standard `bash src/startup.sh` topology.

---

## Endpoints the UI calls

### `apiOrigin` — conversation HTTP server (port 8080)

| Method | Path | Purpose | Response shape |
|---|---|---|---|
| GET | `/sse` | Long-lived SSE stream. Emits `agent-state`, `toggle-voice`, `toggle-mute` events. See **SSE events** below. | `text/event-stream` |
| GET | `/sse-status` | One-shot status snapshot used on page load. | `{ clients: number, muted: boolean, voiceConnected: boolean, state: AgentState, label: string }` |
| GET | `/voice-mode` | Voice agent's current mode sentinel. | `{ mode: 'active' \| 'meeting' }` |
| GET | `/mute-state?muted=…&voice=…&state=…&source=…&label=…&ttl_ms=…` | Mute / voice-connected / agent-state report. Used by the menu-bar HUD to draw the recording indicator. Accepts any subset of params. | `{ ok: true }` (best-effort) |
| GET | `/vision/state` | Current vision-streaming state. | `{ streaming, source, fps, frames, durationMs, sessionReady }` |
| POST | `/vision/start` | Body: `{ source: 'browser' }`. Tell the agent we're about to push frames. | `{ status: string, error?: string }` |
| POST | `/vision/stop` | Body: `{}`. Tear down the stream. | `{ status: string }` |
| POST | `/vision/frame` | Body: raw JPEG bytes (`Content-Type: image/jpeg`). One captured frame. | `{ ok: boolean }` |
| POST | `/note-viewing` | Body: `{ path?: string, slug?: string }`. Tell the agent the user is looking at a note (powers proactive context). | `{ ok: true }` |

### `agentApiOrigin` — Python agent API (port 7843)

| Method | Path | Purpose | Response shape |
|---|---|---|---|
| GET | `/ping` | Liveness probe. | `{ pong: true }` |
| GET | `/core-status` | Proactive-loop status, drives the "Core: idle / Core: running…" indicator. | `{ status: 'idle' \| 'running', step?: string }` |
| GET | `/dynamic-content` | Server-pushed content card (audio / image / video / document / html). Empty `{}` when nothing to show. | `{ type, title?, caption?, src?, content? }` |
| GET | `/contextual-chips` | Suggestion chips to seed the composer. | `{ chips: string[] }` |
| GET | `/tasks/active` | Active task list + bridge health. Poll every ~3s. | `ApiTasksResponse` (see `stando-ui/src/types/task.ts`) |
| GET | `/result/:taskId` | Poll the result of a task submitted via POST `/task`. | `{ status: 'pending' \| 'completed' \| 'error', result?: string }` |
| GET | `/activity` | Recent commits + tasks for the Activity panel. | `{ activity: ActivityItem[] }` |
| GET | `/notes` | Notes index. | `{ notes: NoteSummary[] }` |
| GET | `/notes/:slug` | Single note body. | `{ slug, body, ... }` |
| GET | `/media/:path` | Static media file (image/audio/video) referenced by `/dynamic-content`. `:path` is sanitized and constrained to the workspace. | binary |
| POST | `/task` | Body: `{ from: string, task: string }`. Submit a free-form task (`from: 'web'`) or a reply (`from: 'web-reply:<taskId>'`). | `{ ok: boolean, task_id?: string, error?: string, kind?: 'bridge-down' \| 'task-error' }` |
| POST | `/answer` | Body: `{ id: string, answer: string }`. Resolve a pending question. | `{ ok: boolean, error?: string }` |
| POST | `/notes/:slug` | Body: note content. Save a note. | `{ ok: true }` |

### dashboard (port 7844, optional)

| Method | Path | Purpose | Response shape |
|---|---|---|---|
| GET | `/stand-identity` | User's custom name + avatar choice. Failure-safe — UI must default to "Sutando" + the inline SVG when unreachable. | `{ name?, nameOrigin?, avatarGenerated?, avatarUrl? }` |
| GET | `/avatar` | Generated avatar PNG when `avatarGenerated === true`. | image/png |

### WebSocket (port 9900)

The voice session itself. UI opens one WS to `wsUrl` and uses bodhi
client semantics. See `stando-ui/src/lib/voice-session.ts` and the
[bodhi-realtime-agent docs](https://github.com/sutando-ai/bodhi-realtime-agent)
for the protocol — bidirectional audio + transcript + tool events.

---

## SSE events (on `${apiOrigin}/sse`)

The server emits **named** SSE events. Replacement UIs must subscribe to
the same event names:

| Event | Data | Meaning |
|---|---|---|
| `agent-state` | one of `idle` \| `listening` \| `speaking` \| `working` \| `seeing` | Drive any "what is Sutando doing right now" affordance (avatar ring, status pill, etc.). |
| `toggle-voice` | (empty) | Global ⌃V hotkey was hit. UI should call its "start or stop voice" handler. |
| `toggle-mute` | (empty) | Global ⌃M hotkey was hit. UI should flip mute. |

Reconnect on transport error (browsers throttle background SSE) — see
`stando-ui/src/hooks/useAgentSse.ts` for a reference reconnect loop with
visibility-driven recovery.

---

## What the server expects FROM the UI

The contract is symmetric — these are the calls the UI **must** make for
the system to behave correctly:

1. **Mute / voice state sync**: when the UI's voice connects/disconnects
   or the user mutes, POST `apiOrigin/mute-state?…` so the menu-bar HUD
   stays in sync.
2. **Hotkey honoring**: subscribe to `toggle-voice` / `toggle-mute` SSE
   events and act on them — this is how the system-wide ⌃V / ⌃M
   shortcuts reach the page.
3. **Task result polling**: after POST `/task` succeeds with a `task_id`,
   poll GET `/result/:taskId` until `status !== 'pending'`.
4. **Avatar fallback**: when `/stand-identity` is unreachable, default
   to "Sutando" + a built-in placeholder. The dashboard is optional and
   the UI must not break without it.
5. **Failure-safety**: every poll endpoint should silent-fail. A missing
   sentinel (`/voice-mode`) means "not active," not "error."

---

## Versioning policy

The wire contract follows server-side conventions:

- **Additive changes** (new endpoints, new optional fields, new SSE event
  names) don't bump anything — older clients just ignore them.
- **Breaking changes** to existing shapes are *avoided*. When they're
  necessary, the server adds a new endpoint and keeps the old one for at
  least one release.
- The contract version is implicitly tied to the server version. Pin the
  stando-ui build to a known-good voice-agent commit and bump with intent.

---

## Reference implementation

The stando-ui repo is the reference implementation. Things worth copying
when building a replacement UI:

- `src/lib/config.ts` — the `?ws=…&api=…&agent-api=…` query-string
  override pattern + `window.__SUTANDO_CONFIG__` injection.
- `src/lib/voice-session.ts` — bodhi WebSocket wiring.
- `src/hooks/useAgentSse.ts` — SSE consumer with visibility-driven
  reconnect.
- `src/lib/api.ts`, `tasks-api.ts`, `questions-api.ts`, `notes-api.ts` —
  typed wrappers for every endpoint above.

If you build a replacement and find the contract under-specified, please
open an issue or PR against this file.
