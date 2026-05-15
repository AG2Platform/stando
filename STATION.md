# Superpower Station — Design

The Superpower Station is Sutando's release-grade marketplace: one
catalog for **skills** (local compute, one-time install) and **cloud
tools** (remote compute, usage-based), unified under an agentic shopping
UX and brokered through a cloud MCP gateway.

This document is the source of truth for the design. PRODUCT.md tracks
strategy + wave status; STATION.md tracks what we're actually building
and where it lives in code.

## Status (2026-05-15)

Phases 1 → 5 landed; Phase 5.5 cleaned up 13 audit-surfaced bugs
(blocker: voice-agent now scans cloud-skills install dir; cost-cents
unit fix in MCP gateway; agentic cache version derived from content
hash; sign-out cleans the `~/.claude.json` entry; cloud-skill-sync
skips kind=cloud_tool silently; per-slug install lock; schema-driven
arg coercion in /try; honest disclosure of the /try throttle; etc.).
Wave A of Phase 6 promoted two of the three stub cloud tools to real
backends: **deep-research** = Tavily web search + Gemini synthesis;
**hosted-rag** = pgvector + Gemini embeddings (migration 0014). The
third stub (cloud-delegate) was dropped from the final 16 and is
deprecated in the catalog (migration 0015).

**Same-day visual refresh (2026-05-15 PM):** `/superpower` rebuilt
with an app-store layout (featured hero + mixed-kind rails:
Trending / Just landed / Sutando picks; unified Browse with kind
tab + category chips; all 16 items always visible). New
`/superpower/installed` for local visibility (built-in capabilities
+ installed skills + activated cloud tools, with uninstall). New
`/superpower/publish` page with multipart skill upload + cloud-tool
registration — replaces the legacy `/skills/submit` URL-paste form.
Wallet pill + "My collection" link added to the Station header.
FREE tier chip hidden everywhere (was confusable with "free to
install"). Concierge LLM ranking kept; copy scrubbed of internal
Phase 5/6 references. `cloud-skill-sync` poll interval dropped
from 600s → 60s so dashboard installs reach the user's Mac inside
a minute. Cloud-tool vendor swaps: `image-bg-remove` now on
fal.ai (sync, ~$0.001/call, was Replicate); `pdf-extract-tables`
now on Gemini 3 Flash multimodal (no extra vendor, ~$0.0005/page,
was LlamaParse).

| Phase | Scope | Status |
|---|---|---|
| 1 — Schema + dashboard nav | Add `kind / pricing_model / mcp_*` columns to `skills`; add `cloud_tool_sessions`; migrate 3 stub cloud tools; promote Station to a primary nav row + dashboard home strip; placeholder `/superpower` Discover page | done |
| 2 — Discover/detail page redesign | Concierge chat hero + functional keyword ranking; agentic-feel cards with "Sutando says:" copy; redesigned `/superpower/[slug]` with Intent Preview, kind-aware Install/Activate button, smart-review summary, author analytics | done |
| 3 — Built-in `superpower-station` skill + publishing APIs | `/api/superpower/skills/upload` (multipart + Tigris + server-side SHA-256), `/api/superpower/cloud-tools/register`, `/api/superpower/cloud-tools/{id}/package`, `/api/superpower/submissions`, resubmit route. Desktop `skills/superpower-station/` with 8 voice-callable tools. Install routes now resolve `tigris://` bundles via short-lived presigned GETs. | done |
| 4 — MCP gateway | `POST /api/mcp/v1` Streamable HTTP MCP server (`lib/mcp/protocol.ts` + handler). Per-user dynamic `tools/list` driven by `skill_installs` JOIN `skills WHERE kind='cloud_tool'`, with cached `mcp_introspect_cache`. Pre-flight `checkAndConsume` + per-call wallet debit at `unit_price_credits`. ON CONFLICT-safe `cloud_tool_sessions` upsert + `usage_events` audit. 3 internal MCP upstreams shipped (`/api/internal/mcp/{cloud-delegate,cloud-research,cloud-recall}`) sharing `lib/mcp/internal-server.ts`; `internal:<slug>` URL scheme resolves to local routes in both dev + prod. Desktop `src/register-station-mcp.py` wires `~/.claude.json` MCP entry from `cloud-auth.json` on sign-in (Swift) + every startup (bash). | done |
| 5 — Agentic features | `lib/llm/gemini.ts` thin wrapper over `gemini-3-flash-preview` (text + JSON-schema modes). `lib/superpower/agentic.ts` holds shared `recommendForIntent()` + `summarizeReviews()` with 1h in-process caches. Routes: `POST /api/superpower/recommend` (used by desktop proactive loop), `GET /api/superpower/preview/[slug]` (LLM-generates sample invocations on first call + caches into `skills.preview_invocations`), `POST /api/superpower/items/[slug]/try` (one sandboxed cloud-tool call per user-slug per 7 days against marketing budget; skills return cached previews). `/superpower` page now ranks via Gemini server-side with keyword fallback; `/superpower/[slug]` Try button is live + review summary is LLM-synthesized. Proactive-loop hook deferred to Phase 6. | done |
| 5.5 — Audit fixes | 13 bugs from the Phase 5 audit: voice-agent skill-loader blocker, costCents conflated with credits, agentic cache version (items.length → content hash), station_find ↔ Gemini recommend wiring, sign-out MCP cleanup, cloud-skill-sync kind branching, install/sync race mutex, mcp_introspect_cache invalidation on package upload, re-package status flip, /try arg coercion via inputSchema, preview schema strictness, honest disclosure of the 7-day /try throttle, cap-group wildcard for `cloud.*`. MCP gateway now refunds on upstream errors. | done |
| 6 Wave A — Promote stubs | `cloud-research` → real Tavily search + Gemini synthesis (`lib/llm/web-search.ts`); `cloud-recall` → real pgvector + Gemini embeddings (`lib/llm/embed.ts`, `lib/rag/storage.ts`, migration 0014); `cloud-delegate` deprecated (migration 0015). New `POST /api/superpower/rag/upload` endpoint accepts chunked text into per-user corpora. | done |
| 6 Wave B — Daily-pull skills | 4 skills covering morning-briefing-pro, email-triage, calendar-prep (rescoped — no LinkedIn), screenshot-explain (NEW killer demo). Mix of inline tools (screenshot-explain) and delegated-to-core (other three). | done |
| 6 Wave C — Integration skills | 4 skills covering code-reviewer, linear-or-github-triage, commute-and-weather (NEW), receipt-to-expense (NEW). All delegated-to-core; each wires a new external integration (`gh`, Linear API, Open-Meteo, macOS Live Text). | done |
| 6 Wave D — Lightweight cloud tools | 4 MCP-backed cloud tools: text-translate-quality (DeepL), scrape-and-extract (Jina Reader + Gemini), youtube-transcript (player-response scrape, no API key), image-bg-remove (fal.ai rembg). | done |
| 6 Wave E — PDF cloud tools | 2 MCP-backed cloud tools: pdf-extract-tables (Gemini multimodal) and pdf-fill-and-sign (self-hosted pdf-lib + Tigris). pdf-lib added to package.json — operator: `npm install` before deploying. | done |

## Mental model

Three primitives:

| | **Skill** | **Cloud Tool** |
|---|---|---|
| Compute | Local (user's Mac) | Remote (anywhere — our infra, hosted services, an author's laptop via ngrok) |
| Pricing | One-time credits at install; re-charged on major version | Per-call OR per-unit credits (`unit_label`: call / 1k_tokens / second) |
| Bundle | Tarball of anything: scripts, datasets, repos, templates, libraries | Optional small client package (icons, prompts, config) |
| Required format | `SKILL.md` (Anthropic standard) + optional `manifest.json` for inline-tool hooks | **MCP server** at the registered endpoint |
| Invocation | Loaded by Sutando Core (Claude Code) from the local filesystem | Called via our cloud's MCP gateway, which proxies to the upstream MCP server |
| Vetting | Admin review of submission | Admin review of registration + first-call audit + ongoing rate-limit |

The **MCP gateway** is the load-bearing idea. Sutando Core has ONE MCP
server entry in its `claude` CLI config pointing at
`https://sutando.ag2.ai/mcp/v1` (Streamable HTTP transport). The gateway
announces all of that user's installed cloud tools as MCP tools,
namespaced by slug. Every `tool/call`:

1. Auth via the user's Sutando Bearer token
2. Pre-flight `checkAndConsume(userId, 'cloud_tool.<slug>', units)`
3. Open or reuse session to the upstream `mcp_endpoint_url`
4. Forward with stored auth (decrypted from `mcp_auth_header`)
5. Stream response back to Core
6. Settle wallet + write `usage_events` + audit row

This is the standard "three gates" pattern — we're the MCP gateway
sitting between agents (Claude Code on the user's Mac) and tools
(anywhere on the internet). Cloud tools never see Sutando users, never
see Sutando billing, never see Claude Code. They get a clean MCP call
from our gateway with whatever auth header we send.

## Schema additions

Reuse `skills` as the unified catalog. Migration 0012:

```sql
ALTER TABLE skills
  ADD COLUMN kind varchar(16) NOT NULL DEFAULT 'skill',
    -- 'skill' | 'cloud_tool'
  ADD COLUMN pricing_model varchar(16) NOT NULL DEFAULT 'one_time',
    -- 'one_time' (skill install) | 'per_call' | 'per_unit'
  ADD COLUMN unit_price_credits numeric(10,3),
    -- for cloud tools: credits per call or per unit
  ADD COLUMN unit_label varchar(32),
    -- 'call' | '1k_tokens' | 'second' | 'image' | …
  ADD COLUMN mcp_endpoint_url text,
    -- upstream MCP server URL (never exposed to clients)
  ADD COLUMN mcp_auth_header text,
    -- encrypted credential we send to upstream
  ADD COLUMN mcp_introspect_cache jsonb,
    -- cached tools/list from upstream
  ADD COLUMN categories text[] NOT NULL DEFAULT '{}',
  ADD COLUMN preview_invocations jsonb;
    -- [{input, expected_output}] for the "Try" button

CREATE TABLE cloud_tool_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES users(id) ON DELETE cascade,
  tool_id uuid REFERENCES skills(id) ON DELETE cascade,
  started_at timestamptz NOT NULL DEFAULT now(),
  last_call_at timestamptz NOT NULL DEFAULT now(),
  total_calls integer NOT NULL DEFAULT 0,
  total_credits_debited numeric(10,3) NOT NULL DEFAULT 0
);

CREATE INDEX cloud_tool_sessions_user_idx ON cloud_tool_sessions (user_id, last_call_at);
CREATE INDEX cloud_tool_sessions_tool_idx ON cloud_tool_sessions (tool_id, last_call_at);
```

`skill_installs` doubles as the "activated cloud tools" log — same shape
works (one row per (user, tool, version), append-only).

The 3 stub cloud tools (`cloud-delegate / cloud-research / cloud-recall`)
flip to `kind='cloud_tool'`, `pricing_model='per_call'`,
`unit_label='call'`, with `unit_price_credits = 50 / 100 / 5` from the
existing seed `manifest.cost_credits_per_call`.

## UX

### Dashboard

Today: a tiny **Skills** button in the upper-right of `/dashboard`.

After: Superpower Station is a **primary surface**.

- Sidebar / topnav adds "Superpower Station" as a first-class entry
- Dashboard home gets a **Station strip** between the stats cards and
  "This period" — featured/recommended items as horizontal cards with a
  clear "Explore the Station" CTA
- Old "Skills" button is removed (the strip + nav replace it)

### `/superpower` — Discover

App-store layout: header → concierge → featured hero → mixed-kind
rails → unified browse with kind tab + category chips. Recommended
and Trending are lenses *over* the full Skill + Cloud-tool catalog,
not peers of those primitives — cards from both kinds appear in any
rail.

```
┌──────────────────────────────────────────────┐
│  Superpower Station   [wallet] [Collection]  │
│                                              │
│  ┌──────────────────────────────────────┐    │
│  │  What do you want Sutando to do? [→] │    │
│  └──────────────────────────────────────┘    │
│                                              │
│  ╔══════════════════════════════════════╗    │
│  ║  Featured                            ║    │
│  ║  <one big tile, top-trending pick>   ║    │
│  ╚══════════════════════════════════════╝    │
│                                              │
│  Trending         (horizontal-scroll rail)   │
│  ┌────┐ ┌────┐ ┌────┐ ┌────┐ ▸             │
│                                              │
│  Just landed     (horizontal-scroll rail)    │
│  ┌────┐ ┌────┐ ┌────┐ ┌────┐ ▸             │
│                                              │
│  Sutando picks   (horizontal-scroll rail)    │
│  ┌────┐ ┌────┐ ┌────┐ ┌────┐ ▸             │
│                                              │
│  Browse the catalog                          │
│  [All 16] [Skills 8] [Cloud tools 8]         │
│  [daily 8] [voice 7] [developer 4] …         │
│                                              │
│  ┌────┐ ┌────┐ ┌────┐ ┌────┐                │
│  ┌────┐ ┌────┐ ┌────┐ ┌────┐                │
│  ...                                         │
└──────────────────────────────────────────────┘
```

Card content matches the agent-driven theme:

- Title, kind chip (Skill / Cloud tool), tier badge (only when ≠ free)
- One-line "Sutando says: …" reasoning (generated by `/recommend`)
- Price label + star rating or install count

### `/superpower/[slug]` — Detail

Components:

- Hero: name, author, version, kind chip, price
- **Intent Preview** — bullets auto-derived from `SKILL.md` description
  + tools/MCP introspection: "If you install this, Sutando will be able
  to: …"
- **Try** button (cloud tools only) — runs one sandboxed call against
  `preview_invocations` (one per user per tool per week, budgeted out
  of marketing pool)
- Reviews — default sort = recency × similarity-to-you; agent-summary
  paragraph at the top synthesizing all reviews
- Author analytics (if viewer is author) — installs, revenue, rating,
  24h errors

### `/superpower/publish` — Submit (paid tier only)

Tabs:

- Submit a skill — upload tarball (multipart), fill metadata, choose
  price model, submit for review
- Register a cloud tool — paste MCP endpoint URL, choose auth scheme,
  set pricing model + unit price + unit label, optionally upload a
  client package, submit for review

### `/superpower/installed` — My collection

- **Built-in capabilities** strip at the top: voice agent, phone,
  screen capture, macOS tools, browser, channels, memory, proactive
  loop. Always on, no install needed; gives the user a complete
  picture of what Sutando can already do.
- **Installed skills** — items pulled from the cloud catalog and
  extracted to `~/Library/Application Support/Sutando/cloud-skills/`
  on the user's Mac. Per-row uninstall.
- **Activated cloud tools** — items reachable through the MCP
  gateway. Per-row uninstall.
- Footer explains the 3-stage propagation (dashboard click → bundle
  sync ~1 min → voice-agent restart) so the user isn't left wondering
  why a new skill doesn't show up immediately.

Submissions live separately on `/superpower/publish` (the page also
hosts the submit forms — one tab for skills, one for cloud tools).

### Proactive surfacing

The proactive-loop hook posts Station cards into the dashboard feed and
(if voice-active) speaks: "I noticed you triage email manually a few
times today; want me to install `email-triage`?"

## Built-in skill: `superpower-station`

Replaces / extends `skill-installer`. Voice-callable.

| Tool | Free | Paid |
|---|---|---|
| `find(query)` — semantic search | yes | yes |
| `install(slug)` — skill or cloud tool, same verb | yes | yes |
| `review(slug, rating, body)` | yes | yes |
| `list_installed()` / `remove(slug)` | yes | yes |
| `package_skill(local_path) -> tarball` | no | yes |
| `publish_skill(tarball, metadata)` | no | yes |
| `register_cloud_tool(metadata, mcp_url, auth, pricing)` | no | yes |
| `upload_cloud_tool_package(slug, tarball)` | no | yes |

Voice example: *"Sutando, take my local skill 'recipe-companion',
package it, and submit it for review at 50 credits."*

## Cloud routes

```
POST /api/superpower/skills/upload          (multipart; paid)
POST /api/superpower/cloud-tools/register   (paid)
POST /api/superpower/cloud-tools/{id}/package  (optional; paid)
GET  /api/superpower/submissions
POST /api/superpower/submissions/{id}/resubmit

POST /api/superpower/recommend              (intent → ranked candidates)
GET  /api/superpower/preview/{slug}
POST /api/superpower/items/{slug}/try

POST /api/mcp/v1                             (Streamable HTTP MCP server)
```

## Free-vs-paid

| | Free | Plus / Pro / Max |
|---|---|---|
| Discover, install, review | yes | yes |
| Pay for items via wallet credits | yes (with $5/mo bootstrap) | yes |
| Publish skill / register cloud tool | **no** | yes (review-gated) |
| Earn revenue from publishes | **no** | yes (80 / 20 author / Sutando) |

## Bootstrap content

The original 24-item list was reviewed against Anthropic Skills, the
ChatGPT GPT Store, Raycast Store, Apple Shortcuts, Zapier templates,
and the awesome-MCP-servers registry. **Final catalog: 16 items**
(8 skills + 8 cloud tools). Dropped items either lacked daily-use
pull (interview-coach, travel-planner, daily-journal, recipe-
companion, flashcard-maker, voice-clone-ephemeral, image-upscale-4k)
or are no longer viable (linkedin-profile-lookup — Proxycurl shut
down July 2025 after LinkedIn lawsuit). `cloud-delegate` was dropped
in favor of routing delegation through Sutando's core agent
directly. The four NEW items leverage Sutando's unique surfaces
(screen-capture, voice, calendar integration) for daily-pull value
no web app can match.

### Skills (one-time install, local compute) — 8

| # | Slug | Why | Status |
|---|---|---|---|
| 1 | `morning-briefing-pro` | Richer briefing + voice options; daily-pull morning ritual | **done (Wave B)** |
| 2 | `email-triage` | Gmail urgency triage + draft replies; #1 Zapier category | **done (Wave B)** |
| 3 | `calendar-prep` | Last-thread + meeting-notes + agenda draft (LinkedIn step dropped) | **done (Wave B)** |
| 4 | `code-reviewer` | PR URL → senior review via `gh` + Claude; dev-cohort daily pull | **done (Wave C)** |
| 5 | **`screenshot-explain`** (NEW) | Local region screenshot + Gemini vision → explain. Sutando's killer demo — one keystroke beats any web GPT | **done (Wave B)** |
| 6 | **`commute-and-weather`** (NEW) | Calendar × weather × user-rule. Morning-routine reinforcer | **done (Wave C)** |
| 7 | **`receipt-to-expense`** (NEW) | Photo → OCR (Live Text) → CSV/Sheets. Photo input is the unique unlock | **done (Wave C)** |
| 8 | **`linear-or-github-triage`** (NEW) | "What changed in my issues today" + draft updates. Standup prep | **done (Wave C)** |

### Cloud tools (usage-based, MCP) — 8

| # | Slug | Wholesale cost | Price | Status |
|---|---|---|---|---|
| 1 | `deep-research` | ~$0.02 (Tavily + Gemini synth) | 100 cr/call | **done (Wave A)** |
| 2 | `hosted-rag` | ~$0.00003 (embed + pgvector) | 5 cr/call | **done (Wave A)** |
| 3 | `pdf-extract-tables` | ~$0.0005/page (Gemini 3 Flash) | 5 cr/call | **done (Wave E)** |
| 4 | `youtube-transcript` | ~$0.05/20-min video (Gemini 3 Flash Preview) | 5 cr/call | **done (Wave D)** |
| 5 | `text-translate-quality` | ~$0.005/1k chars (DeepL) | 1 cr/call | **done (Wave D)** |
| 6 | `image-bg-remove` | ~$0.001 (fal.ai rembg) | 2 cr/call | **done (Wave D)** |
| 7 | **`pdf-fill-and-sign`** (NEW) | $0 self-hosted (pdf-lib + Tigris) | 5 cr/call | **done (Wave E)** |
| 8 | **`scrape-and-extract`** (NEW) | ~free (Jina Reader) | 2 cr/call | **done (Wave D)** |

### Dropped from the original 24

Skills: `expense-tracker` (Reminders.app covers it; replaced with
`receipt-to-expense`), `interview-coach`, `paper-summary`,
`meeting-recorder`, `recipe-companion`, `travel-planner`,
`daily-journal`, `flashcard-maker` — all low daily-use pull or
cold-start every install.

Cloud tools: `delegate-to-specialist` (deprecated in migration 0015;
delegation handled by Sutando's core agent directly),
`web-screenshot-pro` (overlaps with the new `screenshot-explain`
local skill + existing browser-tools), `voice-clone-ephemeral`
(niche use case, ~$5+ wholesale per clone), `code-search`
(Sourcegraph heavy; `gh code-search` + grep cover the dev cohort),
`image-upscale-4k` (novelty / one-time), `linkedin-profile-lookup`
(**dead** — Proxycurl shut down July 2025 after LinkedIn lawsuit;
no legally clean alternative).

## Open questions

1. **MCP tool namespacing**: do we expose cloud tool slugs as-is, or
   prefix (`station.<slug>`)? Prefix avoids collisions with built-in
   Claude Code tools but is uglier. Default: prefix.
2. **Try-it budget cap**: per-user-per-tool-per-week is the proposed
   throttle, but the marketing pool could run dry if a tool goes
   viral. Daily cap on the global pool with graceful fallback?
3. **Bundle signing**: today authors compute SHA-256 themselves. For
   release-grade, the upload pipeline should re-compute on receipt and
   stamp the row. Apple Developer ID signing of skill tarballs (per
   PRODUCT.md §2 — currently `partial`) stays deferred to post-beta.
4. **Cloud tool denial / takedown**: if a registered MCP endpoint goes
   bad (returns errors, leaks data, etc.), admin can set
   `status='deprecated'`. Should we also auto-deprecate on a sustained
   error-rate threshold? Probably yes once we have the audit log
   running.

## Cross-references

- Strategy + tier shape: [`PRODUCT.md`](PRODUCT.md)
- Packaging: [`DISTRIBUTION.md`](DISTRIBUTION.md)
- Anthropic skill format: <https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview>
- Official MCP registry: <https://registry.modelcontextprotocol.io/>
