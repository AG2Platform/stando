# Distribution Plan

This document describes the plan to turn Sutando from a single-user developer
environment into a distributable, signed macOS application backed by a cloud
control plane (auth, billing, observability).

## Goals

- **Internal release**: ship a packaged `.app` to ~5–10 internal users without
  changing core feature behavior. Every existing voice / phone / messaging /
  proactive-loop capability works exactly as it does today.
- **Cloud control plane**: signup/login, paid subscriptions, usage metering,
  observability dashboard. Lives in a separate repo:
  `/Users/lianghaochen/agent-universe`.
- **Public release** (later): architectural redesign once internal users have
  validated the experience.

## Status (last updated 2026-05-05)

Phases 0–4 implemented end-to-end on the `distribution` branches in both
repos. The full loop has been smoke-tested locally: install → enter Gemini
key in Settings → install background services → sign in to cloud → talk to
voice agent → telemetry rows appear in dashboard.

| Phase | Status | Notes |
|---|---|---|
| Phase 0 — Lift hardcoded assumptions | **DONE** | All 6 sub-phases. Backwards-compatible: dev workflow unchanged when `SUTANDO_HOME` unset. Commit `b8e35d8`. |
| Phase 1 — `.app` bundle + installer | **DONE** (1.4 merged into 4.7) | Bundle, Xcode-free build script, ad-hoc signing, launchd installer, DMG. Bundled Node/Python deferred — relies on Homebrew on the target Mac. Commit `a840053`. |
| Phase 2 — Signing, notarization, auto-update | **DONE** (no creds yet) | Code is wired; release workflow runs in degraded mode until Apple Developer ID + Sparkle key secrets are set in GitHub Actions. Commit `97decf5`. |
| Phase 3 — Cloud control plane | **DONE** (running locally) | Skeleton, schema, auth, API endpoints, billing, dashboard. Deploy to Vercel still pending. `agent-universe` commit `82ac0b2`. |
| Phase 4 — Desktop ↔ cloud wiring + telemetry | **DONE** | Sign-in via `sutando://` URL scheme, keychain token, heartbeat, three meters wired (voice, TTS, image-gen). Commit `9e1b80f`. |
| Phase 4.7 — Settings + first-launch flow | **DONE** (added post-plan) | Triggered by real-world test — original Phase 1.4 deferral was wrong. See section below. |
| Phase 4-bug — launchd installer hardening | **DONE** (added post-plan) | First install bailed mid-way on `Disabled=true` plist. Installer now collects errors instead of throwing + skips disabled plists. |
| Phase 4-core-agent — Claude Code as launchd service | **DONE** (added post-plan) | Voice agent reported "core agent isn't running" because the original 7-plist set didn't include Claude Code itself. Added `com.sutando.core-agent.plist` + `src/run-core-agent.sh` wrapper. |
| Phase 5 — Architectural redesign | **PENDING** | Intentionally deferred until after internal release. |

Operational gaps before we can hand a build to internal users:

- Cloud must be deployed to a real domain (Vercel + DNS for `sutando.ai`)
  with production Neon, Clerk, Stripe credentials.
- Apple Developer ID cert + Sparkle EdDSA keypair generated and stored as
  GitHub Actions secrets so `release.yml` produces a notarized DMG.
- Manual smoke test on a fresh Mac (one without the dev environment) to
  verify the install → settings → use loop works end-to-end without any
  Terminal commands.

## Guiding principle: wrap, don't refactor

For the internal release, every existing service keeps running exactly as it
does today — same processes, same ports, same `tasks/` / `results/` file
bridge, same Claude Code in tmux. We put a proper macOS package around it and
add a thin cloud layer beside it. The redesign happens after.

## Repository split

Two repos with independent release cadence:

| Repo | Path | Owns |
|---|---|---|
| `sutando` | `/Users/lianghaochen/stando` | Everything desktop-side: core agent code, skills, Swift launcher, Xcode project, signing/notarization CI. The current `src/Sutando/main.swift` becomes the launcher source inside the Xcode project. New top-level `app/` directory holds `Sutando.xcodeproj`, `Info.plist`, `entitlements.plist`, icons, Sparkle config. |
| `agent-universe` | `/Users/lianghaochen/agent-universe` | Cloud control plane. Next.js + Neon + Clerk + Stripe + Cloudflare R2. Owns auth, billing, usage aggregation, dashboard, hosted relays. |

Why no separate `sutando-app` repo:

- `sutando` is already a fork of the upstream public sutando project, so divergence is happening regardless.
- The Swift launcher already lives in `src/Sutando/`; moving it out is busywork.
- One clone gets a developer everything they need to build the app from source.
- macOS CI lives in the same workflow file as the existing Ubuntu typecheck CI.
- Upstream merges from the original sutando repo touch `src/` and `skills/`; the new `app/` directory is yours and never conflicts.

`agent-universe` stays separate because it has a different deploy target (edge/cloud), different security model (server-side secrets), and different stack (Next.js + Postgres). The cloud never sees the user's local skills.

## Stack defaults

| Layer | Choice |
|---|---|
| Bundle ID | `com.sutando.app` |
| Code signing | Apple Developer ID Application |
| Update channel | Sparkle 2 with own appcast (channels: `internal`, `beta`, `stable`) |
| Cloud framework | Next.js on Vercel |
| Database | Neon Postgres |
| Auth | Clerk |
| Billing | Stripe |
| Object store | Cloudflare R2 (transcripts, blobs) |
| Claude Code model | BYO subscription (user provides their own) |
| Phone | Hosted Twilio relay (we operate the account) |

## Current-state pain points the plan addresses

Findings from the audit (2026-05-04) that constrain the design:

- No `.app` bundle, no `Info.plist`, no entitlements, no signing. The
  "menu bar app" is a 1,486-line raw Swift binary (`src/Sutando/main.swift`).
- No launchd plists exist in the repo despite being referenced in
  `health-check.py:123-124` and the README. All services are launched inline
  by `bash src/startup.sh` as background processes.
- No CI for macOS builds (`.github/workflows/ci.yml` runs Ubuntu only).
- No auth, no users, no billing — `userId` hardcoded to `'user'` in
  `voice-agent.ts:802`.
- No version/update mechanism. `package.json:3` says `0.1.0`.
- Hardcoded paths: `~/Desktop/sutando` in `migrate.sh:11`; repo-path-derived
  memory dir slug in `startup.sh:29` and `health-check.py:34`.
- Three of seven service ports have no env override (`dashboard.py:30`,
  `agent-api.py`, `screen-capture-server.py:17`).
- `bodhi-realtime-agent` is pinned to a GitHub commit
  (`package.json:17` → `github:sonichi/bodhi_realtime_agent#ffec0cd`) — won't
  survive a notarization audit.
- `claude-agent-sdk` (`package.json:13`) is a dependency but unused; we still
  exec the `claude` CLI through tmux.

---

## Phase 0 — Lift hardcoded assumptions [DONE — commit `b8e35d8`]

1. **Introduce `SUTANDO_HOME`** [DONE]. `state_path()` / `state_dir()` helpers
   in `util_paths.{ts,py}`; `stateRoot` in `main.swift`. Defaults to repo cwd
   when unset → no behavior change for dev workflow.
2. **Add port-override env vars** [DONE]. `DASHBOARD_PORT`, `AGENT_API_PORT`,
   `SCREEN_CAPTURE_PORT`, `SUTANDO_SCREENSHOT_DIR` added.
3. **Stable memory dir** [DONE]. `SUTANDO_MEMORY_DIR` was already supported in
   `voice-context.ts` and `health-check.py`; documented in `.env.example`.
4. **Vendor `bodhi-realtime-agent`** [DONE]. Switched from
   `github:sonichi/bodhi_realtime_agent#ffec0cd` to npm `0.1.5`.
5. **Convert inline launches to launchd** [DONE]. LaunchAgent templates ship
   in `app/LaunchAgents/`. Final service list (8, not 8 — task-bridge dropped
   because it's a module not a process; core-agent added later in Phase
   4-core-agent):
   - `com.sutando.voice-agent`
   - `com.sutando.web-client`
   - `com.sutando.dashboard`
   - `com.sutando.agent-api`
   - `com.sutando.screen-capture`
   - `com.sutando.credential-proxy`
   - `com.sutando.core-agent` (added post-plan, Phase 4-core-agent)
   - `com.sutando.phone-conversation` (paid tier; ships `Disabled=true`,
     installer skips bootstrap — see Phase 4-bug)
6. **Config layering** [DONE]. `src/load-env.ts` loads repo `.env` first then
   `$SUTANDO_HOME/.env` with override; `startup.sh` sources the latter so
   Python services inherit it; Settings window writes to `$SUTANDO_HOME/.env`
   (Phase 4.7).

## Phase 1 — `.app` bundle + installer [DONE — commit `a840053`]

Bundle structure:

```
Sutando.app/
├── Contents/
│   ├── Info.plist                          # com.sutando.app, version, NSUsageDescription strings
│   ├── MacOS/Sutando                       # Swift launcher (was src/Sutando/main.swift)
│   ├── Resources/
│   │   ├── runtime/
│   │   │   ├── bin/node                    # Node 22 single-executable (sea-build), Universal2
│   │   │   ├── bin/python3                 # bundled Python or use system
│   │   │   ├── bin/fswatch                 # bundled binary
│   │   │   └── bin/ffmpeg                  # bundled binary
│   │   ├── repo/                           # current src/ + skills/ tree, read-only
│   │   ├── LaunchAgents/                   # com.sutando.*.plist templates
│   │   └── icons/AppIcon.icns
│   └── _CodeSignature/
```

Concrete work — what shipped:

- **No Xcode project** [DONE differently]. `app/build-app.sh` shells out to
  `swiftc` directly, listing each Swift source. Cleaner for a small
  multi-file launcher; no `.pbxproj` to maintain. main.swift's
  `workspace` now prefers `Bundle.main.resourcePath/repo` when bundled,
  falls back to the 8-dir-walk for raw-binary dev (preserves existing
  workflow).
- **Node bundling deferred** [PARTIAL → v2]. Single-executable Node via
  `--experimental-sea-config` requires a static-link toolchain that
  Homebrew's node doesn't ship with. `LaunchAgentInstaller` falls back to
  `/opt/homebrew/bin → /usr/local/bin → /usr/bin` so the .app works as
  long as the user has Homebrew node + python3 + fswatch. Documented in
  `app/README.md`. Bundling the official static Node tarball is v2.
- **`claude` CLI as separate prereq** [DONE]. Settings shows a missing-
  prereq warning in the core-agent log (`run-core-agent.sh` self-checks
  for `tmux` and `claude` on PATH and sleeps 60s rather than crash-loop).
- **First-launch wizard** [SUPERSEDED by Phase 4.7]. Originally deferred
  with the assumption "internal users are devs". Real-world test killed
  that assumption — without a Settings UI, even devs had to hand-edit
  `~/Library/Application Support/Sutando/.env`. Replaced by the Settings
  window — see Phase 4.7.
- **`.dmg` build** [DONE]. `app/build-dmg.sh` produces a 93MB UDZO DMG
  with `/Applications` symlink and READ ME FIRST, via `hdiutil`.

## Phase 2 — Signing, notarization, auto-update [DONE — commit `97decf5`]

Code is wired; the workflow runs in degraded mode (ad-hoc signing,
unsigned appcast warnings) until the GitHub Actions secrets below are
populated. To turn on full signing:

1. Set `APPLE_DEVELOPER_ID_CERT_P12_BASE64` + `APPLE_DEVELOPER_ID_CERT_PASSWORD`
2. Set `APPLE_ID` + `APPLE_TEAM_ID` + `APPLE_APP_SPECIFIC_PASSWORD`
3. Run `bash app/sparkle/generate-keys.sh` once locally; paste the public
   key into `app/Info.plist` (replacing `REPLACE_WITH_PUBLIC_ED_KEY`); set
   `SPARKLE_PRIVATE_KEY_BASE64` from the exported private key.

After that, pushing a `v*` tag produces a signed + notarized DMG +
EdDSA-signed appcast and uploads to GitHub Releases.

- **Apple Developer ID Application** certificate stored in 1Password and GitHub
  Secrets.
- **CI workflow** on a GitHub-hosted M-series runner:
  ```
  build .app → codesign --options runtime --entitlements Sutando.entitlements
            → xcrun notarytool submit --wait
            → stapler staple
            → create-dmg
            → upload to GitHub Releases (or sutando.ai CDN)
  ```
- **Sparkle 2** with EdDSA-signed appcast hosted at
  `updates.sutando.ai/appcast.xml`. Channels:
  - `internal` — internal release, gated by user account flag
  - `beta` — opt-in for friendly users
  - `stable` — public default (later)
- **Entitlements required**:
  - `com.apple.security.automation.apple-events` (heavy `osascript` use in
    `inline-tools.ts`, `browser-tools.ts`)
  - `com.apple.security.device.microphone`
  - `com.apple.security.files.user-selected.read-write`
  - `com.apple.security.network.client` and `com.apple.security.network.server`
  - Hardened runtime enabled, library validation disabled (we exec node +
    python).

---

## Phase 3 — Cloud control plane [DONE — `agent-universe` commit `82ac0b2`]

### Architecture

```
       ┌──── sutando.ai (marketing + login) ────┐
       │                                         │
       │   /api/auth         → Clerk             │
       │   /api/billing      → Stripe webhooks   │
       │   /api/usage        → aggregated events │
       │   /api/relay/twilio → Twilio webhook    │
       │   /api/gateway/llm  → Gemini proxy      │
       │                                         │
       └─── Postgres (Neon) ─── Object store ────┘
                ▲
                │ HTTPS, signed events
                │
         ┌────[ Sutando.app on user's Mac ]────┐
         │   stores cloud token in keychain     │
         │   ships event_log entries to cloud   │
         │   on paid tier: routes voice / phone │
         │   / image-gen calls through gateway  │
         └──────────────────────────────────────┘
```

### Database schemas (Neon)

```sql
-- Users
users (
  id uuid pk,
  clerk_id text unique,
  email text,
  org_id uuid nullable,        -- nullable from day 1, supports teams later
  plan text,                   -- 'free' | 'plus' | 'pro'
  current_period_end timestamptz,
  created_at timestamptz
);

-- Devices (one user can have multiple Macs)
devices (
  id uuid pk,
  user_id uuid fk,
  machine_id text,             -- stable UUID stored in SUTANDO_HOME/device.json
  hostname text,
  app_version text,
  last_seen timestamptz,
  created_at timestamptz
);

-- Append-only usage events
usage_events (
  id bigserial pk,
  user_id uuid fk,
  device_id uuid fk,
  kind text,                   -- 'voice.gemini', 'phone.twilio.outbound', 'image.gen', 'skill.run', etc.
  ts timestamptz,
  units numeric,               -- seconds, count, tokens — meaning depends on kind
  cost_cents integer,
  metadata jsonb               -- skill name, model, etc.
);

-- Credit ledger (single source of truth for paid-tier balance)
credits_ledger (
  id bigserial pk,
  user_id uuid fk,
  ts timestamptz,
  delta integer,               -- positive = credit, negative = debit
  reason text,                 -- 'subscription.renewal', 'usage.voice', 'topup', etc.
  balance_after integer
);

-- Hosted phone numbers
phone_numbers (
  id uuid pk,
  user_id uuid fk,
  e164 text unique,
  twilio_sid text,
  monthly_cost_cents integer,
  provisioned_at timestamptz,
  released_at timestamptz nullable
);

-- API keys (app→cloud and dev→app)
api_keys (
  id uuid pk,
  user_id uuid fk,
  scope text,                  -- 'app', 'dev', 'webhook'
  hashed text,
  created_at timestamptz,
  revoked_at timestamptz nullable
);
```

### Auth flow

1. App opens `https://sutando.ai/cli-login?challenge={nonce}` in default
   browser.
2. User authenticates via Clerk.
3. Cloud POSTs token back to a one-shot localhost listener the app raised.
4. Token stored in macOS keychain (`com.sutando.app.cloud-token`).
5. Subsequent app→cloud requests use the token in `Authorization: Bearer`.

### Telemetry instrumentation

Extend `src/event_log.py` with a `cloud_sink` that batches events to
`/api/usage` every 60s. Tag every event with `device_id` and `user_id`.

**Privacy default**: ship counts and durations only. Message bodies /
transcripts only when user opts in to "Cloud transcripts" (Pro feature).

**Instrumentation points** (existing files in `sutando` repo):

| File:line | Event kind | Units |
|---|---|---|
| `src/voice-agent.ts:141` | `voice.gemini` | seconds |
| `skills/phone-conversation/scripts/conversation-server.ts:1010` (`twilioCall`) | `phone.twilio.outbound` | call seconds |
| `skills/phone-conversation/scripts/conversation-server.ts:1024` (`twilioHangup`) | `phone.twilio.inbound` | call seconds |
| `src/cartesia-tts.ts:52-65` (`generateSpeech`) | `tts.cartesia` | audio seconds |
| `skills/image-generation/scripts/generate.py` | `image.gen` / `video.gen` | count / video seconds |
| `skills/quota-tracker/scripts/credential-proxy.ts` (port 7846) | `claude.code` | tokens (visibility only, no billing in v1) |
| `src/browser-tools.ts` (`describeScreenTool`) | `vision.gemini` | calls |

### Cloud dashboard

Same data the local `dashboard.py` (`localhost:7844`) shows today, plus
accessible from any browser. Shows:

- Device list with last-activity per device
- Voice / phone / image / video usage with month-to-date and forecast
- Current month bill breakdown
- Live status of each launchd service per device
- Transcript history (Pro tier only, opt-in)

---

## Phase 4 — Desktop ↔ cloud wiring + telemetry [DONE — commit `9e1b80f`]

Implemented:

- `src/Sutando/CloudAuth.swift` — keychain token, `sutando://auth?…` URL
  scheme handler with challenge validation, `$SUTANDO_HOME/cloud-auth.json`
  mirror so Node + Python services share the auth without keychain access,
  stable `machineId` in `device.json`, 5-minute heartbeat to `/api/devices`.
- `src/cloud-client.ts` — auth-aware fetch + batched event sender (60s or
  200 events) with 5000-event queue cap.
- `src/cloud_metrics.py` — fire-and-forget Python equivalent.
- `agent-universe` `cli-login` page redirects via URL scheme (legacy
  localhost-port path retained as fallback).
- `main.swift` — Sign in / Sign out menu items, URL scheme handler, 5-min
  heartbeat timer.
- Three meters wired: `voice.gemini` (`voice-agent.ts` writeVoiceMetrics),
  `tts.cartesia` (`cartesia-tts.ts` generateSpeech), `image.gen` /
  `video.gen` (`skills/image-generation/scripts/generate.py`).

Deferred to v2 (operational, not code):

- Hosted Twilio relay — needs a Twilio account we operate.
- Hosted Gemini gateway — needs a paid GCP project.
- These are paid-tier features; BYO works for internal release.

## Phase 4.7 — Settings + first-launch flow [DONE]

Added post-plan after the first real-world test — installing the .app and
trying to use it required hand-editing `.env`. Original Phase 1.4 wizard
deferral was wrong.

- `src/Sutando/EnvFile.swift` — round-tripping `.env` parser/writer that
  preserves comments + unknown keys.
- `src/Sutando/Permissions.swift` — TCC status (Microphone via
  `AVCaptureDevice`, Accessibility via `AXIsProcessTrusted`, Screen
  Recording via `CGPreflightScreenCaptureAccess`) plus
  `x-apple.systempreferences:` deeplinks.
- `src/Sutando/SettingsWindow.swift` — single-pane window with cloud
  account row, API key form (Gemini required + Cartesia + 12 advanced
  fields under disclosure), permission rows with Grant buttons, and
  Background Services Install / Uninstall.
- `main.swift` — `setupMainMenu()` builds an Edit menu so ⌘V works in
  text fields (LSUIElement apps don't get one by default — without it,
  pasting an API key fails silently). `Settings…` menu item with `⌘,`
  accelerator. First-launch detection: if no Gemini key + no
  `$SUTANDO_HOME/.firstrun-complete` marker, Settings auto-opens 300ms
  after launch.

## Phase 4-bug — launchd installer hardening [DONE]

First Settings → Install attempt installed only 4 of 7 plists then
showed an error. Root cause: `launchctl bootstrap` of a plist with
`<key>Disabled</key><true/>` returns "Bootstrap failed: 5: Input/output
error", which threw and aborted the install loop mid-stream
(`com.sutando.phone-conversation` ships disabled because it's the
paid-tier service).

Fix in `src/Sutando/LaunchAgentInstaller.swift`:

- New `LaunchAgentInstallSummary` struct with `installed` /
  `skippedDisabled` / `failed` lists.
- `install()` now collects errors instead of throwing on first failure.
- Detects `<key>Disabled</key><true/>` in the rendered template and
  writes the plist (so manual `launchctl enable` later works) but skips
  the bootstrap call.
- Settings + menu callers updated to display per-failure detail.

## Phase 4-core-agent — Claude Code as launchd service [DONE]

The original 7-plist set didn't include the Claude Code core agent —
the proactive loop that processes voice tasks queued in `tasks/`.
Real-world test surfaced it: `get_core_status` tool returned "not
running" because nothing in the install set actually ran `claude`.

- `src/run-core-agent.sh` — wrapper that creates a tmux session detached
  (`-d` so no TTY needed under launchd), runs claude with
  `--dangerously-skip-permissions /proactive-loop`, polls
  `tmux has-session` every 30s, and exits when the session ends so
  launchd's `KeepAlive` recreates it. Self-checks for `tmux` and
  `claude` on PATH and sleeps 60s rather than crash-loop on prereqs.
- `app/LaunchAgents/com.sutando.core-agent.plist.template` — runs the
  wrapper with `PATH` extended to include Homebrew dirs.
- Bundled into `Sutando.app/Contents/Resources/repo/src/` automatically
  by `build-app.sh` (already copies the whole `src/` tree).

Prereq the user must do once: `claude auth login` in Terminal.

## Phase 4 — Monetization (pricing plan, code partially in place)

### The Claude Code billing problem

We **cannot** charge users for Claude Code usage they're already paying
Anthropic for, and we should not pool Claude Code subscriptions:

- Anthropic Subscription terms forbid sharing access between users.
- API-key billing means we underwrite spikes; one runaway proactive loop costs
  us $50/day.
- Anthropic owns the relationship.

**v1 model: BYO Claude Code.** User installs Claude Code locally with their own
login. The app uses their auth. We never see the tokens. We don't pay
Anthropic. We don't bill for core agent usage at all.

Reconsider only if Anthropic ships a partner program for hosted Claude Code.

### What we charge for in v1

The product wedge is "all the painful infrastructure around Claude Code,
packaged."

| Charge for | Why it works | Metering point | Pricing |
|---|---|---|---|
| Hosted phone numbers (Twilio relay) | Replaces Twilio account + ngrok + webhook setup. Real friction-kill. | `conversation-server.ts:1010, :1024` | Plus: 1 number + 100 min, then $0.04/min outbound, $0.025/min inbound |
| Hosted voice (Gemini gateway) | Free tier 15 req/min rate-limits heavy users mid-call. We provide a paid Gemini key, smooth quotas. | `voice-agent.ts:141`, `cartesia-tts.ts` | Included in tier ($0.05/min over quota) |
| Image / video generation | Veo 3.1 ~$0.30/min of video. Modest markup. | `image-generation/scripts/generate.py` | $0.10/image, $0.50/sec of video |
| Cloud sync + memory | Replaces BYO-private-GitHub-repo (`SUTANDO_MEMORY_REPO`) and SSH+rsync `cross-node-sync` skill. | New service | Included in paid tier |
| Cloud dashboard + transcripts | Watch your Sutando from your phone, search transcripts, export. | `event_log.py` cloud sink + R2 | Included; retention by tier |
| Auto-update + signed releases | Friction-kill. Drives adoption. | Sparkle | Free for everyone |
| Premium TTS (Cartesia) | Better voice than Gemini's. | `cartesia-tts.ts:52` | Included in Pro |

### Tiers

- **Free** — Local install. BYO Claude Code, BYO Gemini, BYO Twilio. Cloud
  account = device-list dashboard + auto-update only. The funnel.
- **Plus — $19/mo** — Hosted phone (1 number + 100 min), hosted voice, cloud
  sync + memory, cloud dashboard with 7-day transcript retention.
- **Pro — $49/mo** — Plus + 500 phone min + 1000 image gens + premium TTS +
  30-day transcripts + multi-device (3 Macs).
- **Credit wallet** for one-shot expensive things (long phone calls, video
  generation) — bought in $10 increments, never expires.

For internal release, wire **billing infrastructure end-to-end** with one paid
SKU ("Sutando Plus") even if every internal user is on $0 with manual
override. Proves the path.

### Future revenue hooks (design now, charge later)

Even if not in v1, the cloud schema must support:

- **Per-skill metering** — `usage_events.kind = 'skill.run'` with skill name,
  so premium skills can be billed.
- **Per-task quotas** — extend `tasks/` filename convention to
  `task-{ts}-{user_id}.txt` so cloud can attribute every task.
- **Org/team accounts** — `users.org_id` nullable from day 1.
- **API access for power users** — issue API tokens via cloud, extend
  `agent-api.py` (already supports `SUTANDO_API_TOKEN`) to per-user tokens.

---

## Phase 5 — Architectural redesign [PENDING — post-internal, before public]

These will surface during internal use. Don't pre-fix them:

1. **Replace file bridge with proper IPC** — `tasks/` / `results/` + fswatch is
   racy under load. Move to Unix domain socket or in-process Claude Agent SDK
   calls (already a dependency at `package.json:13`, unused). Eliminates tmux,
   the watcher, and dramatically improves latency.
2. **First-class multi-user mode** — currently `userId='user'` hardcoded in
   `voice-agent.ts:802`; many scripts assume single owner.
3. **Skills as a runtime, not symlinks** — replace `~/.claude/skills/` symlink
   approach with versioned, signature-checked skill loader and registry.
4. **Replace tmux + Claude CLI** with `claude-agent-sdk` calls. Removes 4
   external dependencies.
5. **Stop running with `--dangerously-skip-permissions`** (`startup.sh:351`).
   Replace with hook-based approval flows + menu-bar consent prompts.
6. **Test infrastructure** — current `tests/` is thin. Need integration tests
   for file bridge, voice round-trip, phone round-trip.

---

## Sequencing

Original 5–6 week plan, actually completed (code-side) in one session
plus a debugging round. The bottleneck shifted from "writing the code"
to "operational provisioning".

| Track A — App (`sutando` `app/`) | Track B — Cloud (`agent-universe`) | Track C — Telemetry (`sutando`) |
|---|---|---|
| Phase 0 path/port cleanup [DONE] | Next.js + Neon + Clerk skeleton [DONE] | `cloud-client.ts` + `cloud_metrics.py` [DONE] |
| Phase 1 .app bundle [DONE] | Stripe products + webhooks; `/api/auth`, `/api/usage` [DONE] | `voice.gemini`, `tts.cartesia`, `image.gen` instrumentation [DONE] |
| Phase 2 signing + notarization + Sparkle [DONE — needs secrets] | Cloud dashboard MVP [DONE] | End-to-end event flow [DONE — verified locally] |
| Phase 4.7 Settings + first-launch [DONE] | Manual-override Plus subscriptions [PENDING] | — |
| Phase 4-bug installer hardening [DONE] | Production deploy (Vercel + DNS) [PENDING] | — |
| Phase 4-core-agent claude wrapper [DONE] | Phone relay [PENDING — paid tier] | — |
| Internal alpha [PENDING] | | |
| Apple Developer ID + Sparkle keys [PENDING] | | |

## Operational notes

- **Internal user pool**: plan for 5–10 users on Macs running macOS 15+.
- **Twilio account ops** for phone relay: number provisioning, fraud
  monitoring, abuse detection. Budget for ~$50/mo overhead during internal
  phase.
- **Gemini quota**: provision a paid GCP project with billing for the hosted
  voice gateway. Forecast ~$50–200/mo per active user on voice.
- **Privacy**: every cloud-shipped event must be opt-out by default for free
  tier, opt-in for transcripts on paid. Document clearly in onboarding wizard.

## Cross-references

- Cloud control plane: `/Users/lianghaochen/agent-universe/README.md`
- Core agent code: this repo (`sutando`)
- Audit findings: see commit history when this doc was authored (2026-05-04)
