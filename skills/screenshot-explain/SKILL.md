---
name: screenshot-explain
description: "Capture the current screen and ask Gemini to answer a question about it. Use when the user says 'what does this mean', 'explain this error', 'what's this chart showing', 'help me with this' — anything where the answer depends on what's currently visible."
user-invocable: true
---

# Screenshot Explain

Voice-native screen Q&A. The user is looking at something — an error message, a chart, a contract clause, a UI they're stuck on — and asks a question. We capture, send to Gemini Vision, and speak the answer.

This is Sutando's killer demo: one keystroke + voice question collapses the manual screenshot → drag → upload → wait flow that web GPTs require.

## When to Use

- **Errors**: "What does this Postgres error mean?", "why is this build failing?"
- **Charts / dashboards**: "What's this graph showing?", "is this metric good or bad?"
- **Contracts / forms**: "What does this clause obligate me to?", "is anything weird here?"
- **UI assistance**: "What button do I click?", "how do I undo this?"
- **Reading help**: "Summarize what's on screen", "translate this", "read this aloud"

## Voice tool

`screenshot_explain(question, display?)` — captures the screen (all displays by default) and returns Gemini's answer to the user's question.

- `question` (string, required): The user's question. Quote the user verbatim when possible.
- `display` (number, optional): 1=main, 2=secondary. Omit to capture all displays.

The capture runs against `http://localhost:7845/capture` (Sutando's in-process screen-capture supervisor — bundled with the .app, always running). No screenshots leave the user's Mac except the resized JPG sent to Gemini through the cloud gateway.

## Privacy

- Screenshots are resized to 800px wide before transit (saves bandwidth and reduces accidental leakage of high-res details).
- Pixels go to Sutando's managed Gemini gateway when signed in, or BYO `GEMINI_API_KEY` when not.
- No on-disk persistence beyond the capture supervisor's temp dir (cleared on app quit).

## Limitations

- Whole-display capture only in v1. Region-select lands in a follow-up once the macOS interactive-capture flow is wired into the supervisor.
- Multimodal answers (vision-only Q&A) — for questions that need text from outside the screen (e.g. "what is this thing, in general?"), prefer the regular voice path instead.
