#!/usr/bin/env python3
"""Regression guard: deal-finder must write proactive results to the workspace, not the repo root.

## Why this test exists

`skills/deal-finder/scripts/scan.py` originally derived its results directory by
walking up from the script location:

    SKILL_DIR = Path(__file__).resolve().parents[1]  # → skills/deal-finder/
    WORKSPACE = SKILL_DIR.parents[1]                  # → repo root  ← WRONG
    RESULTS_DIR = WORKSPACE / "results"               # → <repo>/results/

The Telegram bridge polls `~/.sutando/workspace/results/` for `proactive-*.txt`
files. Deal-finder notifications were written to `<repo>/results/` and silently
dropped — the bridge never saw them.

Fixed in PR #110 by importing `resolve_workspace()` from `src/` and using it
for `RESULTS_DIR`.

These source-grep tests pin the fix so a future refactor that drifts back to the
`SKILL_DIR.parents` walk fails here rather than silently in production.
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SRC = (REPO / "skills" / "deal-finder" / "scripts" / "scan.py").read_text()


def test_no_workspace_alias_via_parents_walk():
    """Must NOT have a WORKSPACE variable assigned by walking .parents[] from
    SKILL_DIR. That walk lands on the repo root, not the user workspace, so
    any path derived from it (RESULTS_DIR, .env, etc.) would be wrong."""
    bad = re.search(
        r'\bWORKSPACE\b\s*=\s*SKILL_DIR\.parents\[',
        SRC,
    )
    assert bad is None, (
        "deal-finder/scan.py assigns WORKSPACE via SKILL_DIR.parents[] — "
        "this resolves to the repo root, not ~/.sutando/workspace/. "
        "Any path derived from it (RESULTS_DIR, .env) is wrong. "
        "Use resolve_workspace() from src/ for runtime state paths."
    )


def test_results_dir_uses_resolve_workspace():
    """RESULTS_DIR must be derived from resolve_workspace(), not from __file__."""
    assert re.search(
        r'resolve_workspace\s*\(.*\)\s*/\s*["\']results["\']',
        SRC,
    ), (
        "deal-finder/scan.py must compute RESULTS_DIR via resolve_workspace() "
        "so notifications land in ~/.sutando/workspace/results/ where the "
        "Telegram bridge can find them."
    )


def test_env_file_uses_repo_dir_not_workspace_alias():
    """The .env lookup must use REPO_DIR (the repo root), not a variable that
    shadows the workspace. Before the fix, the misnamed WORKSPACE variable was
    used for both runtime state and .env lookup — renaming to REPO_DIR makes
    the intent clear."""
    assert re.search(
        r'REPO_DIR\s*/\s*["\']\.env["\']',
        SRC,
    ), (
        "deal-finder/scan.py must reference REPO_DIR / \".env\" for the .env "
        "lookup. If this fails, the variable may have been renamed or the "
        "fix reverted."
    )


def main():
    failures = []
    for fn in (
        test_no_workspace_alias_via_parents_walk,
        test_results_dir_uses_resolve_workspace,
        test_env_file_uses_repo_dir_not_workspace_alias,
    ):
        try:
            fn()
            print(f"  ✓ {fn.__name__}")
        except AssertionError as e:
            failures.append(f"{fn.__name__}: {e}")
            print(f"  ✗ {fn.__name__}")
    if failures:
        print("\nFailures:")
        for f in failures:
            print(f"  {f}")
        sys.exit(1)
    print("All deal-finder-workspace-path tests passed.")


if __name__ == "__main__":
    main()
