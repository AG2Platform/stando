---
name: commute-and-weather
description: "Should-I-bike-today decisions: calendar × weather × user rules. Voice-callable: 'should I bike today', 'do I need a jacket', 'is it a good walk day'."
user-invocable: true
---

# Commute & Weather

Cross-references today's calendar with weather and the user's commute rules to answer specific questions like "should I bike today" or "do I need a jacket". The morning equivalent of "check phone" — pure habit reinforcer.

## Triggers

- "Should I bike today"
- "Do I need a jacket"
- "Is it a good walk day"
- "What's the weather"
- "Should I bring an umbrella"
- "What's my commute look like"

## Inputs

- `mode` (optional): "bike" / "walk" / "drive" / "any" (default = pick based on phrasing).
- `time` (optional): "morning" / "evening" / "all-day" (default = next commute window).

## Steps

### 1. Get the user's location

Priority order:
1. `$LOCATION_LAT_LON` env var (e.g. "37.77,-122.42")
2. `~/.config/sutando/location.json` if present (shape: `{ "latitude": float, "longitude": float, "city": string }`)
3. Geocode the user's timezone IANA name via `https://nominatim.openstreetmap.org/search?q=<city>&format=json&limit=1` (no key)
4. Hardcoded SF fallback ("37.77,-122.42") + warn the user once via `pending-questions.md` to set their location.

### 2. Get the user's commute rules

Read `notes/commute-rules.md` if it exists. Format:

```markdown
---
title: Commute rules
tags: [commute, rules]
---
bike:
- temperature_f >= 50
- precipitation_probability < 20
- wind_mph < 18
walk:
- temperature_f >= 40 OR (raining AND has_umbrella)
```

If absent, use defaults:
- bike: temp ≥ 50°F, precip < 20%, wind < 18mph
- walk: temp ≥ 40°F or "always with jacket"

### 3. Fetch weather (Open-Meteo, no key)

```bash
curl -s "https://api.open-meteo.com/v1/forecast?latitude=${LAT}&longitude=${LON}&current=temperature_2m,weather_code,wind_speed_10m,precipitation&hourly=temperature_2m,precipitation_probability&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset&timezone=auto&forecast_days=1&temperature_unit=fahrenheit&wind_speed_unit=mph"
```

Extract:
- Current temp, current weather code, current wind, current precipitation
- Next-6h max precipitation probability
- Today's high/low
- Sunrise / sunset

Map `weather_code` to one word: clear / partly-cloudy / cloudy / rainy / drizzle / snowy / stormy / foggy.

### 4. Get today's calendar (for commute window)

```bash
gws calendar +agenda --today --format json 2>/dev/null
```

Find the first meeting that REQUIRES being somewhere physical (look for `location` field; skip events with location that match `zoom.us`, `meet.google.com`, `teams.microsoft.com`, or empty). If the first physical meeting is in `mode=morning` window (before noon), the user's commute window matters; otherwise speak the weather generically.

If no physical meetings today, the answer is "weather doesn't really gate you — you're WFH/remote today. Here's the conditions anyway: ..."

### 5. Apply the rules

For the user's specified mode (or pick the most likely from phrasing):
- Bike: check each rule from the user's rules file (or defaults).
- Walk: same.

If ALL rules pass → green (recommended).
If 1 rule fails marginally (within 10% of threshold) → yellow ("doable but borderline").
If 2+ rules fail or any fails badly → red (not recommended).

### 6. Voice output

Conversational. Lead with the verdict, then the rationale.

Examples:
- "Yes — bike today. 62°F, no rain in the forecast, light wind. First meeting's at 10:30 so you have time."
- "I'd skip the bike — 48°F is below your threshold, and there's a 60% chance of rain by 9. Drive or wait for the afternoon — it clears up by 1pm."
- "Walk's fine but bring a light jacket — 52°F now, climbing to 64. Sunrise in 20 minutes."
- "You're WFH today, no commute. Just so you know: 58°F, sunny, mid-60s by afternoon. Good day for a walk break."

Save the analysis to `notes/commute-<date>.md` if the user might want to refer back (they often won't — keep this opt-in via the user explicitly saying "save that").

## Voice routing

`documented_for_core: true`. Delegated to core.

## Setup

If the user doesn't have a commute-rules file, on first run write a starter:
```
notes/commute-rules.md
```
Ask the user "What's your minimum bike temperature? Do you ride in the rain?" and persist their answers. Don't write the file without asking — it's their preference space.
