---
name: frontend-conventions
description: Stando frontend conventions for the React + TypeScript client in client/src. Covers component sizing (atoms/molecules/organisms), naming, directory layout, and placement rules. Use when creating, editing, refactoring, or reviewing any .tsx/.ts file under client/src — including pages, components, hooks, contexts, utils, const-values, or lib — or when the user asks where a new piece of frontend code should live.
---

# Frontend Conventions

Apply these rules to any code authored under `client/src/`. They are project standards for the Stando React + TypeScript client and should be enforced without prompting.

## Core Rules

- **Components render UI only** -- business logic lives in hooks or utilities
- **No fetch calls in components** -- data fetching belongs in hooks
- **No hardcoded strings** -- all copy and static values live in `const-values/`
- **File size limit**: ~150 lines per file
- **Prefer declarative patterns**: `map`/`filter`/`reduce` over imperative loops; no `while`, `do...while`, `++`/`--`
- **Immutable patterns**: never mutate arrays/objects directly; use spread or functional methods
- **No implicit coercion**: use `===` not `==`; use `const` over `let`
- **Early returns** over nested conditionals

## Naming Conventions

| What | Convention | Example |
|------|-----------|---------|
| Components | PascalCase | `StatsCard.tsx` |
| Component dirs | kebab-case | `stats-card/` |
| Hooks | camelCase with `use` prefix | `useAuth.ts` |
| Event handlers | `handle`/`on` prefix | `handleClick`, `onSubmit` |
| Boolean flags | `is`/`has`/`can` prefix | `isLoading`, `hasError` |

## Directory Structure

```
src/
  pages/            # Page-level view components (thin orchestration)
    conversation/
      ConversationPage.tsx
      index.ts
    core-cli/
      CoreCLIPage.tsx
      index.ts
    dashboard/
      DashboardPage.tsx
      index.ts
    settings/
      SettingsPage.tsx
      index.ts
  components/       # All UI components organized by size
    atoms/          # Small components (<100 lines, highly reusable)
    molecules/      # Medium components (70-150 lines)
    organisms/      # Large components (feature-complete sections >150 lines)
  contexts/         # React Context providers (auth, theme)
  hooks/            # Custom reusable React hooks (data fetching, business logic)
  utils/            # Pure utility functions
  const-values/     # Application constants and static content
  lib/              # Infrastructure (api client, etc.)
```

## Component Organization

**Pages** (in `pages/`)
- Thin orchestration layers that compose smaller components
- Each page has its own directory with:
  - Main component file (e.g., `HomeView.tsx`)
  - `index.ts` export file
- **NO `components/` subdirectories** - all components live in `/components/`
- Examples: `conversation/`, `core-cli/`, `dashboard/`, `settings/`

**Atoms** (< 70 lines)
- Pure presentational components
- Highly reusable across the app
- Minimal or no state
- Examples: avatars, icons, checkbox, button

**Molecules** (70-150 lines)
- Composed of multiple atoms
- Moderately complex UI patterns
- May have internal state
- Examples: cards, inputs, lists, dropdowns

**Organisms** (complex features)
- Complex, feature-complete components
- Often connected to data/state
- Not full pages, but substantial features
- Examples:

## Placement Rules

**When to use `pages/`:**
- Component represents a full page/route
- Component is the top-level view for a URL
- Component manages page-specific state and layout

**When to use `components/atoms/`:**
- Component is < 70 lines
- Component is highly reusable (even if page-specific now)
- Component is pure presentational

**When to use `components/molecules/`:**
- Component is 70-150 lines
- Component combines multiple atoms
- Component has moderate complexity

**When to use `components/organisms/`:**
- Component is >150 lines and complex
- Component is a substantial feature (like a wizard step)
- Component is feature-complete but not a full page

**File Structure:**
- Each component gets its own directory
- `ComponentName.tsx` (main file, TypeScript)
- `index.ts` (export-only: `export { default } from "./ComponentName"`)
- **NO subdirectories** - components are organized flat by size

## Workflow

When adding or editing frontend code:

1. **Locate by size, not by feature.** Decide if the new code is a page, atom, molecule, or organism using the line-count thresholds above. If a file grows past its bucket, split it or promote it.
2. **Extract logic before adding it to a component.** Any data fetching, derived state, or business rule belongs in a hook (`hooks/`) or pure utility (`utils/`). Components only render the result.
3. **Move strings to `const-values/`** before merging — no inline copy or magic numbers.
4. **Match the directory pattern exactly**: `kebab-case-dir/PascalCaseFile.tsx` plus a one-line `index.ts` re-export. No subdirectories inside a component dir.
5. **Refactor on touch.** If you edit a file that already violates these rules (e.g. >150 lines, fetch in component, uses `let` where `const` works), fix it as part of the change rather than perpetuating the pattern.
