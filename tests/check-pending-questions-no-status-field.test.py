#!/usr/bin/env python3
"""Tests for the no-Status-field-means-unanswered behavior in
check-pending-questions.py (Phase 5.19).

Bug class:
    `pending-questions.md` is the workspace's central durable record of
    open user-input asks. Two formats are in active use:

    1. **Structured**: `## Title\\n- **Status:** unanswered` — the
       form that voice / chat surfaces write when they programmatically
       record a question.
    2. **Free-form prose**: `## Title\\nSome plain text...` — the form
       a human types directly in markdown, deleting the section when
       resolved rather than marking it.

    Before this PR, `get_waiting_questions()` *required* an explicit
    `**Status:**` field. Sections in the free-form prose style were
    silently dropped from the waiting list — meaning a question typed
    directly into pending-questions.md by the user would never trigger
    a macOS notification or a Discord DM ping, and would never appear
    in `notify_voice` either. The owner could write a question and
    have it sit there forever, with the dashboard / notifier
    completely silent.

Fix (matches OSS sutando):
    Treat a section with no Status field as unanswered (default-open),
    consistent with the documented convention that prose sections are
    "deleted when resolved, not marked done." Sections with an
    *explicit* status of "resolved" / "done" / "answered" are still
    skipped so the structured format keeps working.

Tests cover six concerns:

  1. **Free-form prose**: no Status field → reported as waiting.
  2. **Explicit unanswered**: `**Status:** unanswered` → reported.
  3. **Explicit waiting**: `**Status:** waiting` → reported.
  4. **Explicit resolved / done / answered**: skipped.
  5. **Empty title**: skipped (defensive — `## \\n` shouldn't show up).
  6. **Mixed file**: a real-world mix where both formats coexist;
     every unanswered section (free-form or structured) is reported,
     and every resolved section is skipped.

Run: `python3 tests/check-pending-questions-no-status-field.test.py`
"""

import importlib.util
import os
import sys
import tempfile
from pathlib import Path


REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "src"))


def _load_with_pq_file(content: str):
    """Load check-pending-questions.py with PQ_FILE patched to a temp
    file containing `content`. Returns (module, tmpdir) so the caller
    can cleanup. The module-level PQ_FILE binding is resolved at
    import time; we override it post-import."""
    tmp = tempfile.mkdtemp(prefix="sutando-pq-test-")
    pq_path = Path(tmp) / "pending-questions.md"
    pq_path.write_text(content)
    os.environ.setdefault("SUTANDO_WORKSPACE", tmp)
    sys.modules.pop("cpq_under_test", None)
    spec = importlib.util.spec_from_file_location(
        "cpq_under_test", REPO / "src" / "check-pending-questions.py"
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.PQ_FILE = pq_path
    return mod, tmp


def _run(content: str):
    mod, tmp = _load_with_pq_file(content)
    try:
        return mod.get_waiting_questions()
    finally:
        # Best-effort cleanup
        try:
            (Path(tmp) / "pending-questions.md").unlink()
            Path(tmp).rmdir()
        except OSError:
            pass


# -----------------------------------------------------------------------
# 1. Free-form prose (no Status field) — must be reported as waiting
# -----------------------------------------------------------------------


def test_free_form_prose_reported():
    """A section with no Status field is the human-typed style; it
    should be treated as unanswered. Pre-Phase-5.19 this returned
    []. Post-port it returns the section."""
    content = (
        "# Pending\n"
        "\n"
        "## Should I sell the bike?\n"
        "Considering it. Need to think about commute distance.\n"
        "\n"
        "## What language to learn next?\n"
        "Maybe Rust, maybe Zig.\n"
    )
    rows = _run(content)
    titles = [r["title"] for r in rows]
    assert len(rows) == 2, (
        f"both free-form sections should be reported, got {titles!r}"
    )
    assert "Should I sell the bike?" in titles
    assert "What language to learn next?" in titles


# -----------------------------------------------------------------------
# 2. Explicit Status: unanswered — must be reported
# -----------------------------------------------------------------------


def test_explicit_unanswered_reported():
    content = (
        "## When to take the trip?\n"
        "- **Status:** unanswered\n"
        "- **Asked:** 2026-05-01\n"
    )
    rows = _run(content)
    assert len(rows) == 1
    assert rows[0]["title"] == "When to take the trip?"


# -----------------------------------------------------------------------
# 3. Explicit Status: waiting — must be reported
# -----------------------------------------------------------------------


def test_explicit_waiting_reported():
    content = (
        "## Waiting on bug confirmation\n"
        "- **Status:** Waiting\n"
    )
    rows = _run(content)
    assert len(rows) == 1
    assert rows[0]["title"] == "Waiting on bug confirmation"


# -----------------------------------------------------------------------
# 4. Explicit resolved / done / answered — must NOT be reported
# -----------------------------------------------------------------------


def test_resolved_skipped():
    for status in ("resolved", "done", "answered", "Resolved", "DONE"):
        content = f"## Old question\n- **Status:** {status}\n"
        rows = _run(content)
        assert rows == [], (
            f"status={status!r} should skip the section, got {rows!r}"
        )


# -----------------------------------------------------------------------
# 5. Empty title — must NOT be reported
# -----------------------------------------------------------------------


def test_empty_title_skipped():
    """Defensive: `##\\n` shouldn't appear in real files, but if it
    does we shouldn't emit an empty-title notification row."""
    content = "## \n- **Status:** unanswered\n"
    rows = _run(content)
    assert rows == [], f"empty-title section should skip, got {rows!r}"


# -----------------------------------------------------------------------
# 6. Mixed real-world file
# -----------------------------------------------------------------------


def test_mixed_file_reports_only_waiting_sections():
    """A pending-questions.md file in real use mixes formats. Every
    unanswered/waiting section (regardless of format) must be
    reported; every resolved section must be skipped."""
    content = (
        "# Pending Questions\n"
        "\n"
        "## Q1 — Bike purchase\n"   # legacy format, prose body
        "Should I do it now or wait until fall?\n"
        "\n"
        "## Q2 — Old structured ask\n"
        "- **Status:** resolved\n"
        "- **Resolution:** decided yes\n"
        "\n"
        "## Q3 — New structured ask\n"
        "- **Status:** unanswered\n"
        "- **Asked:** 2026-06-01\n"
        "\n"
        "## Free-form note about scheduling\n"   # no status — must report
        "I'm wondering whether Friday or Monday works better.\n"
    )
    rows = _run(content)
    titles = [r["title"] for r in rows]
    expected = {
        "Q1 — Bike purchase",       # free-form prose
        "Q3 — New structured ask",  # explicit unanswered
        "Free-form note about scheduling",  # free-form prose
    }
    assert set(titles) == expected, (
        f"mixed-file mismatch — expected {expected!r}, got {set(titles)!r}"
    )
    # And the resolved section MUST NOT appear
    assert "Q2 — Old structured ask" not in titles


# -----------------------------------------------------------------------
# 7. Empty file — must return empty list (no crash, no exception)
# -----------------------------------------------------------------------


def test_empty_file_returns_empty():
    rows = _run("")
    assert rows == [], f"empty file should return [], got {rows!r}"


def main():
    test_free_form_prose_reported()
    test_explicit_unanswered_reported()
    test_explicit_waiting_reported()
    test_resolved_skipped()
    test_empty_title_skipped()
    test_mixed_file_reports_only_waiting_sections()
    test_empty_file_returns_empty()
    print("All check-pending-questions-no-status-field tests passed.")


if __name__ == "__main__":
    main()
