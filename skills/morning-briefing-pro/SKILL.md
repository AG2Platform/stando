---
name: morning-briefing-pro
description: "Conversational morning briefing — calendar + email + reminders + weather + overnight Discord/Telegram + daily insight, delivered in a voice-friendly narrative (not a list)."
user-invocable: true
---

# Morning Briefing Pro

Premium morning briefing. Extends the basic `morning-briefing` skill with weather, reminders, conversational narrative output (instead of a bullet list), and a tunable depth knob (brief / standard / detailed).

**Voice trigger**: "morning briefing", "give me the morning rundown", "what should I know today", "kick off my morning".

## Voice routing

The voice agent surfaces this skill to Gemini via `documented_for_core`. When called, the agent writes a work-task to the bridge; the core agent runs through the steps below and writes the spoken result to `results/proactive-<ts>.txt`.

## Inputs

- `depth` (optional, default `standard`):
  - `brief` — 1 short paragraph, 20s spoken
  - `standard` — 2-3 paragraphs, 45-60s spoken
  - `detailed` — full narrative with sub-items, 90-120s spoken

## Steps

Run the gathering steps in parallel where possible, then synthesize.

### 1. Calendar
```bash
gws calendar +agenda --today --format json 2>/dev/null || gws calendar +agenda --today
```
Note the first 3 meetings: time, attendees (first names only for voice), one-line topic.

### 2. Email triage
```bash
gws gmail +triage 2>/dev/null
```
Pick the top 3 unread by urgency. Skip newsletters / bot mail. For each: sender + 1-sentence summary.

### 3. Reminders (macOS)
```bash
python3 ~/.claude/skills/macos-tools/scripts/reminders.py list 2>/dev/null
```
Anything due today or overdue. Skip the rest.

### 4. Weather (Open-Meteo, free, no key)
Detect the user's location from system timezone or the `LOCATION` env var if set. Use the Bash tool to fetch:
```bash
LAT_LON="$(LATITUDE_LONGITUDE_FOR_USER)"  # e.g. "37.77,-122.42" — SF default
curl -s "https://api.open-meteo.com/v1/forecast?latitude=${LAT_LON%%,*}&longitude=${LAT_LON##*,}&current=temperature_2m,weather_code&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max&timezone=auto&forecast_days=1&temperature_unit=fahrenheit"
```
Extract: current temp, today's high/low, precipitation probability. Map `weather_code` to a one-word description (sunny / cloudy / rainy / snowy / stormy). If the curl fails, skip the weather section silently.

### 5. Overnight messages
- Discord: `python3 src/discord-bridge.py --recent --since "8 hours ago" 2>/dev/null` (skip if unavailable)
- Telegram: `tail -n 20 logs/telegram-bridge.log 2>/dev/null | grep -i "from "` (rough — anything actionable from overnight)
Summarize anything that needs the user's attention.

### 6. System health
```bash
python3 src/health-check.py 2>/dev/null
```
Only mention if something is broken. If everything's green, don't mention it (saves spoken-time).

### 7. Daily insight (optional)
```bash
python3 src/daily-insight.py 2>/dev/null
```
If it produces something interesting, include as a closing "by the way" line.

## Synthesis

Compose a single conversational narrative. Voice-tuned:

- Short sentences. No bullet lists.
- Use "you" not "the user".
- Lead with the most time-sensitive thing (e.g. "Your 9am with Sarah is in 45 minutes — here's what's on the docket.").
- Sequence: time-sensitive → calendar → email → reminders → weather → overnight → insight.
- For `brief`, collapse to the single most-important item per category and aim for ~50 words total.
- For `detailed`, expand with sub-items, but stay conversational ("Three meetings today. First, at 9, you and Sarah are walking through the deployment plan. Then at 11 …").

## Output

Write the synthesized narrative to `results/proactive-<ts>.txt`. The voice agent picks it up and speaks it.

## Notes

- Skip any source that errors silently — partial briefing > silence.
- Don't quote raw timestamps ("2026-05-15T09:00") — use "in 45 minutes" or "at 9".
- If nothing is happening today and inbox is empty, say so warmly ("Your morning's pretty clean — one reminder, no meetings, nothing urgent in the inbox. Good day to do deep work.") rather than awkwardly listing emptiness.
