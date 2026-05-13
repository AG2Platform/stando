# skill-installer

Voice-callable tools to browse + install marketplace skills from the
Sutando cloud (`agent-universe`).

## Tools

- `find_skill(query)` — search the catalog by name or description
- `install_skill(slug)` — debits wallet if priced, downloads + verifies the bundle, extracts to `cloud-skills/<slug>/`
- `review_skill(slug, rating, body?)` — post a 1–5 rating + optional review body

## Behavior

Installs land under `$SUTANDO_HOME/cloud-skills/` (or
`~/Library/Application Support/Sutando/cloud-skills/` when
`SUTANDO_HOME` is unset). After install, voice-agent must be restarted
to pick up new tools — the inline tool loader scans on boot.

Wallet debits for priced skills happen server-side via the same
`credits_ledger` path as over-cap usage. If the wallet can't cover the
install, the cloud route returns 402 and the install aborts before any
bytes are downloaded.

## Cloud routes used

- `GET https://sutando.ag2.ai/api/skills/catalog`
- `GET https://sutando.ag2.ai/api/skills/{slug}`
- `POST https://sutando.ag2.ai/api/skills/{id}/install`
- `POST https://sutando.ag2.ai/api/skills/{id}/review`

## Failure modes

- 401 → user signed out; prompt to sign in via menu bar
- 402 → insufficient credits; prompt to top up at `/dashboard`
- 403 → tier required is above current plan; prompt to upgrade
- bundle hash mismatch → abort, leave nothing on disk, surface error
