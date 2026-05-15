---
name: linear-or-github-triage
description: "Daily issue triage across Linear + GitHub: what's open, what changed, blockers, draft a standup update. Voice-callable: 'what changed in my issues today', 'draft my standup'."
user-invocable: true
---

# Linear / GitHub Triage

Daily issue-tracker triage for the dev cohort. Pulls open issues + recent activity from Linear and/or GitHub (whichever the user has configured), surfaces what changed, blockers, and drafts a standup update. Tracks the technical user's daily standup / EOD-update flow.

## Triggers

- "What changed in my issues today"
- "Draft my standup"
- "What's on my plate"
- "Any new tickets"
- "Standup update"

## Inputs

- `since` (optional): "today" (default), "yesterday", "this week", or an ISO timestamp.
- `target` (optional): "linear", "github", or "both" (default).
- `draft` (optional, bool): if true, format as a standup update (yesterday/today/blockers).

## Steps

### 1. Detect which integrations are configured

```bash
# Linear: needs LINEAR_API_KEY in env
test -n "$LINEAR_API_KEY" && echo "linear-ok"

# GitHub: gh authenticated?
gh auth status 2>&1 | grep -q "Logged in" && echo "github-ok"
```

If neither is configured, tell the user how to set them up:
- Linear: `export LINEAR_API_KEY=lin_api_...` (generate at linear.app/<workspace>/settings/api)
- GitHub: `gh auth login`

### 2. Linear pull (if configured)

Query Linear GraphQL for issues assigned to the user. Endpoint: `https://api.linear.app/graphql`. Auth: `Authorization: $LINEAR_API_KEY` (raw, no `Bearer`).

```graphql
query MyIssues($since: DateTimeOrDuration!) {
  viewer {
    assignedIssues(filter: { updatedAt: { gte: $since } }) {
      nodes {
        identifier
        title
        state { name type }
        priority
        url
        updatedAt
        comments(last: 3) { nodes { body createdAt user { name } } }
      }
    }
  }
}
```

For each issue, capture: identifier (ENG-123), title, state, priority, recent comments.

### 3. GitHub pull (if configured)

```bash
# Issues assigned to me, updated in the window:
gh search issues --assignee "@me" --updated "${SINCE_ISO}..*" --state open --json number,title,state,repository,url,updatedAt

# PRs I authored that have new activity:
gh search prs --author "@me" --updated "${SINCE_ISO}..*" --json number,title,state,reviewDecision,repository,url,updatedAt

# PRs requested for my review:
gh search prs --review-requested "@me" --state open --json number,title,author,repository,url
```

### 4. Triage the combined list

Classify each item:
- **Action needed today**: status changed to "Blocked", new comment from PM/peer, PR review requested, "needs your input" comments.
- **In progress**: assigned, "In Progress" state, has recent activity.
- **Waiting on others**: "In Review", or you're waiting for a reply.
- **Done since last check**: closed / merged in the window — surface as wins.

Skip noise: automated dependabot-style PRs unless explicitly tagged for you, status-bot pings, "stale" labels.

### 5a. Output mode: triage summary

```
Yesterday's wins (closed):
- ENG-101: <title> (linear)
- repo#234: <title> (github)

Action needed today:
- ENG-145 (Urgent): <title> — <why>
- repo#290: PR review for @sarah requested

In progress:
- ENG-130: <title> — last comment: "<excerpt>"

Waiting on others:
- ENG-140: <title> — waiting on @bob since 3d
```

Speak the "action needed today" + "wins" sections aloud, save full triage to `notes/triage-<date>.md`.

### 5b. Output mode: standup update

If `draft: true`:

```markdown
## Standup — <date>

**Yesterday:**
- <closed/merged items as one-liners>
- <progress on in-progress items>

**Today:**
- <plan for action-needed-today items>

**Blockers:**
- <waiting-on-others items, or "None">
```

Save to `notes/standup-<date>.md`. Copy to clipboard via `pbcopy` so the user can paste into Slack:
```bash
pbcopy < notes/standup-<date>.md
```
Confirm aloud: "Standup drafted, copied to clipboard."

## Voice routing

`documented_for_core: true`. Delegated to core.

## Env

- `LINEAR_API_KEY` — Personal API key. Generate at linear.app/<workspace>/settings/api.
- `gh` CLI authenticated for GitHub.

If neither env var is present, the skill returns a one-line "Set up Linear or GitHub first — see skill docs" rather than failing silently.
