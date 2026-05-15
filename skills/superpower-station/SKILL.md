---
name: superpower-station
description: Browse, install, publish, and review skills + cloud tools from the Sutando Superpower Station. Use when the user wants to find/install a skill, activate a cloud tool, rate something they've installed, or publish their own skill / register a cloud tool to the catalog.
---

# Superpower Station

Voice-callable tools for the Sutando Superpower Station — one catalog
for **skills** (local compute) and **cloud tools** (remote compute via
our MCP gateway).

## Tools

| Tool | Who | Purpose |
|---|---|---|
| `station_find(query)` | anyone | Search the catalog by name / description |
| `station_install(slug)` | anyone | Install a skill OR activate a cloud tool |
| `station_review(slug, rating, body?)` | anyone | Post a 1–5 rating |
| `station_my_collection(scope?)` | anyone | List installed items + your own submissions |
| `station_package_skill(local_path)` | paid only | Validate + tarball a local skill directory |
| `station_publish_skill(local_path \| tarball_path, metadata?)` | paid only | Upload a skill to the catalog (auto-packages if `local_path` given) |
| `station_register_cloud_tool(...)` | paid only | Register an upstream MCP server as a cloud tool |
| `station_resubmit_submission(id)` | paid only | Re-trigger admin review after edits |

## Behavior

- Installs land under `$SUTANDO_HOME/cloud-skills/` (or
  `~/Library/Application Support/Sutando/cloud-skills/` when
  `SUTANDO_HOME` is unset). Cloud tools don't install a tarball unless
  they ship an optional client package.
- After install of a skill, voice-agent must be restarted to pick up
  new inline tools — mention this to the user. Cloud-tool tools come
  online on next MCP refresh (Phase 4).
- Wallet debits for priced skills happen server-side via the same
  `credits_ledger` path as over-cap usage. If the wallet can't cover
  the install, the cloud route returns 402.
- Publishing is paid-tier only (Plus / Pro / Max). Free users see a
  clean 403 response with an upgrade prompt.

## Publishing a local skill

To publish a directory at `~/my-skill`:

1. The directory needs `SKILL.md` with YAML frontmatter (`name`,
   `description`) — Anthropic format. Optional `manifest.json` for
   `version` + `tierRequired` + `priceCredits` + `categories`.
2. `station_publish_skill({local_path: "~/my-skill"})` packages the
   directory (excludes `.git`, `node_modules`, `.DS_Store`), uploads to
   our Tigris bucket, and submits for admin review.
3. Admin reviews from `/admin/skills` and approves/denies. Author
   receives a Loops email (`LOOPS_TRANSACTIONAL_SKILL_DECISION`).
4. Once approved, the row flips to `status='published'` and lands in
   the catalog. Re-submitting your own slug bumps the version + flips
   back to review.

## Registering a cloud tool

Cloud tools are MCP servers we proxy through our gateway (Phase 4).

```
station_register_cloud_tool({
  slug: "my-cloud-tool",
  name: "My Cloud Tool",
  description: "...",
  version: "0.1.0",
  mcp_endpoint_url: "https://my-host.example.com/mcp",
  mcp_auth_header: "Bearer XXX",       // sent to upstream as Authorization
  pricing_model: "per_call",            // or "per_unit"
  unit_price_credits: 5,                // credits per call/unit
  unit_label: "call",                   // or "1k_tokens" / "second" / ...
  tier_required: "free",
})
```

Endpoint must be HTTPS. Auth header is stored as-is in beta (encrypted
at rest in post-beta hardening).

## Cloud routes used

- `GET /api/skills/catalog`
- `GET /api/skills/{slug}`
- `POST /api/skills/{id}/install`
- `POST /api/skills/{id}/review`
- `GET /api/skills/installed`
- `POST /api/superpower/skills/upload`       (multipart)
- `POST /api/superpower/cloud-tools/register`
- `GET /api/superpower/submissions`
- `POST /api/superpower/submissions/{id}/resubmit`

## Failure modes

- 401 → user signed out; prompt to sign in via menu bar
- 402 → insufficient credits; prompt to top up at `/dashboard`
- 403 (install) → tier required is above current plan; prompt to upgrade
- 403 (publish) → free tier; prompt to upgrade to Plus or above
- 409 → slug owned by another author; pick a new slug
- bundle hash mismatch → abort, leave nothing on disk
