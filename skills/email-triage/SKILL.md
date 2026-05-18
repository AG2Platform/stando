---
name: email-triage
description: "Triage Gmail inbox by urgency and draft replies. Voice-callable: 'triage my inbox', 'what's urgent', 'draft a reply to X', 'send the draft'."
user-invocable: true
---

# Email Triage

Inbox triage + draft generation. Replaces the manual "scroll inbox, read each, decide what matters" flow with a 3-tier urgency classification plus on-demand reply drafting.

## Modes

The user's verb determines the mode — listen for it.

### 1. Triage (read-only summary)

Triggers: "triage my inbox", "what's urgent", "what's new", "any important email", "check my email".

Run:
```bash
gws gmail +triage 2>/dev/null
```

For each unread thread:
- Skip if sender is a known newsletter / bot (look at `Sender` and `Subject` patterns: "noreply@", "newsletter", "[Bot]", "Unsubscribe" in body).
- Classify into:
  - **🔴 Urgent**: time-sensitive request from a known human, deadline mentioned in subject/body, "ASAP", "today", "RSVP by", calendar invites needing accept/decline.
  - **🟡 Worth knowing**: human sender, substantive content, but no immediate action needed.
  - **🟢 Skim**: routine updates, FYIs.

Voice output: "You have N urgent: [one-line per item, sender + ask]. Then M worth-knowing: [sender + topic]. The rest is routine." Cap urgent at 3, worth-knowing at 3. Don't list routine.

### 2. Read one thread

Triggers: "read me [name]'s email", "what did [name] say", "open the [topic] email".

Run:
```bash
gws gmail users messages list --params 'q=from:NAME OR subject:TOPIC' --params 'maxResults=1'
# Then read that message ID:
gws gmail +read MESSAGE_ID
```

Voice output: speak the body conversationally. Skip quoted text and signatures.

### 3. Draft a reply

Triggers: "draft a reply to [name]", "respond to [name]", "answer the [topic] email".

Steps:
1. Find the thread via `gws gmail users messages list --params 'q=...'`
2. Read the latest message: `gws gmail +read MESSAGE_ID`
3. Compose a draft in the user's voice — read `$SUTANDO_MEMORY_DIR/user_profile.md` for tone preferences first.
4. Save the draft to `tasks/email-draft-<ts>.txt` with the format:
   ```
   TO: <recipient email>
   SUBJECT: Re: <original subject>
   IN-REPLY-TO: <messageId>
   BODY:
   <draft body>
   ```
5. Speak the draft back to the user for review.

Do NOT send until the user explicitly confirms with "send it" / "yes send" / "looks good, send".

### 4. Send the draft

Triggers: "send it", "send the draft", "looks good send".

Find the most recent `tasks/email-draft-*.txt`, parse the fields, then:
```bash
gws gmail +send --to "RECIPIENT" --subject "SUBJECT" --body "BODY" --in-reply-to "MESSAGE_ID"
```
Voice output: "Sent." + 1-line summary of what was sent.

If the user says "wait", "change it", "modify" instead — re-enter draft mode with the requested edit.

## Drafting voice — tone notes

Always read `$SUTANDO_MEMORY_DIR/user_profile.md` and `$SUTANDO_MEMORY_DIR/feedback_*.md` before drafting. Match:
- Sentence length (short vs long)
- Formality (Hi vs Hey)
- Sign-off style (Best, vs Cheers, vs none)
- Comma vs em-dash habits

Default if no profile: terse, no buzzwords, lead with the ask not the context.

## Limits

- One thread at a time per draft cycle (no bulk reply).
- Sender lookup is text-match (`q=from:NAME`); for common names, ask the user to disambiguate ("Sarah K. or Sarah W.?").
- Read-only operations don't touch the inbox. Draft creation writes to `tasks/`. Send is the only mutating action and requires explicit confirmation.

## Voice routing

`documented_for_core: true` — voice agent surfaces this to Gemini, which delegates to core via `work`. Output goes to `results/proactive-<ts>.txt` for voice; the file-bridge picks it up.
