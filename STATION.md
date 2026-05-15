# Superpower Station — Design

The Superpower Station is Sutando's release-grade marketplace: one
catalog for **skills** (local compute, one-time install) and **cloud
tools** (remote compute, usage-based), unified under an agentic shopping
UX and brokered through a cloud MCP gateway.

This document is the source of truth for the design. PRODUCT.md tracks
strategy + wave status; STATION.md tracks what we're actually building
and where it lives in code.

## Status (2026-05-14)

Phases 1 → 5 landed. Discover concierge ranks via gemini-3-flash-preview,
detail pages render LLM-synthesized review summaries, the Try button
actually invokes cloud tools against a sandbox budget. Phase 6
(bootstrap content) is the last piece before the Station is content-
complete.

| Phase | Scope | Status |
|---|---|---|
| 1 — Schema + dashboard nav | Add `kind / pricing_model / mcp_*` columns to `skills`; add `cloud_tool_sessions`; migrate 3 stub cloud tools; promote Station to a primary nav row + dashboard home strip; placeholder `/superpower` Discover page | done |
| 2 — Discover/detail page redesign | Concierge chat hero + functional keyword ranking; agentic-feel cards with "Sutando says:" copy; redesigned `/superpower/[slug]` with Intent Preview, kind-aware Install/Activate button, smart-review summary, author analytics | done |
| 3 — Built-in `superpower-station` skill + publishing APIs | `/api/superpower/skills/upload` (multipart + Tigris + server-side SHA-256), `/api/superpower/cloud-tools/register`, `/api/superpower/cloud-tools/{id}/package`, `/api/superpower/submissions`, resubmit route. Desktop `skills/superpower-station/` with 8 voice-callable tools. Install routes now resolve `tigris://` bundles via short-lived presigned GETs. | done |
| 4 — MCP gateway | `POST /api/mcp/v1` Streamable HTTP MCP server (`lib/mcp/protocol.ts` + handler). Per-user dynamic `tools/list` driven by `skill_installs` JOIN `skills WHERE kind='cloud_tool'`, with cached `mcp_introspect_cache`. Pre-flight `checkAndConsume` + per-call wallet debit at `unit_price_credits`. ON CONFLICT-safe `cloud_tool_sessions` upsert + `usage_events` audit. 3 internal MCP upstreams shipped (`/api/internal/mcp/{cloud-delegate,cloud-research,cloud-recall}`) sharing `lib/mcp/internal-server.ts`; `internal:<slug>` URL scheme resolves to local routes in both dev + prod. Desktop `src/register-station-mcp.py` wires `~/.claude.json` MCP entry from `cloud-auth.json` on sign-in (Swift) + every startup (bash). | done |
| 5 — Agentic features | `lib/llm/gemini.ts` thin wrapper over `gemini-3-flash-preview` (text + JSON-schema modes). `lib/superpower/agentic.ts` holds shared `recommendForIntent()` + `summarizeReviews()` with 1h in-process caches. Routes: `POST /api/superpower/recommend` (used by desktop proactive loop), `GET /api/superpower/preview/[slug]` (LLM-generates sample invocations on first call + caches into `skills.preview_invocations`), `POST /api/superpower/items/[slug]/try` (one sandboxed cloud-tool call per user-slug per 7 days against marketing budget; skills return cached previews). `/superpower` page now ranks via Gemini server-side with keyword fallback; `/superpower/[slug]` Try button is live + review summary is LLM-synthesized. Proactive-loop hook deferred to Phase 6. | done |
| 6 — Bootstrap content | Build + publish 12 skills + 12 cloud tools | pending |

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

Concierge hero + curated grid below the fold.

```
┌────────────────────────────────────────┐
│  Superpower Station                    │
│                                        │
│  ┌──────────────────────────────────┐  │
│  │  What do you want Sutando        │  │
│  │  to do?                    [→]  │  │
│  └──────────────────────────────────┘  │
│                                        │
│  Recommended for you                   │
│  ┌────┐ ┌────┐ ┌────┐ ┌────┐         │
│  │card│ │card│ │card│ │card│  ...    │
│  └────┘ └────┘ └────┘ └────┘         │
│                                        │
│  Trending this week                    │
│  ┌────┐ ┌────┐ ┌────┐ ┌────┐         │
│                                        │
│  Sutando picks                         │
│  ┌────┐ ┌────┐ ┌────┐ ┌────┐         │
└────────────────────────────────────────┘
```

Card content matches the agent-driven theme:

- Title, tier badge, kind chip (Skill / Cloud tool), price label
- One-line "Sutando says: …" reasoning (generated by `/recommend`)
- Star rating + install count

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

### `/superpower/mine` — My collection

- Installed skills + activated cloud tools (with remove)
- Submissions (status: review / published / denied / deprecated, with
  edit + resubmit)
- Per-item usage (call count + credits spent + ratings given)

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

### Skills (one-time install)

1. `morning-briefing-pro` — richer briefing + voice options
2. `calendar-prep` — auto-pull attendee LinkedIn + last thread + draft talking points
3. `email-triage` — Gmail urgency triage + draft replies
4. `expense-tracker` — voice "spent $X" → CSV / Sheets
5. `interview-coach` — mock interview + scoring
6. `paper-summary` — arXiv URL → summary + key figures
7. `meeting-recorder` — record + transcribe + Notion publish
8. `code-reviewer` — PR URL → senior review
9. `recipe-companion` — voice-guided cooking
10. `travel-planner` — voice "plan 4 days in Lisbon"
11. `daily-journal` — evening reflection + weekly synthesis
12. `flashcard-maker` — notes → Anki decks

### Cloud tools (usage-based, MCP)

1. `deep-research` (Phase 4 — promote existing stub)
2. `delegate-to-specialist` (Phase 4 — promote existing stub)
3. `hosted-rag` (Phase 4 — promote existing stub)
4. `web-screenshot-pro` (Cloudflare Browser)
5. `pdf-extract-tables` (Reducto / LlamaParse-class)
6. `voice-clone-ephemeral` (Cartesia)
7. `youtube-transcript`
8. `code-search` (Sourcegraph-style)
9. `image-upscale-4k`
10. `image-bg-remove`
11. `text-translate-quality` (DeepL-class)
12. `linkedin-profile-lookup` (Proxycurl)

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
