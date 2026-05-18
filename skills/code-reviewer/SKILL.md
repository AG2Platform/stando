---
name: code-reviewer
description: "Senior-engineer code review of a GitHub PR. Voice-callable: 'review PR 1284', 'review my latest PR', 'review the user-auth PR'."
user-invocable: true
---

# Code Reviewer

Run a careful PR review using `gh` + the repo's conventions + Claude's reasoning. Built for the technical beta cohort that lives in GitHub.

## Triggers

- "Review PR <number>"
- "Review my latest PR"
- "Review the <topic> PR"
- "What's wrong with PR <number>"

## Inputs

- `pr_number` (optional): If specified, target that PR. Otherwise find the user's most recent open PR.
- `repo` (optional): Defaults to the current working directory's repo.
- `focus` (optional): "security", "tests", "performance", "naming", "all" (default).

## Steps

### 1. Resolve the PR

```bash
# Specific PR:
gh pr view PR_NUMBER --json title,body,url,baseRefName,headRefName,additions,deletions,changedFiles,author,reviewDecision

# Most recent of mine:
gh pr list --author "@me" --state open --limit 1 --json number,title,url
```

If the user said "my latest PR" but there's no open PR, fall back to the most recent `gh pr list --author "@me" --state all --limit 3` and ask which one.

### 2. Read the diff

```bash
gh pr diff PR_NUMBER
```

If the diff is > 50k characters, ask the user which files to focus on rather than reviewing blindly.

### 3. Read repo conventions

In priority order, pull whichever exist:
- `CLAUDE.md` (project instructions)
- `CONTRIBUTING.md`
- `.github/PULL_REQUEST_TEMPLATE.md`
- `README.md` (architecture section)

Match the project's voice in the review — terse for terse repos, more explanatory for newcomer-friendly ones.

### 4. Run the review checklist

Walk through these in order; cite specific lines from the diff for each concern.

**Logic & correctness**
- Edge cases not handled (empty input, null, max int, race, retries)
- Off-by-ones
- Error paths that swallow errors silently
- State mutations that aren't transactional when they should be

**Tests**
- Are there new tests? Do they cover the new logic?
- Are existing tests still meaningful, or have they been weakened to pass?

**Security**
- User input that hits a shell / SQL / regex without escape
- Secrets in code or fixtures
- Auth checks present on new endpoints
- New deps — check `package.json` / `requirements.txt` diff against known-good list (or comment if unsure)

**Performance**
- N+1 patterns in new DB code
- Synchronous IO in hot paths
- Unbounded recursion / loops over user input

**Naming & readability**
- Identifiers that lie about what the code does
- Comments that explain WHAT instead of WHY (per CLAUDE.md projects)
- Dead code or commented-out blocks
- Backward-compat shims that aren't actually needed

**Scope**
- Does the PR do one thing, or three? Suggest a split if the latter.
- Drive-by refactors that should be their own PR.

### 5. Format the review

Output structure:

```
## PR <number>: <title>
<one-line summary of what the PR does>

### Verdict
<approve / request-changes / blocking-questions>

### Strengths
<1-3 bullets — what's well done>

### Blocking (must fix before merge)
<file:line — concern, with the relevant code snippet>

### Worth fixing
<file:line — nits>

### Optional / question
<file:line — open questions for the author>
```

Save to `notes/review-pr-<number>-<ts>.md` with frontmatter `tags: [code-review, pr-<number>]`. Speak a 1-paragraph summary aloud.

### 6. Optional: post the review

If the user says "post it" or "comment on the PR":
```bash
gh pr review PR_NUMBER --body "$(cat notes/review-pr-<number>-<ts>.md)" --comment
```

Or for blocking concerns: `--request-changes` instead of `--comment`. Confirm verb with the user explicitly — posting to GitHub is irreversible (the review is visible to all repo collaborators).

## Voice routing

`documented_for_core: true` — voice-agent surfaces description to Gemini, which delegates to core via `work`. Output goes to `notes/` for diffability and `results/proactive-<ts>.txt` for voice.
