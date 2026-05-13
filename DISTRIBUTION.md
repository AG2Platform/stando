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

## Status (last updated 2026-05-06)

Phases 0–4 + post-plan polish implemented end-to-end on the `distribution`
branches in both repos. The full loop has been smoke-tested both locally
AND from the DMG on a clean user-account simulation (state stashed aside):
install → enter Gemini key → click Install Claude Code → click Install
Background Services → grant TCC prompts → talk to voice agent → core agent
processes proactive loop → screen capture works. Cloud sign-in works
locally. The remaining work is operational: deploy cloud to production,
turn on signing/notarization, and validate end-to-end from a different Mac
on a different network. Phase 4.10 below sequences exactly that.

| Phase | Status | Notes |
|---|---|---|
| Phase 0 — Lift hardcoded assumptions | **DONE** | All 6 sub-phases. Backwards-compatible: dev workflow unchanged when `SUTANDO_HOME` unset. Commit `b8e35d8`. |
| Phase 1 — `.app` bundle + installer | **DONE** (1.4 merged into 4.7, 1.5 done in 4.8) | Bundle, Xcode-free build script, ad-hoc signing, launchd installer, DMG. Commit `a840053`. |
| Phase 2 — Signing, notarization, auto-update | **DONE** (no creds yet) | Code is wired; release workflow runs in degraded mode until Apple Developer ID + Sparkle key secrets are set in GitHub Actions. Commit `97decf5`. |
| Phase 3 — Cloud control plane | **DONE** (running locally) | Skeleton, schema, auth, API endpoints, billing, dashboard. Deploy to Vercel still pending — see Phase 4.10. `agent-universe` commit `82ac0b2`. |
| Phase 4 — Desktop ↔ cloud wiring + telemetry | **DONE** | Sign-in via `sutando://` URL scheme, keychain token, heartbeat, three meters wired (voice, TTS, image-gen). Commit `9e1b80f`. |
| Phase 4.7 — Settings + first-launch flow | **DONE** (added post-plan) | Triggered by real-world test — original Phase 1.4 deferral was wrong. See section below. |
| Phase 4-bug — launchd installer hardening | **DONE** (added post-plan) | First install bailed mid-way on `Disabled=true` plist. Installer now collects errors instead of throwing + skips disabled plists. |
| Phase 4-core-agent — Claude Code as launchd service | **DONE** (added post-plan) | Voice agent reported "core agent isn't running" because the original 7-plist set didn't include Claude Code itself. Added `com.sutando.core-agent.plist` + `src/run-core-agent.sh` wrapper. |
| Phase 4.8 — Self-contained .app | **DONE** (commit `15b2114`) | Bundled Node 22 LTS + tmux + ncurses terminfo (Phase 1.5 finally done); fswatch replaced by Node `fs.watch`; in-app WKWebView windows for voice + dashboard (no more Chrome dependency); Claude Code detect-install-signin row in Settings; 4-step first-launch stepper. |
| Phase 4.9 — Fresh-Mac install validation | **DONE** (commit `8f96454`) | Six bugs surfaced by walking the install flow on a clean user account: hardened-runtime mic entitlement key, LSUIElement TCC prompt suppression, missing skills symlinks, Claude 2.1.x bypass-permissions warning auto-accept, `screencapture` PATH, python3 Screen Recording grant trigger. |
| Phase 4.10 — Distribution test (different-Mac, different-network) | **PENDING** | Three parallel tracks: cloud deploy, signed/notarized DMG, fresh-Mac validation. See section below for the ordered task list. |
| Phase 4.11 — Admin panel | **DONE** (`agent-universe` commit pending) | `/admin/*` routes — overview, funnel, retention, margins, features, reliability. Schema additions: `users.is_admin`, `usage_events.app_version` + `provider_cost_cents`, three new tables (`onboarding_events`, `error_events`, `sessions`). Three new ingestion endpoints (`/api/onboarding`, `/api/errors`, `/api/sessions`). See section below. |
| Phase 4.12 — Onboarding lifecycle (services tied to app process) | **DONE** | Plists now render into `$SUTANDO_HOME/LaunchAgents/` (not auto-loaded by macOS), bootstrap on app launch, bootout on cmd+Q. Voice web window auto-opens on launch. Stepper down to 3 steps; Install/Uninstall UI removed. See section below. |
| Phase 5 — Architectural redesign | **PENDING** | Intentionally deferred until after internal release. |

Operational gaps before we can hand a build to an external internal user:

- **Cloud production deploy** to `sutando.ag2.ai` (Vercel) with prod
  Neon branch, Clerk production instance, Stripe live mode + webhook,
  Tigris. (Phase 4.10 Track 1.)
- **Signing + notarization secrets** in GitHub Actions: Developer ID
  Application cert .p12 (we have the Apple account), app-specific
  password, Sparkle EdDSA private key. (Phase 4.10 Track 2.)
- **Bake `apiBase` into the .app** — `CloudAuth.swift` currently keeps
  whatever was typed at sign-in; production builds need a default of
  `https://sutando.ag2.ai`. (Phase 4.10 Track 2.)
- **Desktop-side emission** of the new admin telemetry — DONE. See
  Phase 4.10 Track 4 below for the surfaces wired (Swift onboarding/error
  emitters, voice + phone session lifecycle, `appVersion` injection on
  every event). Three small surfaces deferred (cartesia 5xx,
  image-gen rate limits, per-skill metadata) — not on the critical path.

The "manual smoke test on a fresh Mac" gap was closed in this round —
walked the install flow on a stashed-state account simulation, fixed
every install-time bug surfaced. See Phase 4.9. Phase 4.10 is the
NEXT-Mac-on-NEXT-network test, which exercises a different surface:
Gatekeeper, public DNS, third-party network paths, prod Stripe.

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
| `agent-universe` | `/Users/lianghaochen/agent-universe` | Cloud control plane. Next.js + Neon + Clerk + Stripe + Tigris. Owns auth, billing, usage aggregation, dashboard, hosted relays. |

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
| Object store | Tigris (transcripts, blobs) — S3-compatible, zero egress, partnership |
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
  (`package.json:17` → `github:sonichi/bodhi_realtime_agent#ffec0cd`). Reviewed
  2026-05-12: notarization actually traverses node_modules to re-sign Mach-O
  binaries (which `build-app.sh` does) but doesn't care about the source URL,
  so the pin is safe to keep. The npm 0.1.5 release sends the deprecated
  `media`/`media_chunks` wire format that Gemini 3.1 closes with code 1007;
  the github commit pin restores the new `audio`/`video` slot routing.
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
4. **Vendor `bodhi-realtime-agent`** [SUPERSEDED]. Originally intended to
   switch to npm `0.1.5` but reverted: npm 0.1.5 sends the deprecated
   `media`/`media_chunks` realtimeInput wire format which Gemini 3.1 closes
   with code 1007. Kept at `github:sonichi/bodhi_realtime_agent#ffec0cd` —
   notarization re-signs the bundled Mach-O binaries (sharp, etc.) and
   doesn't care about the source URL, so the pin is safe.
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
- **Node bundling** [DONE in Phase 4.8 — commit `15b2114`]. Initially
  deferred (single-executable Node via `--experimental-sea-config` needs a
  static-link toolchain that Homebrew's node doesn't ship with). Now done
  via `app/bundle-runtime.sh` which downloads the official Node 22 LTS
  macOS tarball, strips debug symbols (114MB → 95MB), and ad-hoc signs.
  tmux + libevent/libncursesw/libutf8proc dylibs also bundled with rpaths
  rewritten to `@executable_path/../lib`; ncurses terminfo bundled so tmux
  can resolve `$TERM` under launchd. fswatch dropped entirely — replaced
  by Node `fs.watch`. `LaunchAgentInstaller` still falls back to Homebrew
  paths for the dev workflow. See Phase 4.8.
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
            → upload to GitHub Releases (or ag2.ai/sutando CDN)
  ```
- **Sparkle 2** with EdDSA-signed appcast hosted at
  `ag2.ai/sutando/updates/<channel>/appcast.xml`. Channels:
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
       ┌──── sutando.ag2.ai (auth + dashboard) ────┐
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

1. App opens `https://sutando.ag2.ai/cli-login?challenge={nonce}` in default
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

## Phase 4.8 — Self-contained .app: bundled runtime + in-app windows + guided setup [DONE — commit `15b2114`]

Closes the gap between "internal release UX" and "public release UX": the
.app drag-installs and walks the user through setup with zero Terminal
touch except `claude auth login` (Anthropic owns that flow). Five blocks
of work, all wrap-don't-refactor:

### Bundled runtime (Phase 1.5 finally)

`app/bundle-runtime.sh` stages a self-contained runtime under
`app/vendor/runtime/`, copied into `Sutando.app/Contents/Resources/runtime/`
by `build-app.sh`:

- `bin/node`, `bin/npm`, `bin/npx` — official Node 22 LTS tarball,
  stripped + ad-hoc signed (~95MB)
- `bin/tmux` — Homebrew tmux re-rpathed to load its dylibs from
  `@executable_path/../lib`
- `lib/libevent_core-2.1.7.dylib`, `lib/libncursesw.6.dylib`,
  `lib/libutf8proc.3.dylib` — tmux's dylib chain
- `share/terminfo/` — ncurses terminfo so tmux can resolve `$TERM` under
  launchd (the wrapper exports `TERMINFO_DIRS` to point here)

System `python3` (`/usr/bin/python3`) is sufficient on macOS 15 — not
bundled. ffmpeg deferred (only the video-skill subset needs it).

`SKIP_BUNDLE_RUNTIME=1` env var skips the bundle step in `build-app.sh`
when the runtime is already staged (CI uses this between iterative builds).

### fswatch removed

Replaced by Node `fs.watch` in two new scripts that match the prior
on-the-wire contract:

- `src/watch-tasks.mjs` — one-shot watcher (replaces `watch-tasks.sh`)
- `src/watch-tasks-stream.mjs` — streaming watcher with rename-out
  filter + parent-dir guard + per-file dedupe (replaces `watch-tasks-stream.sh`)

The original `.sh` files are now thin `exec node` wrappers, so every
caller — `bash src/watch-tasks.sh`, `proactive-loop/SKILL.md`, Monitor
tool invocations, `pgrep -f watch-tasks` — keeps working unchanged.
Sweep also touches `startup.sh`, `init.sh`, `verify-setup.sh`,
`migrate.sh`, `README.md`, `app/README.md`, code comments.

### In-app web windows (WKWebView)

`src/Sutando/WebWindow.swift` — generic WKWebView NSWindow controller
used for both the voice client (`localhost:8080`) and the dashboard
(`localhost:7844`). Replaces the prior AppleScript-drives-Chrome path.
Backend services unchanged — same launchd-managed processes, just a
different rendering surface.

- Mic + camera auto-granted for `localhost` origins via `WKUIDelegate`
- Cold-start retry: 30 attempts × 1s backoff handles the case where
  launchd hasn't bootstrapped the service yet
- Position autosave per window
- Friendly fallback HTML pointing the user at Settings → Background
  Services if the service stays unreachable
- On window close, navigates to `about:blank` to release mic + audio

`main.swift` `openWebUI()` and `openDashboard()` now spawn
`WebWindowController` instances instead of AppleScripting Chrome. Apple
Events permission to Chrome no longer needed.

### Claude Code installer in Settings

New section between API keys and Permissions:

- Detects `claude` on PATH (also checks `~/.local/bin`, `/usr/local/bin`,
  `/opt/homebrew/bin`, `~/.npm-global/bin`)
- "Install" button runs `curl -fsSL https://claude.ai/install.sh | bash`
  via `NSTask` with progress spinner
- "Sign in…" button opens Terminal.app with `claude auth login` (only
  Terminal touch in the install flow)
- Status auto-refreshes every 1.5s while window is open

### First-launch stepper

Horizontal 3-step indicator at the top of Settings:

```
① API key › ② Claude Code › ③ Permissions
```

(Originally 4 steps; "Background services" was removed in Phase 4.12
once service install + start became automatic on app launch.)

Each step shows ○ / ✓ based on live state checked every 1.5s. Hides
once `$SUTANDO_HOME/.firstrun-complete` exists (written on first
successful Save). Drives non-technical users through setup without a
README.

## Phase 4.9 — Fresh-Mac install validation [DONE — commit `8f96454`]

Six bugs surfaced by walking the install flow on a clean user-account
simulation (state stashed at `~/Library/Application Support/Sutando.bak`,
DMG mounted, dragged to /Applications, right-click Open). All install-time
issues — none of them appeared in dev-machine testing because the dev
machine had accumulated state that masked them.

1. **Mic prompt suppressed by hardened runtime** — tccd flat-out refused
   to prompt: `Prompting policy for hardened runtime; service:
   kTCCServiceMicrophone requires entitlement
   com.apple.security.device.audio-input but it is missing`. The bundle
   had `device.microphone` (sandbox-era key) but not `device.audio-input`
   (hardened-runtime key). Added both to `Sutando.entitlements`.

2. **LSUIElement TCC prompt suppression** — even with the right
   entitlement, mic prompts from `.accessory`-policy apps can be silently
   swallowed. `grantPermission` now bumps to `.regular` for the prompt
   duration and reverts after. Also reorders: fire `AVCaptureDevice.requestAccess`
   FIRST, fall through to System Settings only on user denial. (Opening
   Settings before the prompt steals focus and macOS suppresses prompts
   from non-frontmost apps.)

3. **`Unknown skill: proactive-loop`** — claude looks up slash commands
   in `~/.claude/skills/`, which a fresh user has empty. The bundled .app
   ships skills at `Resources/repo/skills/` but never seeded the user's
   global dir, so the core-agent crash-looped every 30s with the cryptic
   "session ended" message. `LaunchAgentInstaller.install()` now also
   runs the bundled `skills/install.sh` (which already idempotently
   symlinks each skill into `~/.claude/skills/`).

4. **Claude 2.1.x bypass-permissions warning** — Claude Code 2.1+ shows
   an interactive *"1. No, exit / 2. Yes, I accept"* dialog every launch,
   even with `--dangerously-skip-permissions`. The default selection is
   "exit", so the wrapper would idle until claude timed out (~30s) and
   exited. `run-core-agent.sh` polls `capture-pane` for the dialog and
   responds with `Down` then `Enter`; also kills any pre-existing tmux
   session on every wrapper start so a zombie session stuck on the
   warning can't be misread as healthy. Pane output piped to
   `core-agent.pane.log` for debugging. **Follow-up (2.1.133):** the two
   keys must be sent in **separate** `send-keys` calls with a 0.3s gap.
   2.1.133's TUI reads stdin fast enough that `send-keys Down Enter` in
   one call confirms the default-highlighted "1. No, exit" before the
   cursor visually advances — surfaced on a fresh DMG install on a new
   Mac, second crash-loop bug from the same dialog.

5. **`screencapture: No such file or directory`** — the screen-capture
   plist's `PATH` had `/usr/local/bin:/usr/bin:/bin` but the system
   `screencapture` binary lives at `/usr/sbin/screencapture`. Added
   `/usr/sbin` to the plist template.

6. **Python3 missing from Screen Recording list** — TCC tracks
   launchd-spawned python3 as a separate identity from `Sutando.app`.
   Granting Screen Recording to the .app didn't help the helper.
   `screenRecording.request()` now also pokes the running screen-capture
   service AND fork-spawns python3 with a one-shot `screencapture` so
   python3 lands in System Settings → Privacy → Screen Recording
   alongside Sutando.app. User toggles both in one trip. (System Audio
   Recording still needs manual grant for the `screen-record` skill —
   no clean way to register python3 for that without ScreenCaptureKit
   audio bindings.)

## Phase 4.12 — Onboarding lifecycle: services tied to app process [DONE]

Done in the same session as the PRODUCT.md beta wave work. The original
model installed plists into `~/Library/LaunchAgents/` from a Settings
button, then macOS auto-loaded them on every user login. Two real-world
problems with that:

- Required a manual "Install Background Services" click before anything
  worked — non-technical beta users got stuck here.
- Services kept running across reboots even when the user wasn't using
  Sutando — confusing surface area; harder to reason about.

The new model binds service lifecycle to the app process:

- **App open** → render plist templates to `$SUTANDO_HOME/LaunchAgents/`
  (writable, NOT auto-loaded by macOS at user login), `launchctl
  bootstrap` each one, then open the voice web window 1.5s later
  (WebWindowController retries cold-start failures for 30s so the race
  is covered).
- **App quit (cmd+Q)** → `launchctl bootout` every loaded com.sutando.*
  service synchronously before NSApplication exits.
- **First launch on upgraded machine** → `migrateLegacyPlists()` boots
  out + deletes any leftover `~/Library/LaunchAgents/com.sutando.*.plist`
  from the old install model, so users don't get double instances (one
  from login auto-load, one from the new app).

UX consequences:

- Install / Uninstall Background Services menu items removed.
- Settings "Background services" row no longer has Install/Uninstall —
  shows a live "N services running" status with a single Restart
  button.
- First-launch stepper drops from 4 → 3 steps (API key → Claude Code
  → Permissions). The 4th step disappeared because background services
  are now automatic.

Files touched:

- `src/Sutando/LaunchAgentInstaller.swift` — `runDir`,
  `legacyLaunchAgentsDir`, `migrateLegacyPlists()`, `stopAll()`,
  `booteachLabel(in:deletePlist:)` helper. Existing `install()` /
  `uninstall()` keep the same external shape; they just write to the
  new runDir.
- `src/Sutando/main.swift` — `applicationDidFinishLaunching` calls
  `autoBootstrapServices()` + `scheduleAutoOpenWebUI()`;
  `applicationWillTerminate` calls `LaunchAgentInstaller().stopAll()`;
  menu items for install/uninstall removed; in-app Restart/Stop
  buttons rewired through `LaunchAgentInstaller` instead of pkill.
- `src/Sutando/SettingsWindow.swift` — `stepNames` collapsed from 4 →
  3; new `servicesStatusLabel` + `refreshServicesUI()` + Restart
  button replace the old install row; `restartServicesFromSettings`
  handler.

## Phase 4.10 — Distribution test (different Mac, different network) [PENDING]

The Phase 4.9 fresh-Mac test was a clean *user account* on the same
hardware — same kernel, same network, same already-warmed-up TCC
database and existing Apple ID. A real distribution test exercises a
different surface: Gatekeeper on a download from the internet, public
DNS, prod Stripe webhooks, prod Clerk session cookies on a different
TLD. This phase sequences exactly that.

The Apple Developer account already exists, so Track 2 is just cert +
secret plumbing rather than a multi-day membership wait.

### Track 1 — Cloud production deploy

Goal: `sutando.ag2.ai` reachable from any browser, accepting heartbeats
and usage events from the desktop, with Stripe webhooks landing.

1. **Provision production secrets** (separate from dev):
   - Neon: new project (or new branch on the existing project) — keep
     dev branch for `localhost`. Capture both `DATABASE_URL` (pooled,
     for runtime) and `DATABASE_URL_UNPOOLED` (for migrations).
   - Clerk: new production instance. Generate publishable + secret keys.
     Configure allowed redirect URLs to include `sutando.ag2.ai`.
   - Stripe: live mode. Create products for Plus + Pro, capture price
     IDs into `STRIPE_PRICE_PLUS_MONTHLY` / `STRIPE_PRICE_PRO_MONTHLY`.
   - Tigris: bucket for transcripts/blobs. Capture access key id +
     secret + endpoint URL. S3-compatible — `@aws-sdk/client-s3` works
     unchanged. Defer until the transcripts feature actually ships;
     not on the critical path for the first internal user.
2. **Vercel deploy.** `vercel --prod` from `agent-universe` repo. Bind
   `sutando.ag2.ai` as the production domain. Set every env var in the
   Vercel project, including the Sparkle public key path.
3. **Run migrations.** `DATABASE_URL=$PROD_UNPOOLED npm run db:migrate`
   from a local checkout. Confirms `0001_admin_panel.sql` lands.
4. **Stripe webhook.** Create endpoint `https://sutando.ag2.ai/api/billing/webhook`
   in Stripe live mode, copy the signing secret into `STRIPE_WEBHOOK_SECRET`,
   redeploy, fire a `checkout.session.completed` test event, confirm a
   row updates in `users`.
5. **Promote yourself to admin.** One-shot SQL against prod Neon:
   `UPDATE users SET is_admin = true WHERE email = 'rickedwardboss@gmail.com';`
   (Won't work until your account exists in prod — sign in once first.)
6. **Smoke test from current Mac against prod.** Sign out of dev, edit
   `cloud-auth.json` `apiBase` to point at `https://sutando.ag2.ai`,
   sign in via prod Clerk, talk to voice agent, confirm a `voice.gemini`
   event lands in prod Neon within a minute. `/admin` page renders.
7. **DMG download proxy** [DONE — code]. `GET /api/download/<channel>`
   (channels: `stable` / `beta`) streams the latest GitHub release DMG
   through the Vercel function — Clerk-gated, browser only ever sees
   `sutando.ag2.ai` in the URL bar. Logs to a new `download_events`
   table (`user_id`, `channel`, `release_tag`, `bytes`, `ts`,
   `user_agent`) — feeds the activation funnel. Requires
   `GITHUB_TOKEN` env (fine-grained PAT, `Contents: Read` on the
   release repo) to lift GitHub's 60 req/hr unauthenticated rate
   limit. `GITHUB_RELEASE_REPO` defaults to `AG2Platform/stando`.
   Dashboard surfaces a "Download for Mac" card at the top of
   `/dashboard`. No CI changes — DMG stays on GitHub Releases as today.

### Track 2 — Signed/notarized DMG

Goal: a DMG on GitHub Releases that opens cleanly on a never-seen-it
Mac (no right-click-Open dance).

1. **Generate Developer ID Application cert.** Apple Developer portal →
   Certificates → Developer ID Application. Download, install in
   Keychain, export private key + cert as `.p12`.
2. **Set GitHub secrets** in `sutando` repo (already wired in
   `release.yml`):
   - `APPLE_DEVELOPER_ID_CERT_P12_BASE64` = `base64 -i cert.p12`
   - `APPLE_DEVELOPER_ID_CERT_PASSWORD` = the .p12 password
   - `APPLE_ID` = the Apple ID email
   - `APPLE_TEAM_ID` = 10-char team ID (Membership page)
   - `APPLE_APP_SPECIFIC_PASSWORD` = from appleid.apple.com
3. **Generate Sparkle keypair.** `bash app/sparkle/generate-keys.sh -x file`
   locally; paste public key into `app/Info.plist` (replace
   `REPLACE_WITH_PUBLIC_ED_KEY`); `base64 -i sparkle.priv` → set as
   `SPARKLE_PRIVATE_KEY_BASE64` GitHub secret. Commit the public-key
   change.
4. **Bake prod `apiBase` into the .app.** `CloudAuth.swift` currently
   reads whatever `apiBase` was set during sign-in. Add a compile-time
   default of `https://sutando.ag2.ai`, override-able via
   `SUTANDO_CLOUD_BASE` env var for dev. Without this the second Mac
   has nothing to sign in against on first launch.
5. **Tag a release.** `git tag v0.2.0 && git push --tags`. The
   `release.yml` workflow runs end-to-end on the macos-14 runner, lands
   a notarized DMG on GitHub Releases.
6. **Local verify.** Download from Releases, then on your Mac:
   - `xcrun stapler validate Sutando-0.2.0.dmg` should print
     "ticket valid".
   - `spctl -a -vvv -t install Sutando-0.2.0.dmg` should print
     "accepted source=Notarized Developer ID".
   Skip if either fails — no point shipping an unnotarized DMG to test
   distribution.

### Track 3 — Fresh-Mac validation

Goal: prove the package is distributable by exercising it on hardware
that has never seen Sutando.

1. **Provision a clean Mac.** Borrow one, or create a brand-new local
   user account on a Mac you haven't logged into Sutando with (cleaner
   than wiping). Don't pre-install Homebrew, Node, tmux — that's the
   whole point.
2. **Download via Safari.** From the GitHub Release page, not via
   `scp`. This exercises the `com.apple.quarantine` xattr that
   triggers Gatekeeper. Drag DMG to /Applications, open.
3. **Walk the 4-step Settings stepper.**
   - Gemini key (paste from another machine — confirm ⌘V works since
     LSUIElement apps need an explicit Edit menu, fixed in Phase 4.7).
   - Install Claude Code (button runs `curl ... | bash`, then opens
     Terminal for `claude auth login` — only Terminal touch).
   - Permissions (mic, screen recording, accessibility — known cliff,
     watch the funnel telemetry land).
   - Background services (launchd bootstrap; should install all 7 with
     `phone-conversation` deferred-disabled).
4. **Sign in to cloud from the second Mac.** Critical: this is the
   first time `sutando://` URL scheme is exercised on hardware where
   that scheme has never been registered.
5. **End-to-end task.** Talk to voice agent, get a response. Trigger
   one skill (e.g. "what's on my screen"). Confirm in `/admin` from a
   third device that:
   - The new device row exists with current `last_seen`.
   - `voice.gemini` event count is non-zero.
   - The funnel shows this user reached `first_voice`.
6. **Reopen 3×.** Force-quit the .app, reopen, force-quit again. The
   install must be idempotent — known weak point because `LaunchAgentInstaller`
   runs `skills/install.sh` on every install (Phase 4.9 #3) and that
   needs to be a no-op on second invocation.
7. **What we're watching for.** Distribution-only bugs that the same-Mac
   test couldn't surface:
   - Gatekeeper rejection (means notarization didn't staple).
   - First-launch deeplink to `sutando://auth?...` failing because URL
     scheme isn't registered until first launch completes (race).
   - TCC database differences across machines (each Mac's TCC is
     independent; even with the entitlement, prompts can land
     differently on a Mac with different OS minor version).
   - Stripe live-mode webhook landing on prod, not dev.
   - Cloud token bound to the wrong `apiBase` if the user signed in
     against a stale URL during bootstrap.

### Track 4 — Desktop-side admin telemetry emission [DONE]

Each new ingestion endpoint added in Phase 4.11 now has at least one
desktop-side caller. The funnel and reliability views populate as soon
as a signed-in user touches the surface in question.

- **`onboarding_events`** — Swift fires from `SettingsWindow`:
  `gemini_key_set` on Save (when key non-empty), `firstrun_complete`
  on Save, `claude_installed` from `refreshClaudeCodeUI()` once
  `claudeCodePath()` resolves, `perms_granted` when all three TCC
  checks return `.granted`, `services_installed` from `installServices()`
  when `summary.failed.isEmpty`. Per-launch in-memory dedup
  (`emittedOnboardingSteps`) avoids HTTP spam from the 1.5s polling
  loop; the server's `(user_id, step)` unique index is the source of
  truth.
- **`error_events`** — Swift emits one per `LaunchAgentInstaller` failure
  with `kind=launchd.bootstrap_fail`, plus `kind=launchd.install_failed`
  if the install function throws. TS-side: `voice-agent.ts` emits from
  `hooks.onError` and from the voice-failure transport classifier
  (kinds: `voice.<component>`, `voice.transport.<category>`);
  `conversation-server.ts` emits `phone.twilio.call_failed` on Twilio
  REST 4xx/5xx.
- **`sessions`** — `voice-agent.ts` opens a session in `onSessionStart`
  (kind=`voice`), captures `userTurnCount` + `voiceToolCalls` snapshot
  in `onSessionEnd` and PATCHes the same row.
  `conversation-server.ts` opens kind=`phone.outbound` in `twilioCall`
  (storing the start-promise per `callSid`), closes in `twilioHangup`.
  Inbound calls deferred — webhook-driven flow needs a different
  lifecycle hook.
- **`appVersion` injection** — every event now carries the value of
  `Bundle.main.infoDictionary.CFBundleShortVersionString` (in the .app)
  or `package.json:version` (dev workflow), read once at startup.
  Powers release-vs-release regression analysis on the
  `/admin/reliability` page.

Implementation:

- `src/cloud-client.ts` — added `recordOnboarding`, `recordError`,
  `startSession`, `endSession`, `appVersion` injection on usage events.
- `src/cloud_metrics.py` — Python equivalents for image-gen / Twilio
  / dashboard services; `record_error` and `record_onboarding`.
- `src/Sutando/CloudClient.swift` (new) — Swift caller for
  `/api/onboarding` and `/api/errors`. Reads `cloud-auth.json` the
  same way `CloudAuth.swift` does. Added to `app/build-app.sh`
  `SWIFT_SOURCES`.

Open instrumentation (deferred, low marginal value):

- `cartesia-tts.ts` 5xx → `tts.cartesia.error` (touches a hot path;
  current rate is low so not yet worth it).
- `image-generation/scripts/generate.py` Gemini rate-limit →
  `image.gen.rate_limit` via `record_error` (Python helper now exists,
  call site not yet wired).
- `run-core-agent.sh` prereq misses (tmux/claude not on PATH) → the
  wrapper is bash; emission would need either a curl call inside the
  shell script or a Swift-side health check that polls the wrapper's
  pane log. Trivial but defer.
- Per-skill `metadata.skill` on `usage_events.kind = 'skill.run'` —
  needs touching `task-bridge.ts` skill dispatcher; biggest payoff for
  `/admin/features` but more invasive.

Sequencing: Track 1 first (otherwise Track 3 has nothing to talk to);
Track 2 in parallel with Track 1. Track 3 is the integration moment
and gates "internal alpha". Track 4 is now done in code — the funnel
and reliability views populate immediately on first signed-in use.

## Phase 4.11 — Admin panel [DONE]

Admin observability for the cloud control plane. Five views answer
five product questions; schema additions support questions we can't
yet answer but will once desktop-side emission (Phase 4.10 Track 4)
lands.

### Schema additions (`agent-universe` `lib/db/migrations/0001_admin_panel.sql`)

- `users.is_admin boolean` — gates `/admin/*`. Promote via SQL during
  internal release; promote to a Clerk org-membership check before
  public launch.
- `usage_events.app_version varchar(32)` — per-event app version so
  release-vs-release regression analysis doesn't require a join blowup.
- `usage_events.provider_cost_cents integer` — what *we* pay providers
  (wholesale), distinct from `cost_cents` which is what the user owes
  us. Drives the gross-margin view. Populated by a server-side rate
  sheet (TODO — see below); falls back to `cost_cents` when null.
- `onboarding_events (user_id, device_id, step, ts, metadata)` —
  activation funnel. Partial-unique on `(user_id, step)` so idempotent
  emission is safe. Steps that can be derived from `users` /
  `devices` / `usage_events` are also computed in the funnel query so
  the view works before desktop emission lands.
- `error_events (user_id, device_id, kind, severity, message, stack,
  app_version, ts, metadata)` — reliability board. Severity tiers:
  `info` / `warn` / `error` / `fatal`.
- `sessions (id, user_id, device_id, kind, started_at, ended_at,
  duration_s, turn_count, tools_used jsonb, ended_reason,
  app_version, metadata)` — voice / phone session boundaries.
  Power-user behavior signal (which skills get invoked in a single
  voice session) which is technically derivable from `usage_events`
  but ugly to query.
- Indexes on `usage_events (user_id, ts)` and `(kind, ts)` — admin
  queries scan both.

### Routes

| Route | Question it answers |
|---|---|
| `/admin` | Single-pane overview. KPIs: users, paid, MAU/WAU/DAU, MRR, gross margin, errors/24h. |
| `/admin/funnel` | Where do users drop off between signup and habitual use? |
| `/admin/retention` | Of the cohort that signed up in week N, how many came back in W+1, W+2, W+4, W+8? |
| `/admin/margins` | Per-user revenue minus cost-to-serve. Top of list = runaway loops / abuse. |
| `/admin/features` | MAU/WAU per `kind`. Reveals whether you're a "voice product" or a "phone product" by behavior. |
| `/admin/reliability` | Errors by kind/severity over 24h, plus stale devices that stopped heartbeating. |

Access control via `lib/admin.ts:requireAdmin()` — wraps `requireAppUser`
+ `is_admin` check. Non-admins typing `/admin` are redirected to
`/dashboard` rather than 403'd.

### New ingestion endpoints (Bearer-token auth, scope=app)

| Endpoint | Method | Purpose |
|---|---|---|
| `/api/onboarding` | POST | Batch onboarding-event emission. ON CONFLICT DO NOTHING handles desktop retries. |
| `/api/errors` | POST | Batch error-event emission. Up to 100 per request. |
| `/api/sessions` | POST / PATCH | POST = start session, returns `id`. PATCH = end session by `id`, computes `duration_s`. |

Routes added to `middleware.ts` `isPublicRoute` list — they're
Bearer-token-protected per-request, not Clerk-session-protected.

### Open follow-ups

- **Server-side rate sheet** to populate `provider_cost_cents` per event
  (Twilio + Gemini + Cartesia + Veo wholesale). Without this, the
  margins view falls back to `cost_cents` which is retail not
  wholesale — accurate-ish but not the real cost-to-serve.
- **Time-to-first-value (TTFV)** metric: `MIN(usage_events.ts WHERE
  kind='voice.gemini') - users.created_at` per user, p50/p90. Trivial
  query but needs a card on `/admin`.
- **Net revenue retention (NRR)** cohort view — only meaningful at
  ≥20 paid users.
- **Per-skill popularity** — `usage_events.kind = 'skill.run'` with
  `metadata.skill = '<name>'` — depends on adding `recordEvent` calls
  inside the skill dispatcher in `task-bridge.ts`.

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
| Cloud dashboard + transcripts | Watch your Sutando from your phone, search transcripts, export. | `event_log.py` cloud sink + Tigris | Included; retention by tier |
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

1. **Replace file bridge with proper IPC** — `tasks/` / `results/` + Node
   `fs.watch` (post-Phase-4.8) is still racy under load. Move to Unix domain
   socket or in-process Claude Agent SDK calls (already a dependency at
   `package.json:13`, unused). Eliminates tmux, the watcher, and
   dramatically improves latency.
2. **First-class multi-user mode** — currently `userId='user'` hardcoded in
   `voice-agent.ts:802`; many scripts assume single owner.
3. **Skills as a runtime, not symlinks** — Phase 4.9 made the symlink
   approach load-bearing for the install flow (`LaunchAgentInstaller`
   runs `skills/install.sh`). Replace with versioned, signature-checked
   skill loader and registry; symlinks into `~/.claude/skills/` are
   fragile across .app moves and Anthropic-side skills-API changes.
4. **Replace tmux + Claude CLI** with `claude-agent-sdk` calls. Removes 4
   external dependencies AND the bypass-permissions-warning auto-accept
   hack from Phase 4.9.
5. **Stop running with `--dangerously-skip-permissions`** (`startup.sh:351`).
   Replace with hook-based approval flows + menu-bar consent prompts.
6. **Bridge python3 helpers through the .app for TCC** — the launchd-
   spawned python3 needs its own Screen Recording (and System Audio
   Recording) grants, separate from the .app's. Phase 4.9 papers over
   this by triggering python3 to register itself, but the right fix is
   to have the .app's Swift process do screen capture and expose it via
   XPC/HTTP, so only one TCC grant is ever needed.
7. **Test infrastructure** — current `tests/` is thin. Need integration tests
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
| Phase 4-bug installer hardening [DONE] | Phase 4.10 Track 1 — production deploy (Vercel + DNS + prod Neon/Clerk/Stripe; Tigris deferred) [PENDING] | Phase 4.10 Track 4 — onboarding/error/session emission [DONE] |
| Phase 4-core-agent claude wrapper [DONE] | Phase 4.11 admin panel [DONE — needs migration applied + admin flag set] | Per-skill `skill.run` metadata emission [PENDING — deferred] |
| Phase 4.8 bundled runtime + WKWebView + Claude Code installer + stepper [DONE] | Server-side rate sheet for `provider_cost_cents` [PENDING] | — |
| Phase 4.9 fresh-Mac install fixes [DONE] | Phone relay [PENDING — paid tier] | — |
| Phase 4.10 Track 2 — Dev ID cert + Sparkle keys + `apiBase` baked-in + tagged release [PENDING] | | |
| Phase 4.10 Track 3 — fresh-Mac DMG validation [PENDING — gated on Tracks 1+2] | | |
| Internal alpha [PENDING — gated on Track 3 success] | | |

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
