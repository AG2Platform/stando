#!/usr/bin/env python3
"""Regression guard: dashboard must read runtime state from the workspace, not the repo root.

## Why this test exists

`src/dashboard.py` had a class of bug where `shared_personal_path()` and
`personal_path()` were called with `REPO_DIR` as the workspace fallback arg.
When `SUTANDO_MEMORY_DIR` is not configured (the common case), these helpers
fall back to the supplied arg — so the dashboard read stale stub files from
the repo root instead of the live workspace files:

- `get_pending_count()` read `<repo>/pending-questions.md` ("none open")
  instead of `~/.sutando/workspace/pending-questions.md` (the live file).
- `get_score()` and `get_use_case_matrix()` read `<repo>/build_log.md`
  (missing or stale) instead of the workspace build log.
- Notes-serving endpoints resolved notes dir from the repo root.

Fixed in PR #109 by:
- `get_pending_count()` → `state_path("pending-questions.md")`
- `build_log.md` readers → `shared_personal_path("build_log.md")` with no
  explicit workspace arg (falls back to `resolve_workspace()`)
- Notes dir → `shared_personal_path("notes")` with no explicit workspace arg

These source-grep tests pin that shape so a future refactor that drifts back
toward REPO_DIR-as-workspace fails here rather than silently in production.
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SRC = (REPO / "src" / "dashboard.py").read_text()


def test_pending_questions_not_via_repo_dir():
    """get_pending_count() must NOT pass REPO_DIR to personal_path() or
    shared_personal_path() as the workspace fallback for pending-questions.md."""
    bad = re.search(
        r'personal_path\s*\(\s*["\']pending-questions\.md["\']\s*,\s*REPO_DIR\s*\)',
        SRC,
    )
    assert bad is None, (
        "dashboard.py passes REPO_DIR to personal_path() for pending-questions.md. "
        "When SUTANDO_MEMORY_DIR is unset this reads the repo stub "
        "(\"none open\") instead of the live workspace file. "
        "Use state_path(\"pending-questions.md\") instead."
    )


def test_pending_questions_uses_state_path():
    """get_pending_count() must resolve pending-questions.md via state_path(),
    which goes directly through resolve_workspace() with no REPO_DIR fallback."""
    assert re.search(
        r'state_path\s*\(\s*["\']pending-questions\.md["\']\s*\)',
        SRC,
    ), (
        "dashboard.py must call state_path(\"pending-questions.md\") to read "
        "the pending question count from the live workspace file. "
        "Using personal_path(..., REPO_DIR) reads a stale repo stub instead."
    )


def test_build_log_not_via_repo_dir():
    """build_log.md reads must NOT pass REPO_DIR to shared_personal_path().
    Two callers: get_score() and get_use_case_matrix()."""
    bad = re.search(
        r'shared_personal_path\s*\(\s*["\']build_log\.md["\']\s*,\s*REPO_DIR\s*\)',
        SRC,
    )
    assert bad is None, (
        "dashboard.py passes REPO_DIR to shared_personal_path() for build_log.md. "
        "When SUTANDO_MEMORY_DIR is unset this reads from the repo root "
        "(often missing or stale) instead of the workspace build log. "
        "Drop the second arg so it falls back to resolve_workspace()."
    )


def test_notes_not_via_repo_dir():
    """Notes dir resolution must NOT pass REPO_DIR to shared_personal_path().
    Two callers: _resolve_note_path() and the /notes HTTP handler."""
    matches = re.findall(
        r'shared_personal_path\s*\(\s*["\']notes["\']\s*,\s*REPO_DIR\s*\)',
        SRC,
    )
    assert not matches, (
        f"dashboard.py passes REPO_DIR to shared_personal_path() for notes/ "
        f"({len(matches)} occurrence(s)). Drop the second arg so the notes dir "
        f"resolves to the workspace, not the repo root."
    )


def main():
    failures = []
    for fn in (
        test_pending_questions_not_via_repo_dir,
        test_pending_questions_uses_state_path,
        test_build_log_not_via_repo_dir,
        test_notes_not_via_repo_dir,
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
    print("All dashboard-workspace-path tests passed.")


if __name__ == "__main__":
    main()
