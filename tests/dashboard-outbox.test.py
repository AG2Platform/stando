#!/usr/bin/env python3
"""Tests for the `get_outbox` dashboard reader (Phase 5.15).

`src/outbox_log.py` is the audit log every bridge appends to after a
successful outbound delivery (currently slack-bridge writes; the
discord/telegram families are expected to follow). The data was
invisible until this PR — there was no reader on the dashboard.

This test file covers four concerns for the reader added in
`src/dashboard.py`:

  1. **Happy path** — given outbox entries, `get_outbox(limit)` returns
     up to `limit` of them via `outbox_log.read_recent(limit)`.
  2. **Empty / missing** — fresh install (no outbox file yet) returns
     an empty list, not an exception. The dashboard's render block is
     guarded by `if outbox:` so callers tolerate empty results.
  3. **Fault tolerance** — if `outbox_log` can't be imported or
     `read_recent` raises, `get_outbox` returns `[]` rather than
     bubbling the exception up into the dashboard render path.
     The dashboard must keep rendering even when the audit log is
     broken — telemetry is a courtesy, never load-bearing.
  4. **Render block emits the card only when entries exist** —
     structural source guard so a future PR can't accidentally
     drop the `if outbox:` gate (would surface a stub card on fresh
     installs that have never delivered a message).

Run: `python3 tests/dashboard-outbox.test.py`
"""

import importlib
import importlib.util
import os
import re
import sys
import tempfile
import types
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "src"))


def _load_dashboard(workspace: Path):
    """Load `src/dashboard.py` as `dash` after pinning SUTANDO_WORKSPACE.

    Dashboard resolves workspace at module-import time (REPO_DIR /
    state_path etc.); each test gets its own sandbox so the outbox
    file lives under a tempdir, not the developer's live workspace."""
    os.environ["SUTANDO_WORKSPACE"] = str(workspace)
    (workspace / "state").mkdir(parents=True, exist_ok=True)
    # Force a fresh import each call — dashboard caches no state from
    # outbox_log, but resolve_workspace consumers might. Safest path
    # is reload-from-spec each time.
    for stale in ("dash", "outbox_log"):
        sys.modules.pop(stale, None)
    spec = importlib.util.spec_from_file_location("dash", REPO / "src" / "dashboard.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def _isolate_workspace(fn):
    """Run `fn(workspace)` under a fresh tempdir SUTANDO_WORKSPACE.

    Cleans up the env var + tempdir on exit so other tests in the
    same pytest run see no spillover."""
    original = os.environ.get("SUTANDO_WORKSPACE")
    with tempfile.TemporaryDirectory(prefix="sutando-dashboard-outbox-test-") as tmp:
        workspace = Path(tmp)
        try:
            fn(workspace)
        finally:
            if original is None:
                os.environ.pop("SUTANDO_WORKSPACE", None)
            else:
                os.environ["SUTANDO_WORKSPACE"] = original


# -----------------------------------------------------------------------
# 1. Happy path — entries in outbox_log are returned
# -----------------------------------------------------------------------


def test_get_outbox_returns_appended_entries():
    def run(workspace):
        dash = _load_dashboard(workspace)
        import outbox_log  # picks up the sandboxed workspace
        outbox_log.append(
            channel_type="slack_dm",
            recipient="U_test",
            body="hello from the test",
            task_id="task-test-1",
        )
        outbox_log.append(
            channel_type="discord_channel",
            recipient="C_test",
            body="second message",
            task_id="task-test-2",
        )
        rows = dash.get_outbox(10)
        assert isinstance(rows, list), f"expected list, got {type(rows).__name__}"
        assert len(rows) == 2, f"expected 2 entries, got {len(rows)}"
        # The reader exposes the underlying JSONL records — fields used by
        # the render block (channel_type, recipient, body_preview, iso_ts)
        # must round-trip.
        channels = {r["channel_type"] for r in rows}
        assert channels == {"slack_dm", "discord_channel"}, (
            f"channels mismatch: {channels!r}"
        )
        bodies = {r["body_preview"] for r in rows}
        assert bodies == {"hello from the test", "second message"}, (
            f"bodies mismatch: {bodies!r}"
        )
    _isolate_workspace(run)


# -----------------------------------------------------------------------
# 2. Limit is honored (don't flood the dashboard with thousands of rows)
# -----------------------------------------------------------------------


def test_get_outbox_honors_limit():
    def run(workspace):
        dash = _load_dashboard(workspace)
        import outbox_log
        for i in range(25):
            outbox_log.append(
                channel_type="slack_dm",
                recipient=f"U_{i}",
                body=f"msg {i}",
            )
        rows = dash.get_outbox(5)
        assert len(rows) == 5, f"limit=5 should return 5 rows, got {len(rows)}"
        # Default-limit fallback also works (reader default is 10 in dashboard;
        # the underlying outbox_log.read_recent default is 50, but dashboard's
        # wrapper caps at 10 unless overridden).
        rows = dash.get_outbox()
        assert len(rows) == 10, f"default limit should return 10, got {len(rows)}"
    _isolate_workspace(run)


# -----------------------------------------------------------------------
# 3. Empty / missing file — returns [] not exception
# -----------------------------------------------------------------------


def test_get_outbox_empty_when_no_writes_yet():
    """Fresh install: outbox file has never been written. Dashboard
    must not crash and must return an empty list (the render block
    will then hide the card via `if outbox:`)."""
    def run(workspace):
        dash = _load_dashboard(workspace)
        rows = dash.get_outbox(10)
        assert rows == [], f"expected empty list on fresh workspace, got {rows!r}"
    _isolate_workspace(run)


# -----------------------------------------------------------------------
# 4. Fault tolerance — import / read_recent failures degrade to []
# -----------------------------------------------------------------------


def test_get_outbox_swallows_import_error():
    """Telemetry never load-bearing. If the outbox_log module is missing
    or its read_recent raises, get_outbox must not propagate — the
    dashboard should keep rendering everything else."""
    def run(workspace):
        dash = _load_dashboard(workspace)
        # Swap the cached outbox_log import in sys.modules with a stub
        # whose read_recent always raises. The reader's try/except
        # must catch it.
        original = sys.modules.pop("outbox_log", None)
        broken = types.ModuleType("outbox_log")
        def _boom(limit=50):
            raise RuntimeError("simulated outbox_log breakage")
        broken.read_recent = _boom
        sys.modules["outbox_log"] = broken
        try:
            rows = dash.get_outbox(10)
            assert rows == [], (
                f"reader must swallow read_recent errors, got {rows!r}"
            )
        finally:
            if original is not None:
                sys.modules["outbox_log"] = original
            else:
                sys.modules.pop("outbox_log", None)
    _isolate_workspace(run)


# -----------------------------------------------------------------------
# 5. Structural guard — render block is gated on `if outbox:`
# -----------------------------------------------------------------------


def test_render_block_hides_card_when_empty():
    """A future PR that drops the `if outbox:` guard would surface a
    stub card on fresh installs that have never delivered a message.
    This pin keeps that gate in place."""
    src = (REPO / "src" / "dashboard.py").read_text()
    # The render block sits between the get_outbox call and the
    # `cards.append(..."Outbox"...)`. Confirm a literal `if outbox:`
    # guard precedes the append.
    m = re.search(
        r"outbox\s*=\s*get_outbox\([^)]*\)\s*\n\s*if\s+outbox\s*:",
        src,
    )
    assert m, (
        "Outbox card render block is missing `if outbox:` guard — "
        "fresh installs would see an empty card"
    )
    # And the Outbox card must be the only cards.append() inside that
    # `if outbox:` block (no duplicate / fallback card emitted on the
    # empty branch).
    outbox_card_count = src.count('<h2>Outbox</h2>')
    assert outbox_card_count == 1, (
        f"expected exactly 1 Outbox card render, found {outbox_card_count}"
    )


def test_get_outbox_is_module_attribute():
    """The reader must be importable at module scope (not nested in a
    closure or a class). Catches a refactor that accidentally hides
    the function from external callers — e.g. tests, the planned
    /api/outbox endpoint, etc."""
    def run(workspace):
        dash = _load_dashboard(workspace)
        assert callable(getattr(dash, "get_outbox", None)), (
            "dashboard.get_outbox must be a module-level callable"
        )
    _isolate_workspace(run)


def main():
    test_get_outbox_returns_appended_entries()
    test_get_outbox_honors_limit()
    test_get_outbox_empty_when_no_writes_yet()
    test_get_outbox_swallows_import_error()
    test_render_block_hides_card_when_empty()
    test_get_outbox_is_module_attribute()
    print("All dashboard-outbox tests passed.")


if __name__ == "__main__":
    main()
