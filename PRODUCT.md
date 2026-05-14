# Sutando — Product Strategy & Beta Plan

This document captures the product strategy for Sutando's monetization
beta: what we charge for, how the desktop ↔ cloud split works under
managed mode, and the implementation work sequenced across the
`sutando` and `agent-universe` repos.

It complements (does not replace) `DISTRIBUTION.md`, which covers the
packaging and ops work to ship a signed `.app`. Where DISTRIBUTION.md
asks "how do we deliver Sutando to a user's Mac," this doc asks "once
they have it, what do they pay for and how does the cloud earn its
keep."

## Status (2026-05-12)

DISTRIBUTION.md Phases 0–4.11 are done in code. The app installs
end-to-end from DMG, the cloud control plane runs locally with the
admin panel landed. We have beta users waiting. The next chapter is
turning capability into a product.

## Implementation status (2026-05-13, late session)

All three waves are functionally complete except items explicitly
scoped out: managed Gemini Live voice (2.3 / 2.4), hosted Twilio
relay (2.5 / 2.6 / 2.7), WhatsApp bridge (1.6), and the cloud-tools
real implementations (3.7 — specialist routing / deep-research worker
/ vector RAG). Those land in dedicated follow-up sessions.

### Onboarding lifecycle (2026-05-13, this session)

Services are now bound to the app process — open Sutando.app and the
voice agent / dashboard / bridges / core agent start automatically; the
voice web window opens 1.5s after launch; cmd+Q tears every service
back down. Replaces the old "click Install Background Services in
Settings, then they auto-start on every user login" model.

Mechanism: `LaunchAgentInstaller` now renders plist templates into
`$SUTANDO_HOME/LaunchAgents/` instead of `~/Library/LaunchAgents/`.
Plists outside the system-watched directory don't auto-load at login —
launchctl only runs them when we explicitly `bootstrap`. `AppDelegate
.applicationDidFinishLaunching` runs `migrateLegacyPlists()` (one-shot
`bootout` + `rm` of anything in `~/Library/LaunchAgents/com.sutando.*`,
covering upgraders), then `bootstrapAll()`, then opens the voice
window. `applicationWillTerminate` calls `stopAll()` to bootout every
service synchronously. The Install/Uninstall menu items and Settings
buttons are gone; the first-launch stepper drops from 4 → 3 steps
(API key → Claude Code → Permissions). Settings shows a live
"N services running" status row instead, with a single Restart button.

Files touched: `src/Sutando/LaunchAgentInstaller.swift` (runDir,
migrateLegacyPlists, stopAll, booteachLabel helper), `src/Sutando/main
.swift` (autoBootstrapServices, scheduleAutoOpenWebUI,
applicationWillTerminate, removed install menu items),
`src/Sutando/SettingsWindow.swift` (3-step stepper, status-only
services row, restartServicesFromSettings).

What's new vs the morning snapshot:

- Cap-hit graceful response wired end-to-end (voice-agent `injectText`,
  Discord + Telegram replies, image/video structured errors via
  gateway 402 / 429).
- Burst protection live in `lib/rate-limit.ts` (60s + 5min windows
  per cap group; gateway/llm now routed through `checkAndConsume`).
- Auto-topup off-session charges land via the `users.default_payment_method_id`
  column + Stripe PaymentIntent flow (migration 0009). Dashboard
  exposes a toggle in the wallet card; Settings panel mirrors it.
- Settings (Swift) gained a Plan & usage section: tier label, wallet
  balance, per-cap progress bars, top-up + manage buttons, auto-topup
  checkbox. Polls `/api/me` on the existing 1.5s timer with internal
  throttle.
- `⌃⇧F` opens the new native feedback form (kind / severity / title /
  body / optional screen attach). Settings now has a "Report an issue"
  button that opens the same form.
- Cloud memory backup is plaintext for beta (open decision #2 below).
  Background loop (`src/memory-backup-loop.sh`) uploads tar.gz of
  $SUTANDO_MEMORY_DIR + notes/ every ~20 min on paid tiers. On a
  fresh Mac, signing in fires `CloudAuth.cloudAuthDidSignIn` which
  triggers `python3 src/memory-backup.py hydrate`.
- Cartesia gateway routing lands via REST (`/tts/bytes`) — paid tiers
  no longer need `CARTESIA_API_KEY`. Falls back to BYOK WebSocket on
  any non-cap-hit failure. Image / video generation gateway-route
  through `genai.Client(http_options=HttpOptions(base_url=…))` and
  surface 402 / 429 as a clean "top up" / "rate limit" error.
- Cloud-skill auto-install loop (`src/cloud-skill-sync-loop.sh`) pulls
  `GET /api/skills/installed` every ~10 min and extracts any bundles
  missing locally — dashboard installs propagate to every Mac.
- Skill marketplace gained a submission flow (`/skills/submit` +
  `POST /api/skills/submit`) and admin approve / deny / deprecate
  actions on `/admin/skills`. Decisions email the author via Loops
  (template `LOOPS_TRANSACTIONAL_SKILL_DECISION`).
- Loops lifecycle templates: invoice receipts, skill decisions,
  feedback resolved.
- Menu-bar template icon (monochrome, auto-tinted) bundled at
  `Contents/Resources/menubar.png`; falls back to the legacy
  stand-avatar if absent.

Memory snapshot storage and the Stripe / Loops / bucket credentials
remain operational (`ops`) tasks documented in the post-merge
checklist.

Pricing math adjusted from the original proposal: voice allowances
cut to 10 / 40 / 120 hr (Plus / Pro / Max) and Veo re-priced to
60 credits per 10s, both to keep over-cap usage margin-neutral
against rough wholesale rates. Headline tier prices unchanged
($29 / $99 / $199). See the tier-structure table below.

Per-row status appears in the **Status** column on each wave table.
Legend:

- `done` — shipped this session
- `partial` — partial implementation; deferred piece noted
- `deferred` — explicitly out of scope this session
- `ops` — user-action operational task (env vars, Stripe products, etc)

## North star for beta

Validate three things, in order:

1. **Concept** — do users who didn't write the README understand what
   Sutando is and stick around past week one?
2. **Value** — which capabilities create habitual use (voice / phone /
   skills marketplace / self-learning)?
3. **Monetization path** — do users upgrade past Free when the
   friction is removed, and which tier do they land on?

Code quality, abuse resistance, and security hardening are explicitly
secondary in beta. If a paywall can be bypassed by editing a local
file, that's acceptable. Investment goes into surfaces that produce
signal: telemetry, feedback ingestion, tier-shaped UX. Production
hardening happens post-beta if the signal is good.

## Beta-tier requirements

- macOS 15+
- **Claude Code subscription** (Pro / Max / Max20×) brought by the
  user. Sutando does not provision Anthropic in beta — subscription
  terms forbid pooling, and replacing the `claude` CLI in tmux with
  `claude-agent-sdk` is a Phase 5 architectural change deferred until
  after beta. Frame as a feature: "We add the body, you keep
  ownership of the brain."
- Free tier still requires the user to bring a Gemini API key (BYOK).
  Paid tiers move Gemini and everything else to managed mode.

## Beta access

The product is invite-only for the beta. Public repos and GitHub
release pages are not the distribution surface — the only path to a
Sutando install is through the cloud.

### Distribution gate

- **`AG2Platform/stando` goes private.** No public release page, no
  publicly downloadable DMG. The OSS upstream at `sonichi/sutando`
  stays open and unchanged — that's the unbundled agent for self-
  hosters. Our packaged-app fork is private from now on.
- **`agent-universe` stays private.**
- **DMG only served via cloud proxy.** The Clerk- and
  `beta_status`-gated `GET /api/download/<channel>` route is the only
  download URL we publish (DISTRIBUTION.md Phase 4.10 Track 1 step 7
  already wired the proxy — beta gating is one new condition on top).
- **Landing page** at `sutando.ag2.ai` renders the waitlist form only
  for unauthenticated visitors. Product walkthrough and feature pages
  stay behind sign-in.

### Onboarding flow

1. Visitor lands on `sutando.ag2.ai`, submits email + an optional
   short "why" field on the waitlist form.
2. Submission writes a `waitlist_signups` row; visitor sees a
   "you're on the list" confirmation.
3. Admin reviews `/admin/waitlist`, clicks **Approve** on a row.
4. Cloud generates a one-time beta invite code and sends an email:
   "Your Sutando beta access is ready — code XXXX, sign up at
   <link>".
5. User clicks the link, completes Clerk sign-up, enters the invite
   code on an activation step. Code marked redeemed;
   `users.beta_status = 'approved'`.
6. Approved user lands on `/dashboard`, where the download card +
   onboarding steps + billing are now visible.
7. Desktop sign-in (per existing CLI-login flow in DISTRIBUTION.md
   Phase 4) checks `beta_status === 'approved'` before minting a
   Sutando API key. Non-approved users bounce to a "still on the
   waitlist" page.

### Schema additions (`agent-universe`)

```sql
ALTER TABLE users
  ADD COLUMN beta_status varchar(16) NOT NULL DEFAULT 'waitlist';
-- 'waitlist' | 'approved' | 'denied' | 'revoked'

CREATE TABLE waitlist_signups (
  id uuid PRIMARY KEY,
  email text UNIQUE NOT NULL,
  why text,
  source text,                          -- 'landing' | 'referral' | 'direct'
  status text NOT NULL DEFAULT 'waiting',
  ts timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE beta_invites (
  id uuid PRIMARY KEY,
  code text UNIQUE NOT NULL,            -- random 16-char
  email text NOT NULL,                  -- pre-bound to a waitlist email
  granted_by uuid REFERENCES users(id),
  granted_ts timestamptz NOT NULL DEFAULT now(),
  redeemed_by uuid REFERENCES users(id),
  redeemed_ts timestamptz,
  expires_ts timestamptz NOT NULL,
  status text NOT NULL DEFAULT 'unredeemed'
);
```

### Routes

- `POST /api/waitlist` — public; visitor submits email + optional why
- `POST /api/auth/redeem-beta` — sign-up validates code, marks redeemed
- `GET /admin/waitlist` — admin-only triage view
- `POST /admin/waitlist/{id}/approve` — generates code + sends email

Email delivery via **Loops.so** — minimal template, code + sign-up
link + onboarding doc link. Loops.so also covers the lifecycle emails
later (approval, monthly billing receipts, feature announcements,
re-engagement) so we don't add a second ESP.

## Tier structure

| Tier | Price | What's in it |
|---|---|---|
| **Free (BYOK)** | $0 | Full local agent, BYO Gemini + Twilio + Cartesia + Discord/Telegram/WhatsApp tokens. Cloud account = device dashboard, auto-update, feedback. Can install marketplace skills but **cannot publish**. Funnel only. |
| **Plus** | $29/mo | Managed Gemini gateway. **Voice: 30 hr/mo. Phone: 1 number + 200 min. Channels: 3000 msgs/mo** across Discord + Telegram + WhatsApp. Cloud memory backup (encrypted). 500 skill-credits/mo. 7-day transcript retention. 1 Mac. **Can publish skills** (after review). |
| **Pro** | $99/mo | Plus + **Voice: 100 hr/mo. Phone: 1000 min. Channels: 15000 msgs/mo.** Premium TTS (Cartesia). 2500 skill-credits/mo. 30-day transcripts. 3 Macs. |
| **Max** | $199/mo | Pro + **Voice: 300 hr/mo (fair use). Phone: 3000 min. Channels: 50000 msgs/mo.** Unlimited free-skill use. 10000 skill-credits/mo. Priority cloud-tool access. Early access to new skills. 90-day transcripts. 5 Macs. |
| **Credit wallet** | $10 increments | Top-up for over-cap usage (voice / phone / channels / skills). Never expires. Available on all paid tiers. |

Every tier's allowance is denominated in credits internally
(1 voice-hour = 200 credits, 1 channel message = 0.3 credits, 1
phone minute = 2.5 credits — see open decision #1 for the full
table). The table shows the human-readable view. Over-cap usage
debits the credit wallet, or fails closed when the wallet is empty
(configurable per user).

**Voice hour** = active Gemini Live time (audio bytes flowing either
direction). Connected-but-silent doesn't draw. **Channel message** =
inbound message to Discord / Telegram / WhatsApp that triggers an
agent response, plus any agent-initiated outbound. Bot status pings
and bot-to-bot heartbeat traffic don't count.

## Architectural principles

These constrain every implementation decision below:

1. **Cloud proxies API calls; desktop does not hold provider keys.**
   Exception: Gemini Live needs direct desktop → Google for latency,
   so cloud mints 24h ephemeral sub-keys stored in macOS keychain.
2. **Skills are signed code with declared permissions.** Marketplace
   skills must be signed by Sutando's Developer ID before publish.
   Manifest declares permission surfaces (filesystem, network,
   screen). Not enforced in beta; disclosed on install.
3. **Beta paywalls are advisory.** Tier checks happen both client- and
   server-side, but production-grade abuse prevention waits for
   post-beta.
4. **Wrap, don't refactor.** No architectural redesigns in this
   chapter — everything below is additive to the existing desktop +
   cloud surfaces.
5. **Cloud cannot read user content without consent.** Memory backup
   is end-to-end encrypted; transcripts opt-in per tier.

## Product surfaces

### 1. Managed credentials

**Goal**: Paid users sign in once and everything works. No `.env`
editing.

**Mechanism**:
- Cloud mints a Sutando-issued Bearer token (already wired via
  `CloudAuth.swift` keychain flow).
- Desktop routes Gemini text/vision, Cartesia TTS, Veo image/video,
  and any other paid provider through
  `https://sutando.ag2.ai/api/gateway/*`.
- Gateway enforces per-user rate limits + caps, attributes usage to
  `usage_events` with the right `kind` for billing.
- For Gemini Live (voice WebSocket), cloud mints a 24h ephemeral
  Google sub-key per user, stored in keychain; the desktop connects
  Google directly. Renews on heartbeat.

**Per-tier behavior**:
- Free — gateway requires user's own Gemini key. No cloud-managed
  credentials. Keeps the Free tier viable without burning our money.
- Plus+ — gateway uses Sutando's master keys, charges metered usage
  against the user's tier allowance plus wallet.

**Files touched**:
- `sutando` — `src/cloud-client.ts` adds gateway routing helpers;
  `src/voice-agent.ts` reads ephemeral Gemini key from keychain on
  startup; `src/cartesia-tts.ts` switches to gateway URL when paid
  tier is active.
- `agent-universe` — new routes under `app/api/gateway/*`; gateway
  caches master keys server-side; rate limiter in
  `lib/usage-rollup.ts`.

### 2. Skill marketplace

**Goal**: Skills are the most important asset. Make them discoverable,
installable, monetizable. App-Store-shaped from day one.

**Skill bundle format**:
- Skill is a directory: `manifest.json`, `SKILL.md`, `scripts/`,
  optional `data/`, optional `tools.ts`.
- Bundle = signed tarball + manifest hash. Sign on publish with
  Sutando's Apple Developer ID; verify on install.
- Manifest declares: `name`, `version`, `author`, `permissions`,
  `price_credits`, `tier_required`, `tools` (if manifest-loaded),
  `cloud_endpoint` (if cloud-backed).

**Cloud catalog** (`agent-universe`):
- `skills` — id, name, version, author_id, signing_hash, tier,
  price_credits, status (`review` / `published` / `deprecated`),
  bundle_url (Tigris).
- `skill_installs` — user_id, skill_id, version, ts.
- `skill_reviews` — user_id, skill_id, rating 1–5, body, ts.
  Aggregate rating displayed in catalog.
- `skill_analytics` view per author — install count, daily actives,
  revenue, rating, error rate (joined from `error_events` on
  `kind='skill.run' AND metadata.skill = …`).

**Routes**:
- `GET /api/skills/catalog` — list, tier-gated filter
- `GET /api/skills/{id}` — detail + reviews
- `POST /api/skills/{id}/install` — debit credits if priced
- `POST /api/skills/{id}/review` — user posts rating
- `GET /api/skills/{id}/analytics` — author dashboard

**Desktop**:
- New built-in skill `skill-installer` — voice-callable: "find a skill
  for X," "install Y," "review Y." Manages
  `~/Library/Application Support/Sutando/cloud-skills/`; restarts
  voice-agent on install so manifest-loaded tools merge.
- Signature verified on install (Apple Developer ID).
- Per-skill metering: `task-bridge.ts` skill dispatcher emits
  `kind='skill.run', metadata.skill='<name>'` per invocation. (Today
  this is the "deferred low marginal value" item in DISTRIBUTION.md
  Track 4 — **promote it**, the marketplace economics depend on it.)

**Beta scope**:
- Catalog launches with Sutando-published skills only (curated seed).
- **Paid users (Plus / Pro / Max) can submit skills for review;**
  approved submissions enter the catalog. Free users can install but
  cannot publish — the publish flow is the first concrete reason to
  upgrade from Free for the builder-type user.
- Sideloading via `$SUTANDO_PRIVATE_DIR/skills/` stays available on
  any tier (your code, your machine — no submission required).
- Ratings + reviews live from day one (validates demand signal).
- Author analytics surfaced from day one for every approved author.

**Sutando-suggests-a-skill loop**: when the proactive loop sees the
user repeat a workflow, it can suggest publishing it as a skill (or
suggest a matching skill from the catalog). This is a demo of both
the autonomous loop and the marketplace in one breath — no extra
infrastructure beyond the catalog API.

### 3. Self-learning cloud backup

**Goal**: Memory and notes follow the user across machines and
survive disk wipe. Replaces `cross-node-sync` rsync-over-SSH for paid
users.

**Mechanism**:
- Tigris bucket per user (already in stack).
- Files synced: `$SUTANDO_MEMORY_DIR/*`, `notes/*`.
- **Beta: plaintext** with server-side AES-at-rest only. Open decision
  #2 was resolved 2026-05-13 in favor of skipping E2E for beta; the
  passphrase + KDF design lands post-beta once we see real demand
  signal for the audit story.
- Sync from a background daemon (`src/memory-backup-loop.sh`) every
  ~20 min, plus on demand via `python3 src/memory-backup.py upload`.
- Hydration on new device: signing in fires
  `cloudAuthDidSignIn`; `AppDelegate.runMemoryHydrate()` invokes
  `python3 src/memory-backup.py hydrate`, which downloads + extracts
  only when the local memory dir is empty (idempotent).

**Per-tier**:
- Free — BYO (rsync between own Macs via existing `cross-node-sync`
  skill). No cloud backup.
- Plus+ — cloud backup + multi-device sync.

**Privacy positioning (beta)**: Memory leaves the Mac in plaintext
(over TLS) and is stored encrypted at rest by Tigris. The "cloud can't
read your memory" claim is process- and access-control based, not
mathematically guaranteed, until E2E encryption ships post-beta.
`/privacy` should reflect that honestly — overpromising in marketing
is a worse outcome than the absence of a hard guarantee.

### 4. Managed phone & channels

**Goal**: One click enables phone. No Twilio account, no ngrok, no
webhook config.

**Hosted Twilio relay**:
- Master Twilio account operated by Sutando.
- Cloud route `POST /api/phones/provision` creates a Twilio subaccount
  + buys a number + binds webhook to
  `sutando.ag2.ai/api/relay/twilio/<user>`.
- Inbound relay forwards to the user's machine over the existing
  agent-api WebSocket path (`agent-api.py:7843` → cloud → user).
  Outbound flows desktop → cloud → Twilio.
- `VERIFIED_CALLERS` lifts from `.env` to a cloud-managed allowlist
  (one table, editable from the dashboard, pushed to desktop on sync).
- Per-tier daily caps; auto-pause + Discord alert when an abuse
  pattern fires.

**Channel bot tokens** (Discord, Telegram, WhatsApp): user-provisioned
in beta — the BotFather + Discord-developer-portal flow stays. Cloud
stores the token encrypted; desktop reads via authenticated channel.
Multi-tenant shared-bot path is post-beta work.

**Security checklist (beta level)**:
- STIR/SHAKEN inbound preserved through the relay
- Per-user outbound rate limit + daily $-cap
- Number released on subscription cancellation
- Audit log of every outbound call attributed to user_id

### 5. Cloud tools as activatable skills

**Goal**: Sutando's cloud doesn't just bill — it provides
capabilities. Each cloud capability = a server-side service plus a
thin skill the desktop installs on activation.

**Beta launch set** (three cloud tools):
1. **Agent delegation** — Sutando hands a task to one of our
   specialist agents. Skill: `delegate-to-specialist`. Cloud route:
   `POST /api/tools/delegate`.
2. **Deep research** — long-running multi-source research, async
   result via webhook/DM. Skill: `deep-research`. Cloud route:
   `POST /api/tools/research`.
3. **Hosted memory RAG** — vector search over user's notes
   (cloud-side, opt-in, separate encryption namespace from #3). Skill:
   `recall`. Cloud route: `POST /api/tools/recall`.

**Activation flow**:
- User clicks "Activate" on a tool card in the dashboard
- Cloud writes the user's enabled-skills list
- Desktop syncs on next heartbeat, installs the skill bundle from
  the catalog
- Voice-agent picks up the new tool on next restart

**Per-tier**:
- Tools have a base cost in credits per invocation
- Max tier gets priority access plus a higher monthly allowance

### 6. Feedback & bug report

**Goal**: Every beta interaction that goes wrong becomes a structured
record we can act on. No "user emailed me" leakage.

**Cloud schema** (`agent-universe`):
- `feedback` — id, user_id, kind (`bug` / `feature` / `other`),
  severity, title, body, context_jsonb (last_screen_path,
  last_logs_excerpt, app_version, device_id), status (`new` /
  `triaged` / `in-progress` / `shipped` / `wontfix`), ts.
- Admin route `/admin/feedback` to triage.

**Routes**:
- `POST /api/feedback` — accepts a feedback record from desktop
- `PATCH /api/feedback/{id}` — admin updates status

**Desktop surfaces**:
- Built-in skill `report-feedback` — voice-callable: "report a bug,"
  "send feedback," "request a feature." The skill captures the last
  60s of logs + last screen + user note (or voice transcript) and
  POSTs to `/api/feedback`.
- Hotkey `⌃⇧F` in the menu bar — opens a small NSWindow form with
  context already captured.
- Settings → "Report an issue" button (same form).
- Dashboard form at `sutando.ag2.ai/feedback`.

**Loop closure**: when admin marks a record `shipped`, the user gets
a Discord DM "your bug X is fixed in v0.X.Y" — drives upgrade and
goodwill.

### 7. Monitoring & telemetry

**Goal**: Robust, systematic observability across cloud + desktop.
Any question about beta usage should be answerable from `/admin`.

**Already shipped** (per DISTRIBUTION.md 4.11): users / devices /
usage_events / onboarding_events / error_events / sessions.

**Add in beta**:
- **TTFV metric** on `/admin` overview — `MIN(usage_events.ts WHERE
  kind='voice.gemini') - users.created_at`, p50 / p90 / p99.
- **Per-skill `skill.run` metering** — wire emission in
  `task-bridge.ts` skill dispatcher (DISTRIBUTION.md Track 4 deferred
  item, **must ship before marketplace**).
- **Per-cloud-tool usage** — `kind='cloud.delegate'`,
  `'cloud.research'`, `'cloud.recall'`.
- **Provider cost rate sheet** server-side — populate
  `usage_events.provider_cost_cents` from a wholesale-rate table for
  real margin analysis.
- **Skill error-rate dashboard** — `/admin/skills` shows per-skill
  invocation count, error rate, p50 latency, rating.
- **Funnel completion** — augment onboarding step set to include
  `first_voice`, `first_phone`, `first_skill_install`, `first_paid`.

**Desktop emission gaps to close** (deferred from Phase 4.10 Track 4):
- Cartesia 5xx → `tts.cartesia.error`
- Image-gen rate limits → `image.gen.rate_limit`
- `run-core-agent.sh` prereq misses → emit via Swift health poll

### 8. Usage tracking, rate limiting & enforcement

**Goal**: Every tier allowance is observable, enforceable, and
graceful when hit. Without this layer the tier table is decorative.

Three layers, top-down.

**1. Event capture — instrumentation completeness**

Every billable operation emits one or more `usage_events` rows with a
canonical `kind` and `units`. Pre-launch coverage matrix:

| Operation | Kind | Units | Status |
|---|---|---|---|
| Voice active conversation | `voice.gemini` | seconds | shipped (`voice-agent.ts` writeVoiceMetrics) |
| Phone outbound | `phone.twilio.outbound` | call seconds | shipped (`conversation-server.ts:1010`) |
| Phone inbound | `phone.twilio.inbound` | call seconds | shipped (`conversation-server.ts:1024`) |
| Cartesia TTS | `tts.cartesia` | audio seconds | shipped |
| Image generation | `image.gen` | count | shipped (`skills/image-generation/scripts/generate.py`) |
| Video generation | `video.gen` | video seconds | shipped (same path) |
| Vision Gemini | `vision.gemini` | count | shipped (`browser-tools.ts` describeScreenTool) |
| **Channel message in/out** | `channel.<discord\|telegram\|whatsapp>.<in\|out>` | count | **NEW** — wire in each bridge |
| **Skill invocation** | `skill.run` | count + `metadata.skill` | **NEW** — wire in `task-bridge.ts` dispatcher |
| **Voice-hour rollup** | `voice.gemini.hour` | hour-grain windows | **NEW** — server-side aggregation |
| Cloud-tool call | `cloud.<delegate\|research\|recall>` | count | NEW, lands with each tool (Wave 3) |

**2. Rate-limit + cap enforcement — pre-flight check**

`lib/rate-limit.ts` in `agent-universe` exposes one canonical entry
point used by every gateway and cloud route:

```ts
checkAndConsume(userId, kind, units): {
  allowed: boolean,
  tier_remaining: number,
  wallet_balance: number,
  charged_to: 'tier' | 'wallet' | 'denied',
  reason?: 'tier_exhausted_no_wallet' | 'fair_use_burst' | 'no_subscription'
}
```

Implementation:

- **`rate_limit_policies`** — one row per `kind` × tier with monthly
  cap, burst window (60s + 5min) + burst cap, wallet-conversion rate
  (credits per unit). Seeded from the open-decision-#1 unit table.
- **`usage_rollups`** — denormalized sliding-window counts per
  `(user_id, kind, window)`, updated on every event write. Beta
  acceptable; production may move to Redis/KV later.
- **`users.wallet_credits`** — materialized balance, kept in sync by
  `credits_ledger` writes.
- **Decision tree** — within tier cap → allow, charge tier; else if
  wallet has balance → debit at policy rate; else deny.
- **Burst protection** — separate short-window counter so a runaway
  loop can't spend a month's allowance in minutes.

Free tier: policies evaluated but advisory only (user's keys foot the
bill). Admin dashboard flags free users emitting unusual volumes —
early signal of leaked credentials or misuse.

**3. Cap-hit response — graceful client-side handling**

Cloud gateway returns HTTP 429 with structured body
`{error, retry_after, cap_kind, remaining_this_period, wallet_balance,
topup_url}` when denied. Desktop handles per kind:

- **Voice** — voice-agent speaks "you've hit your monthly voice
  limit — top up at sutando.ag2.ai/billing or upgrade," cleanly
  closes Gemini Live. Reconnects fail fast with the same message.
- **Phone** — outbound dial aborts with a synthesized voice template
  + DM to owner. Inbound calls answered with a template + hung up.
- **Channel message** — bot replies "monthly message limit reached
  — top up at <link>"; subsequent messages suppressed until reset or
  top-up lands.
- **Skill / image / video** — tool returns a structured error so the
  agent can explain contextually to the user.

**Auto-topup** (paid tiers, opt-in): when wallet drops below
threshold (default $5 of credits), Stripe charges $10 to the saved
card. Daily + monthly auto-topup caps prevent a runaway loop from
draining the card.

**Monthly tier reset**: Stripe webhook on `invoice.paid` resets the
user's `usage_rollups` counters for the new period. Users without
active subscriptions don't reset — Free tier is BYOK so it doesn't
matter.

**Implementation surfaces**:
- `agent-universe` — `lib/rate-limit.ts`, `rate_limit_policies`
  seeded, `usage_rollups` denormalization, `users.wallet_credits`,
  gateway middleware wrapping every billable route, Stripe webhook
  handlers for reset + auto-topup, `/api/billing/topup` route.
- `sutando` — `cloud-client.ts` rate-limit-response handler; voice
  agent / bridges / phone agent subscribe to "limit hit" events and
  surface gracefully; Settings + menu-bar surface a live "X / Y voice
  hours used" + "Wallet: $N" with an inline top-up button.

### 9. UI & branding refresh

**Goal**: Visual coherence across desktop app and cloud dashboard.
Both should feel like one product made by people who care.

**Deliverables**:
- **Logo + wordmark** — one set, used across desktop, cloud, DMG,
  favicon, social.
- **macOS app icon** (`.icns`) — replace placeholder at
  `app/Resources/icons/AppIcon.icns`. Full size set: 1024 / 512 / 256
  / 128 / 64 / 32 / 16 with retina variants.
- **Cloud dashboard minimalist redesign** (`agent-universe`) — strip
  back to essentials, add density only where it serves (the admin
  panel can stay denser).
- **Desktop Settings window refresh** (`src/Sutando/SettingsWindow.swift`)
  — match cloud style: same fonts, accent colors, spacing tokens. The
  4-step stepper from Phase 4.8 stays but restyled.
- **Menu-bar icon** — current "S" character is functional. Replace
  with a mark consistent with the logo. Preserve three states (idle /
  listening / working).

**Style direction**: cloud minimalist, dark-first, high-contrast,
generous whitespace. Iconography line-based, not filled.
Anti-skeuomorphic. Reference set: Linear, Vercel, Raycast.

## Cross-repo implementation phases

Three waves. Items within a wave can run in parallel.

### Wave 1 — Gate access, instrument, enforce

The heaviest of the three waves. Five buckets — sequential within
each bucket; buckets can partially overlap.

**1a — Distribution gate (must land first)**

| # | Item | Repo | Status |
|---|---|---|---|
| 1.1 | Waitlist + invite-code system: schema, public `POST /api/waitlist`, admin `/admin/waitlist` triage, code generation, email via Loops.so | agent-universe | done |
| 1.2 | `users.beta_status` check on `/api/auth/cli-login/exchange` + `/api/download/<channel>` | agent-universe | done |
| 1.3 | Make `AG2Platform/stando` + `agent-universe` repos private; remove any public DMG links | both | ops |
| 1.4 | Landing page → waitlist-only for unauthenticated; product walkthrough behind sign-in | agent-universe | done |

**1b — Metering completeness** (closes the per-skill / channel / voice-hour gaps so caps are enforceable)

| # | Item | Repo | Status |
|---|---|---|---|
| 1.5 | Per-skill `skill.run` metering (in `voice-agent.ts:onToolResult` rather than `task-bridge.ts` — covers every tool invoked from voice) | sutando | done |
| 1.6 | Channel-message emission (`channel.<discord\|telegram>.<in\|out>`) wired in each bridge | sutando | partial — Discord + Telegram done; WhatsApp bridge **deferred to post-beta** per scope discussion |
| 1.7 | Voice-hour aggregation (`tierUsagePanelForUser` rolls voice.gemini seconds into hours for display + cap check) | agent-universe | done |
| 1.8 | TTFV + funnel-completion metrics on `/admin` | agent-universe | done |

**1c — Billing + rate-limit infrastructure**

| # | Item | Repo | Status |
|---|---|---|---|
| 1.9 | Plus / Pro / Max products in Stripe at $29 / $99 / $199; plan catalog row shape | agent-universe | partial — plan catalog + Max tier in code; Stripe products themselves are `ops` |
| 1.10 | Credit wallet: `users.wallet_credits` materialized column + `credits_ledger` debit/credit writers | agent-universe | done |
| 1.11 | Rate-limit policies (TS constant in `lib/billing/policies.ts`, not DB table — promote later); `usage_rollups` denormalization on each event; `lib/rate-limit.ts checkAndConsume` entry point | agent-universe | done — burst protection (60s + 5min sliding windows over usage_events) landed; gateway/llm now routed through `checkAndConsume` |
| 1.12 | Stripe webhook on `invoice.payment_succeeded` → monthly tier reset + credit grant; `/api/billing/topup` for manual top-up | agent-universe | done — auto-topup off-session PaymentIntent fires from `lib/billing/auto-topup.ts` (called fire-and-forget from `debitWallet`); daily + monthly caps + CAS mutex on `users.last_auto_topup_at`; dashboard toggle + Settings checkbox |

**1d — Enforcement UX (in-app)**

| # | Item | Repo | Status |
|---|---|---|---|
| 1.13 | Tier-aware Settings UI + voice-tool routing (Free vs Plus vs Pro vs Max) | sutando | done — Settings shows tier label + bars + wallet + top-up. Gateway routing wired for Gemini vision, Cartesia TTS, image / video generation. |
| 1.14 | Cap-hit graceful response across surfaces: voice cleanly closes with TTS message; phone returns voice template; bridges reply "top up"; skill / image / video surface as structured tool errors | sutando | done — voice-agent subscribes to `onCapHit` and `injectText`s a "limit reached / burst throttle" message (closes session on voice-cap exhaust); Discord + Telegram bridges short-circuit inbound + reply once per ~5 min per chat; image / video map gateway 402 → "wallet empty" + 429 → "rate limited". Phone wiring waits on hosted Twilio relay. |
| 1.15 | Per-user usage panel — Settings + dashboard: per-kind progress bars, wallet balance, inline top-up button | both | done — Settings.app surfaces tier label + per-cap bars + wallet + top-up / billing / auto-topup checkbox. Cloud dashboard already had it; auto-topup toggle added. |

**1e — Feedback + branding**

| # | Item | Repo | Status |
|---|---|---|---|
| 1.16 | Feedback ingestion schema + routes + admin view | agent-universe | done |
| 1.17 | `report-feedback` built-in skill + `⌃⇧F` hotkey + Settings button | sutando | done — `⌃⇧F` registered in `main.swift` defaultHotkeys; native `FeedbackWindowController` form (kind / severity / title / body / optional screen attach) posts to `/api/feedback`; "Report an issue" button in Settings + menu-bar entry call the same form |
| 1.18 | Logo, icon set, Settings + menu-bar visual refresh | sutando | done — `app/AppIcon.icns` rebuilt; new monochrome menubar template (`app/assets/menubar.png` / `@2x.png`) loaded as `isTemplate=true` so macOS tints it for dark + light bars. Settings polish: tier panel + feedback section + auto-topup row; full-app redesign deferred to post-beta. |
| 1.19 | Cloud dashboard minimalist redesign + waitlist landing page styled | agent-universe | done (light pass) — card hover states + featured-plan ring + table-header tone consistency. Full minimalist redesign deferred per scope discussion (Linear/Vercel/Raycast direction lands post-beta). |

### Wave 2 — Managed mode infrastructure

| # | Item | Repo | Status |
|---|---|---|---|
| 2.1 | `/api/gateway/llm` Gemini proxy + plan gate + per-user attribution (header `X-Sutando-Kind` decides debit: image=5cr, video=60cr, text/vision none) | agent-universe | done |
| 2.2 | `/api/gateway/tts` for Cartesia; image/video share `/api/gateway/llm` since they hit the same Gemini API surface | agent-universe | done |
| 2.3 | Ephemeral Gemini Live key minter `/api/gateway/voice-key` (24h, per-user, daily quota) | agent-universe | deferred — voice stays BYOK until Vertex AI Live release |
| 2.4 | Desktop reads ephemeral key from keychain on startup; refreshes on heartbeat | sutando | deferred — paired with 2.3 |
| 2.5 | Hosted Twilio relay: number provisioning, webhook relay, inbound forwarder | agent-universe | deferred — dedicated follow-up session |
| 2.6 | Desktop `phone-conversation` skill switches to cloud-relay URL when paid tier active | sutando | deferred — paired with 2.5 |
| 2.7 | `VERIFIED_CALLERS` migrate from `.env` to cloud-managed allowlist | both | deferred — paired with 2.5 |
| 2.8 | Cloud memory backup — Tigris bucket per user, e2e-encrypted, sync from proactive loop | both | done (plaintext) — `src/memory-backup.py` + `src/memory-backup-loop.sh` upload tar.gz of `$SUTANDO_MEMORY_DIR` + `notes/` every ~20 min on paid tiers; started in `src/startup.sh`. **E2E encryption deferred to post-beta** per open decision #2 — beta is server-side encrypted at rest (Tigris) only. Bucket creds remain `ops`. |
| 2.9 | First-launch hydration from cloud memory backup on new Mac | sutando | done — `CloudAuth.handle(url:)` posts `cloudAuthDidSignIn`; `AppDelegate.runMemoryHydrate()` shells out to `python3 src/memory-backup.py hydrate`, which downloads + extracts only when the local memory dir is empty |
| 2.10 | Desktop conditional gateway routing — `gatewayBaseUrl(kind)` helper + try-gateway-fall-back-to-BYOK pattern in `browser-tools.ts` (Gemini vision) | sutando | done — Gemini vision (existing), Cartesia TTS via REST `/tts/bytes` (`cartesia-tts.ts` falls back to BYOK WebSocket on non-cap failures), image / video generation via `genai.Client(http_options=HttpOptions(base_url=…))` with `X-Sutando-Kind` headers. 402 / 429 surface as clean "top up" / "rate limited" errors |

### Wave 3 — Skill marketplace + cloud tools

| # | Item | Repo | Status |
|---|---|---|---|
| 3.1 | Skill bundle format + signing pipeline (Apple Developer ID) | sutando | partial — bundle format defined; tarball hosting (CDN + signed-URL upload) + Apple Developer ID signing pipeline deferred to post-beta. Install path verifies SHA-256 today against the manifest's `signing_hash`. |
| 3.0 | Skill submission flow (paid-tier publish) + admin approve / deny / deprecate | both | done — `/skills/submit` form (paid tier only) + `POST /api/skills/submit` (slug ownership + re-submit support). Admin `/admin/skills` gets per-row Approve / Deny / Deprecate buttons via server actions; decisions email the author via Loops (`LOOPS_TRANSACTIONAL_SKILL_DECISION`). |
| 3.2 | Skill catalog tables (`skills`, `skill_installs`, `skill_reviews`) + routes | agent-universe | done |
| 3.3 | `skill-installer` built-in skill in desktop | sutando | done |
| 3.4 | Skill catalog UI on cloud dashboard (`/skills` + `/skills/[slug]`) | agent-universe | done |
| 3.5 | Rating + review submission flow | both | done — `POST /api/skills/[id]/review` (requires prior install), star UI on detail page |
| 3.6 | Per-skill author analytics view (our skills initially) — `/admin/skills` | agent-universe | done — install count + 7d delta + rating + revenue + err24h join on `error_events` |
| 3.7 | Cloud tools v1 — `agent-delegation`, `deep-research`, `hosted-RAG` services | agent-universe | partial — routes ship as wallet-debiting stubs + catalog seed. **Real specialist routing / worker pool / vector RAG explicitly deferred to post-beta** per scope discussion (large infra; beta validates marketplace economics with stubs). |
| 3.8 | Activation flow + auto-install on desktop | both | done — `GET /api/skills/installed` (new) lists user's installed skills with bundleUrl + signingHash; `src/cloud-skill-sync.ts` diffs against local `cloud-skills/<slug>/` and extracts missing tarballs; `src/cloud-skill-sync-loop.sh` runs the diff every ~10 min, started from `src/startup.sh`. Dashboard installs now propagate to every Mac the user signs into. |

## What's out of scope for beta

Be explicit about what we're NOT doing — for sanity, for sequencing,
and so the cloud dashboard never promises features that aren't
shipped:

- **Managed Anthropic / Claude Code subscription pooling** — terms
  forbid, architectural rewrite. Beta requires the user's own CC sub.
- **Public skill submissions** — *paid-tier* submissions land in
  `status='review'` and require admin approval before they appear in
  the catalog. Free-tier sideloading via `$SUTANDO_PRIVATE_DIR/skills/`
  stays available on any tier. Anonymous / Free submissions remain out
  of scope.
- **Real sandboxing of marketplace skills** — disclosure only; trust
  the curation gate.
- **Multi-tenant Discord / Telegram bot** — user-provisioned tokens.
- **Production-grade abuse detection** — basic per-user rate caps
  only.
- **Team / org accounts** — `users.org_id` is nullable from day 1
  (per DISTRIBUTION.md) but no team UX in beta.
- **Public-tier / open rollout** — beta is waitlist + invite-code
  only; see "Beta access" section.
- **Self-serve beta approval** — admin manually approves waitlist
  rows for now. Auto-approval rules (e.g. corp email allowlist) is
  post-beta.

## Open decisions

Things to weigh in on before we start implementation:

1. **Credit unit pricing — finalized 2026-05-13** (per
   `lib/billing/policies.ts`). Every line item denominated in
   credits so over-cap usage debits the wallet uniformly:

   | Unit | Credits | Notional $ @ $0.01/credit |
   |---|---|---|
   | 1 voice-hour (Gemini Live, active) | 200 | $2.00 |
   | 1 phone-minute (outbound or inbound) | 2.5 | $0.025 |
   | 1 channel message (Discord/Telegram/WhatsApp) | 0.3 | $0.003 |
   | 1 image (Gemini Flash Image) | 5 | $0.05 |
   | 1 second of video (Veo) | 6 | $0.06 |
   | 1 Cartesia TTS second | 0.5 | $0.005 |
   | Cloud-tool: delegate | 50 | $0.50 |
   | Cloud-tool: research | 100 | $1.00 |
   | Cloud-tool: recall | 5 | $0.05 |

   Rates were tuned to keep over-cap usage margin-neutral against
   rough wholesale rates (the original draft at 60 cr/hr for voice
   was sub-cost once Gemini Live's per-minute audio billing landed;
   the 200 cr/hr figure absorbs that). Phone collapsed to one rate
   for both lanes — the inbound discount we'd originally proposed
   didn't survive Twilio's per-minute symmetric pricing.

   Sanity at Plus's 500-credit monthly grant: ~100 images OR ~83 sec
   of video OR ~2.5 voice-hours of over-cap. Worst-case full-cap
   provider cost is roughly Plus $36 / Pro $145 / Max $440 — margins
   depend on typical-use being ~30 % of cap (standard SaaS shape).
   Margin re-check post-beta once we have real distribution data.
2. **Encryption key for cloud memory** — derived from a passphrase
   (user can lose it; recovery story?), or from a hardware-backed
   keychain key (can't share across devices without first-device
   pairing)?
   **Resolved 2026-05-13: skip E2E for beta.** Cloud stores plaintext
   tarballs under server-side AES-at-rest (Tigris). The privacy
   positioning in §3 (`Self-learning cloud backup`) is updated to
   reflect that the "cloud can't read your memory" claim is process-
   and access-control based for beta, not mathematically guaranteed.
   The passphrase + KDF flow is the first thing to revisit post-beta
   once we know how many users care about the audit story.
3. **Skill author revenue share** — 70/30 like App Store, or higher
   author share to bootstrap? (Beta is curated, so mostly theoretical
   until Wave 3.) 80/20
4. **Free tier credit wallet** — do free users get $5 of credits/mo
   as a hook into paid skills, or stay strictly BYOK? Yes $5 is good.
5. **Feedback skill behavior** — does the `report-feedback` skill
   always take a voice note, or can users mark "no narration" and
   just attach context? can mark "no narration"

## Cross-references

- Packaging plan: `/Users/lianghaochen/stando/DISTRIBUTION.md`
- Cloud README: `/Users/lianghaochen/agent-universe/README.md`
- Desktop README: `/Users/lianghaochen/stando/README.md`
- Skills primer: `/Users/lianghaochen/stando/skills/MANIFEST.md`
- Project instructions: `/Users/lianghaochen/stando/CLAUDE.md`

## Operational checklist (post-merge)

User actions required before paid beta users can complete an install:

1. **Migrations** — `npm run db:migrate` against Neon applies 0004 → 0009
   (beta gate, billing caps, feedback, skills, memory snapshots,
   auto-topup payment method + mutex).
2. **Seed cloud tools** — `psql $DATABASE_URL -f lib/db/seeds/cloud-tools.sql`
   adds the three v1 cloud tools (delegate / research / recall) to the catalog.
3. **Stripe** — create Plus / Pro / Max products at $29 / $99 / $199;
   set `STRIPE_PRICE_{PLUS,PRO,MAX}_MONTHLY`; add
   `checkout.session.completed` to the webhook event subscriptions
   (already handles `invoice.payment_succeeded`).
4. **Loops.so** — set `LOOPS_API_KEY` plus the four transactional template IDs:
   - `LOOPS_TRANSACTIONAL_BETA_INVITE` — vars `{code, signupUrl, expiresAt}`
   - `LOOPS_TRANSACTIONAL_SKILL_DECISION` — vars `{decision, skillName, skillSlug, catalogUrl, reason}`
   - `LOOPS_TRANSACTIONAL_FEEDBACK_RESOLVED` — vars `{title, body, status, appUrl}`
   - `LOOPS_TRANSACTIONAL_BILLING_RECEIPT` — vars `{planName, amount, periodEnd, dashboardUrl, invoiceUrl}`

   Without each ID, the corresponding email logs to the server console
   instead of sending — fine for staging, must be flipped for prod.
5. **Managed-gateway provider keys** — `GEMINI_MASTER_API_KEY` +
   `CARTESIA_MASTER_API_KEY`. Without them, gateway routes 503 and the
   desktop falls back to BYOK.
6. **Tigris bucket** (for memory snapshots) — provision a bucket, set
   `AWS_ENDPOINT_URL_S3` + `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY`
   + `AWS_REGION` + `OBJECT_STORE_BUCKET`. Without them, the snapshot
   routes 503 gracefully.
7. **Repo privacy** — flip `AG2Platform/stando` + `agent-universe` to
   private via the GitHub UI.
8. **Admin self-approval** — internal-alpha users were retro-marked
   `beta_status='approved'` by migration 0004; `is_admin = true` users
   also bypass the gate via the redeem-beta route.
