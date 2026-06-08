#!/usr/bin/env python3
"""Tests for outbox_log writes in discord-bridge.py (Phase 5.16).

`src/outbox_log.py` is the audit log every bridge appends to after a
successful outbound delivery. Phase 5.15 added the dashboard reader +
card so the data is visible. Phase 5.16 ports the WRITES from OSS
sutando's discord-bridge to stando — 3 delivery sites (DM replies +
channel replies in poll_results, proactive owner DMs, dm-fallback
channel-redirect deliveries).

Tests cover three concerns:

  1. **Structural** — exactly the expected 3 `outbox_log.append(...)`
     call sites exist in discord-bridge.py, and each is wrapped in a
     `try: ... except Exception: pass` so a broken outbox_log can
     never block a Discord delivery (telemetry must not be load-bearing).
  2. **Variable-binding** — each append uses the right field map for
     its surface: `channel_type` derived from the channel kind, `recipient`
     keyed off the channel id, `recipient_label` populated when the
     name is available, `body` from the cleaned text, `task_id` from
     the file stem or the carried task_id var.
  3. **Round-trip via outbox_log** — when the bridge actually appends,
     the resulting JSONL row is well-formed and readable via the
     dashboard's `get_outbox` reader. Catches a future refactor that
     renames a kwarg or rearranges the call site.

Run: `python3 tests/discord-bridge-outbox.test.py`
"""

import importlib.util
import json
import os
import re
import sys
import tempfile
import types
from pathlib import Path


REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "src"))

DBRIDGE_PATH = REPO / "src" / "discord-bridge.py"


# -----------------------------------------------------------------------
# 1. Structural — 3 append sites, each fail-open
# -----------------------------------------------------------------------


def test_three_append_sites_exist_and_are_fail_open():
    """The audit log writes are best-effort; a runtime error inside
    outbox_log MUST NOT propagate up the Discord send path. Phase 5.16
    ports exactly 3 sites (DM/channel reply, proactive owner DM,
    dm-fallback channel-redirect). A future PR that adds a 4th site
    without the try/except wrapper would silently risk dropping a
    Discord reply on an outbox failure."""
    src = DBRIDGE_PATH.read_text()
    sites = list(re.finditer(r"outbox_log\.append\s*\(", src))
    assert len(sites) == 3, (
        f"expected 3 outbox_log.append sites in discord-bridge.py, "
        f"got {len(sites)}"
    )
    for m in sites:
        # Walk ~250 chars before the match looking for the enclosing
        # try: ... import outbox_log block. The OSS shape is:
        #     try:
        #         import outbox_log
        #         ...
        #         outbox_log.append(...)
        #     except Exception:
        #         pass
        # We allow ~30 lines of preamble (label resolution) between
        # `try:` and the append call.
        snippet = src[max(0, m.start() - 800): m.end() + 800]
        assert "try:" in snippet, (
            f"outbox_log.append at byte {m.start()} not wrapped in try block"
        )
        assert "except Exception:" in snippet, (
            f"outbox_log.append at byte {m.start()} not protected by except Exception"
        )
        assert "pass" in snippet, (
            f"outbox_log.append at byte {m.start()} except clause does not pass-swallow"
        )


# -----------------------------------------------------------------------
# 2. Variable-binding — each append has the expected kwargs
# -----------------------------------------------------------------------


def test_all_appends_include_required_kwargs():
    """Each append must carry channel_type, recipient, body, task_id.
    recipient_label is optional but the OSS port adds it everywhere
    (drives the dashboard's human-readable label, otherwise the card
    falls back to the bare channel id which is useless for review)."""
    src = DBRIDGE_PATH.read_text()
    # Pull the body of each append (its arg list). Multiline match.
    matches = re.findall(
        r"outbox_log\.append\s*\(\s*([\s\S]*?)\)\s*\n",
        src,
    )
    assert len(matches) == 3, f"expected 3 append arg blocks, got {len(matches)}"
    for i, args in enumerate(matches, start=1):
        for required in ("channel_type", "recipient", "body", "task_id"):
            assert f"{required}=" in args, (
                f"append site #{i} missing kwarg `{required}=`: {args!r}"
            )
        assert "recipient_label=" in args, (
            f"append site #{i} missing kwarg `recipient_label=` "
            f"(needed for dashboard label rendering): {args!r}"
        )


def test_channel_type_values_are_recognized():
    """The dashboard's _channel_icon dict maps known channel_type
    values to emojis. Discord-bridge appends only `discord_dm` or
    `discord_channel`; a typo here would silently render the default
    `→` arrow in the dashboard card."""
    src = DBRIDGE_PATH.read_text()
    types_used = set(re.findall(
        r"channel_type\s*=\s*[\"']([^\"']+)[\"']",
        src,
    ))
    # We also pick up types in dict literals like `"discord_dm" if`,
    # but that's fine — those are derived constants going INTO the
    # append, same vocabulary.
    extra_types = types_used - {"discord_dm", "discord_channel"}
    assert not extra_types, (
        f"unexpected channel_type values in discord-bridge.py: "
        f"{extra_types!r}. Update dashboard._channel_icon if intentional."
    )


# -----------------------------------------------------------------------
# 3. Round-trip — bridge writes feed the reader
# -----------------------------------------------------------------------


def _isolate_workspace(fn):
    """Run `fn(workspace)` under a fresh tempdir SUTANDO_WORKSPACE so
    appended rows don't pollute the developer's live outbox.log."""
    original = os.environ.get("SUTANDO_WORKSPACE")
    with tempfile.TemporaryDirectory(prefix="sutando-discord-outbox-test-") as tmp:
        workspace = Path(tmp)
        os.environ["SUTANDO_WORKSPACE"] = str(workspace)
        # Force a fresh outbox_log import so it sees the env-var change
        sys.modules.pop("outbox_log", None)
        try:
            fn(workspace)
        finally:
            sys.modules.pop("outbox_log", None)
            if original is None:
                os.environ.pop("SUTANDO_WORKSPACE", None)
            else:
                os.environ["SUTANDO_WORKSPACE"] = original


def test_round_trip_through_outbox_log():
    """Append the same shape discord-bridge.py uses for site A
    (DM/channel reply). Verify the row round-trips via the dashboard
    reader."""
    def run(workspace):
        import outbox_log
        outbox_log.append(
            channel_type="discord_channel",
            recipient="123456789",
            recipient_label="#general",
            body="A test channel reply.",
            task_id="task-test-channel",
        )
        outbox_log.append(
            channel_type="discord_dm",
            recipient="987654321",
            recipient_label="alice DM",
            body="A test DM reply.",
            task_id="task-test-dm",
        )
        # Load dashboard fresh (it picks up our sandboxed workspace
        # via SUTANDO_WORKSPACE for outbox_log.read_recent's path).
        sys.modules.pop("dash", None)
        spec = importlib.util.spec_from_file_location(
            "dash", REPO / "src" / "dashboard.py"
        )
        dash = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(dash)
        rows = dash.get_outbox(10)
        assert len(rows) == 2, f"expected 2 rows, got {len(rows)}"
        by_kind = {r["channel_type"]: r for r in rows}
        assert by_kind["discord_channel"]["recipient_label"] == "#general"
        assert by_kind["discord_channel"]["body_preview"] == "A test channel reply."
        assert by_kind["discord_channel"]["task_id"] == "task-test-channel"
        assert by_kind["discord_dm"]["recipient_label"] == "alice DM"
        assert by_kind["discord_dm"]["body_preview"] == "A test DM reply."
        assert by_kind["discord_dm"]["task_id"] == "task-test-dm"
    _isolate_workspace(run)


# -----------------------------------------------------------------------
# 4. Drift guard — sites stay positioned inside the text-send block
# -----------------------------------------------------------------------


def test_appends_follow_text_send_loops():
    """Each append must be preceded (within the same indented block)
    by a `for chunk in _chunk_for_discord(...)` send loop. Catches a
    future refactor that hoists an append out of its `if text:` gate
    — would record empty-body audit rows when the bridge only sent
    files (no text body)."""
    src = DBRIDGE_PATH.read_text()
    # For each append site, walk backwards through the immediately
    # preceding 30 lines and confirm a _chunk_for_discord send loop
    # appears.
    lines = src.splitlines()
    append_lines = [
        i for i, ln in enumerate(lines)
        if "outbox_log.append(" in ln
    ]
    assert len(append_lines) == 3, (
        f"line scan disagrees with regex: {len(append_lines)} append "
        f"lines"
    )
    for lineno in append_lines:
        preceding = "\n".join(lines[max(0, lineno - 30): lineno])
        assert "for chunk in _chunk_for_discord(" in preceding, (
            f"outbox_log.append at line {lineno+1} not preceded by a "
            f"_chunk_for_discord send loop within 30 lines — may record "
            f"audit rows for empty/file-only deliveries"
        )


def main():
    test_three_append_sites_exist_and_are_fail_open()
    test_all_appends_include_required_kwargs()
    test_channel_type_values_are_recognized()
    test_round_trip_through_outbox_log()
    test_appends_follow_text_send_loops()
    print("All discord-bridge-outbox tests passed.")


if __name__ == "__main__":
    main()
