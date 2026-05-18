---
name: calendar-prep
description: "Pre-meeting prep: pull attendees + last email thread + previous meeting notes if any + draft talking points + agenda. Voice-callable: 'prep my next meeting', 'who am I meeting with at 3'."
user-invocable: true
---

# Calendar Prep

The 30-minutes-before-a-meeting flow, automated. Reads calendar, finds the upcoming meeting, gathers context for each attendee from recent email + past meeting notes, drafts a one-page prep brief.

Originally the design included a LinkedIn lookup per attendee. Dropped in Phase 6 — Proxycurl shut down July 2025 after a LinkedIn lawsuit and the surviving alternatives carry similar legal risk. LinkedIn context, when available, comes from the user's own email history with the attendee (signature blocks, mutual mentions in threads).

## Triggers

- "Prep my next meeting"
- "What's coming up at [time]"
- "Who am I meeting with at 3"
- "Help me prep for [topic / name]"

## Inputs

- `target` (optional): time ("3pm"), title fragment ("standup"), or attendee name. Without this, defaults to the next meeting on the calendar.

## Steps

### 1. Find the meeting

```bash
gws calendar +agenda --days 1 --format json
```

Match by:
- If `target` is a time ("3pm", "in an hour", "next meeting") — find first event whose start ≥ now and matches.
- If `target` is a fragment — substring match on event title or attendee name.
- If no `target` — first event with start ≥ now.

If no upcoming events: "Your calendar's clear for the rest of today. Want me to look ahead?"

### 2. Extract attendees

From the matched event, parse `attendees[].email` (Google Calendar JSON). Skip the user's own email + room resources (anything ending in `@resource.calendar.google.com` or matching the user's domain). For each remaining attendee, also note `displayName` if present.

For each attendee, try to resolve a "human name" via:
```bash
python3 ~/.claude/skills/macos-tools/scripts/contacts.py search "EMAIL"
```
If contacts hit, use their name. If not, use displayName, or fall back to the local-part of the email.

### 3. Pull recent email context (per attendee)

For each attendee, find the latest email thread:
```bash
gws gmail users messages list --params "q=from:EMAIL OR to:EMAIL" --params "maxResults=3"
```

Read the most recent message in the result list:
```bash
gws gmail +read MESSAGE_ID
```

Extract:
- Subject of the most recent thread
- 1-2 sentence summary of what was last discussed
- Anything unresolved / pending action

If no email history exists with the attendee, skip silently. First-time meetings get an "(new contact, no prior threads)" tag.

### 4. Find previous meeting notes (best-effort)

```bash
Grep "ATTENDEE_NAME" notes/ --glob "*.md" -l
```

For each matched note file, read the YAML frontmatter `tags` and `title`. If a tag suggests "meeting" / "1:1" / "sync" or the title contains the attendee, surface as "Previous meeting notes: <title> (<date>)".

### 5. Topic context (from the event)

Read:
- `event.summary` — usually the title
- `event.description` — sometimes the agenda is here
- Any linked docs (Google Docs URLs in description)

If the description is empty and the title is generic ("Sync" / "Catch-up"), the agent should ASK the user "What's this meeting about?" rather than guess.

### 6. Draft talking points

Synthesize a brief:

```
Meeting: <title>
Time: <when> (in <relative time>)
Attendees: <name (role if known from email signatures)>

Why you're meeting: <1-line from description, or "needs your input on" if ambiguous>

Context per attendee:
- <Name>: <1-2 lines from email + last-met>

Talking points:
- <bullet 1, derived from open threads / unresolved questions>
- <bullet 2>
- <bullet 3>

Open questions / things to confirm:
- <anything pending from prior threads>
```

Keep voice output conversational: read the synthesis aloud rather than literally speaking the bullet structure. Save the full brief to `notes/prep-<eventId>-<ts>.md` with frontmatter `tags: [meeting, prep, auto-generated]` so the user can refer back.

### 7. Optional follow-on

If the user says "draft the agenda" or "send a pre-meeting email" — defer to the `email-triage` skill's draft mode with the prep brief as context.

## Notes

- All operations are read-only except writing to `notes/`. No calendar edits, no email sends.
- Caches: don't. The point of running 30 min before is freshness.
- Token-budget guard: cap email body reads at 4 KB per message — long threads get truncated. If the attendee has 10+ recent threads, only read the latest 2.

## Voice routing

`documented_for_core: true` — voice agent surfaces this skill description to Gemini, which delegates to core via `work`. Output goes to `results/proactive-<ts>.txt`.
