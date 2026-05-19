# Known Issues

## macos-use overlay stuck on screen ("AI: … — press Esc to cancel")

**Symptom:** A dark pill banner reading "AI: &lt;tool name&gt; — press Esc to cancel" appears on screen and cannot be dismissed by pressing Esc or clicking away.

**Cause:** The macos-use MCP server (`InputGuard.swift`) shows a full-screen overlay when performing automation. Its 30-second watchdog fires on a background GCD queue and calls `hideOverlay()`, which dispatches back to the main queue via `DispatchQueue.main.async`. If the main run loop is idle/not draining (common in the Swift concurrency MCP server context), the async block never executes and the overlay persists indefinitely.

**Workaround:** Kill the stale macos-use MCP server process:
```bash
kill $(pgrep mcp-server-macos-use)
```
This destroys the NSWindow immediately. The process will be restarted automatically by Claude Code on next use.

**Fix:** `build.sh` applies a patch that (a) fires the watchdog directly on the main queue using `DispatchWorkItem` + `asyncAfter` so no cross-queue dispatch is needed, and (b) adds `CFRunLoopWakeUp` in `hideOverlay()` as a belt-and-suspenders guard. Rebuild with `bash skills/macos-use/scripts/build.sh --force` to pick up the fix. The upstream fix is tracked at [mediar-ai/mcp-server-macos-use](https://github.com/mediar-ai/mcp-server-macos-use).

**Status:** Patched in `build.sh`. Upstream PR pending.

## Task status flickers in web UI after API restart

**Symptom:** Tasks briefly show as "working" then "done" then "working" again in the web client task list after the agent API is restarted.

**Cause:** The agent API stores task history in memory. Restarting it wipes the history, so it rebuilds state from disk on the next poll. If result files were cleaned up before the restart, those tasks lose their "done" status.

**Workaround:** Wait ~5 minutes — the reconciliation logic cleans up stale entries automatically. Or refresh the page after the API stabilizes.

**Status:** By design. Persisting task history to disk would fix this but adds complexity for a rare event.

## Voice agent (Gemini) hallucinates more than Claude Code

The voice/phone agent uses Gemini Live, which hallucinates more than Claude Code — it may say "done" without actually doing the task, or fabricate details instead of looking them up.

## Gemini Live idle timeout (~15 minutes)

**Symptom:** Voice connection drops after ~15 minutes of silence. The web client shows "Connection lost — reconnecting."

**Cause:** Gemini Live sessions have an inactivity timeout. If no audio is sent for ~15 minutes, Google closes the WebSocket.

**Workaround:** The voice agent auto-reconnects when the client reconnects. Click "Start Voice" again or wait for auto-reconnect (3 seconds).

**Status:** Expected behavior from Gemini Live API. The voice agent detects dead sessions and triggers reconnect automatically.

