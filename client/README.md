# `@sutando/client`

Sutando's React frontend. Hosts four pages — **conversation**, **core-cli**, **dashboard**, **settings** — that map 1:1 to the panes in `src/Sutando/UnifiedMainWindow.swift`.

`GET /` serves this React bundle. The original inline HTML survives at `GET /legacy` as a one-release escape hatch (still served via `src/web-server.ts` + `src/web-client-html.ts`); both will be removed in PR-C step 6 once the new tree has burned in. Bookmarks pointing at `/v2` continue to work — it's an alias for `/`.

## Architecture

Follows `CLAUDE.md § Frontend Conventions`:

| Layer | Purpose | Size budget |
|-------|---------|-------------|
| `pages/<page>/` | Thin orchestration; one per route | n/a |
| `components/atoms/` | Pure presentational | < 70 lines |
| `components/molecules/` | Composed of atoms | 70–150 lines |
| `components/organisms/` | Feature-complete sections | > 150 lines |
| `contexts/` | React Context providers | – |
| `hooks/` | Data fetching + business logic | – |
| `utils/` | Pure functions | – |
| `const-values/` | Copy + static config | – |
| `lib/` | Infrastructure (`config`, `api`, `sse`) | – |

**Rules:**
- Components render UI only. No `fetch` in components — hooks own that.
- No hardcoded strings. Copy lives in `const-values/`.
- One file ≤ ~150 lines. Split before it grows past that.
- `===` not `==`. `const` over `let`. Early returns over nesting.

## Routing

No `react-router` yet. The active page is the `?page=` query param, read by `useCurrentRoute()`. Valid ids: `conversation`, `core-cli`, `dashboard`, `settings`. The Sutando macOS app's `UnifiedMainWindow.swift` can load each pane by setting `?page=<id>` on the bundle URL.

## Server-agnostic config

`src/lib/config.ts` resolves the WebSocket URL + API origin at runtime by:

1. `?ws=` / `?api=` query string (highest priority).
2. `window.__SUTANDO_CONFIG__` (injected by the host shell).
3. `window.location.host` (default — works for desktop WKWebView, remote browser over Tailscale, and the future mobile thin-client without rebuilding).

## Build

```bash
pnpm install            # only on the first run; runs at repo root, not in client/
pnpm --filter @sutando/client build  # writes client/dist/
```

`src/web-server.ts` serves `client/dist/index.html` + assets at `/` and `/v2`. When the bundle isn't built yet, both routes fall back to the legacy inline HTML so a fresh checkout still boots.

## Dev workflow

```bash
pnpm --filter @sutando/client dev    # vite dev server on http://localhost:5173
```

The dev server expects `voice-agent.ts` to be running so the conversation page can hit `/sse-status` etc. Pass `?api=http://localhost:8080` if the Vite dev server is on a different origin than the API.
