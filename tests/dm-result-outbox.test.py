#!/usr/bin/env python3
"""Tests for outbox_log writes in dm-result.py (Phase 5.18).

`src/dm-result.py` is the REST fallback path that delivers proactive
owner-DM payloads when the live discord-bridge isn't connected. Phase
5.16 added outbox_log.append calls to discord-bridge.py so live-bridge
deliveries appear in the dashboard's Outbox card; this phase closes
the symmetric gap so REST-fallback deliveries also show up.

Without this PR, an offline-bridge owner DM would land successfully
on Discord but never appear in the dashboard alongside the live-bridge
rows — confusing audit trail that would silently miss every delivery
during bridge downtime.

Tests cover four concerns:

  1. **Structural** — exactly 1 `outbox_log.append(...)` site in
     dm-result.py, wrapped in `try / import outbox_log / append /
     except Exception: pass`. Telemetry is best-effort and must never
     block the `return True` that signals successful delivery to the
     caller (which then exits 0 to whoever invoked dm-result).

  2. **Variable-binding** — the append uses `channel_type=discord_dm`
     to match discord-bridge.py's live-bridge writes (so both surfaces
     render the same 💬 icon in the dashboard card). The
     `recipient_label` is the constant `"owner DM (via dm-result.py)"`
     — a deliberate divergence from discord-bridge's per-user label
     ("alice DM") because dm-result doesn't have the username locally
     and we don't want to pay an extra REST call just to populate it.
     The label doubles as an audit-trail marker letting operators
     distinguish REST-fallback rows from live-bridge rows at a glance.

  3. **Positioning** — the append sits AFTER the success-state `print(...)`
     and BEFORE `return True`. Catches a future refactor that hoists
     it above a failure branch — would record audit rows for unsent
     messages.

  4. **Round-trip** — the dashboard's `get_outbox` reader (added in
     Phase 5.15) picks up the row with the right channel_type and
     label.

Run: `python3 tests/dm-result-outbox.test.py`
"""

import importlib.util
import os
import re
import sys
import tempfile
from pathlib import Path


REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "src"))

DM_PATH = REPO / "src" / "dm-result.py"


# -----------------------------------------------------------------------
# 1. Structural — 1 append site, fail-open wrapped
# -----------------------------------------------------------------------


def test_one_append_site_and_fail_open_wrapped():
    src = DM_PATH.read_text()
    sites = list(re.finditer(r"outbox_log\.append\s*\(", src))
    assert len(sites) == 1, (
        f"expected exactly 1 outbox_log.append site in dm-result.py, "
        f"got {len(sites)}. Future PR adding new delivery surfaces "
        f"should also bump this count + add a fail-open wrapper."
    )
    snippet = src[max(0, sites[0].start() - 600): sites[0].end() + 600]
    assert "try:" in snippet, "outbox_log.append not wrapped in try block"
    assert "except Exception:" in snippet, (
        "outbox_log.append not protected by `except Exception:`"
    )
    assert "pass" in snippet, (
        "outbox_log.append except clause does not pass-swallow"
    )


# -----------------------------------------------------------------------
# 2. Variable-binding — required kwargs + matching discord-bridge vocab
# -----------------------------------------------------------------------


def test_append_uses_discord_dm_channel_type():
    """Match discord-bridge.py's live-bridge writes so both surfaces
    render the same 💬 icon in the dashboard card."""
    src = DM_PATH.read_text()
    m = re.search(
        r'outbox_log\.append\s*\(\s*[\s\S]*?channel_type\s*=\s*[\'"]([^\'"]+)[\'"]',
        src,
    )
    assert m, "channel_type kwarg not found in outbox_log.append"
    assert m.group(1) == "discord_dm", (
        f"channel_type must be 'discord_dm' to match discord-bridge "
        f"live-bridge vocabulary, got {m.group(1)!r}"
    )


def test_append_has_required_kwargs():
    """The dashboard renderer pulls channel_type, recipient,
    recipient_label, and body_preview. body and recipient must be
    present; recipient_label is set explicitly for this surface."""
    src = DM_PATH.read_text()
    m = re.search(
        r"outbox_log\.append\s*\(\s*([\s\S]*?)\)\s*\n",
        src,
    )
    assert m, "outbox_log.append args block not found"
    args = m.group(1)
    for required in ("channel_type", "recipient", "body", "recipient_label"):
        assert f"{required}=" in args, (
            f"append missing kwarg `{required}=`: {args!r}"
        )


def test_recipient_label_is_dm_result_marker():
    """Constant label "owner DM (via dm-result.py)" is the deliberate
    audit-trail marker that distinguishes REST-fallback rows from
    live-bridge rows in the dashboard. Operators rely on this to
    diagnose whether a delivery used the live bridge or the fallback.
    Catches a future refactor that drops the marker."""
    src = DM_PATH.read_text()
    m = re.search(
        r'outbox_log\.append\s*\(\s*[\s\S]*?recipient_label\s*=\s*[\'"]([^\'"]+)[\'"]',
        src,
    )
    assert m, "recipient_label kwarg not found in outbox_log.append"
    assert m.group(1) == "owner DM (via dm-result.py)", (
        f"recipient_label must be the dm-result audit marker, "
        f"got {m.group(1)!r}"
    )


# -----------------------------------------------------------------------
# 3. Positioning — append is after the success-state print, before return True
# -----------------------------------------------------------------------


def test_append_sits_inside_success_block():
    """The append must come AFTER the success-state print "sent to DM"
    and BEFORE the `return True` that signals successful delivery.
    Hoisting it above the print would record audit rows for sends
    that hadn't completed yet; placing it after return True would
    make it unreachable. Catches both."""
    src = DM_PATH.read_text()
    # Find the send_dm function body
    fn_match = re.search(
        r"^def send_dm\([\s\S]+?(?=^def |\Z)",
        src,
        flags=re.MULTILINE,
    )
    assert fn_match, "send_dm function not found"
    body = fn_match.group(0)

    success_print_pos = body.find('sent to DM')
    append_pos = body.find("outbox_log.append(")
    # The last `return True` in send_dm is the success exit; we want
    # to confirm the append sits before that specific one. There's an
    # earlier `return True` at the "no deliverable payload" early-out;
    # that one is fine — the append should sit between the success
    # print and the FINAL return True.
    return_true_positions = [
        m.start() for m in re.finditer(r"^\s*return True\s*$", body, flags=re.MULTILINE)
    ]
    assert return_true_positions, "no `return True` found in send_dm"
    final_return = return_true_positions[-1]

    assert success_print_pos > 0, '"sent to DM" success print not found in send_dm'
    assert append_pos > 0, "outbox_log.append not found in send_dm"
    assert append_pos > success_print_pos, (
        f"outbox_log.append must come AFTER the 'sent to DM' success "
        f"print (would record rows for incomplete deliveries otherwise)"
    )
    assert append_pos < final_return, (
        f"outbox_log.append must come BEFORE the final `return True` "
        f"in send_dm (would be unreachable otherwise)"
    )


# -----------------------------------------------------------------------
# 4. Round-trip — append → outbox_log → dashboard.get_outbox
# -----------------------------------------------------------------------


def _isolate_workspace(fn):
    original = os.environ.get("SUTANDO_WORKSPACE")
    with tempfile.TemporaryDirectory(prefix="sutando-dm-result-outbox-") as tmp:
        workspace = Path(tmp)
        os.environ["SUTANDO_WORKSPACE"] = str(workspace)
        sys.modules.pop("outbox_log", None)
        try:
            fn(workspace)
        finally:
            sys.modules.pop("outbox_log", None)
            if original is None:
                os.environ.pop("SUTANDO_WORKSPACE", None)
            else:
                os.environ["SUTANDO_WORKSPACE"] = original


def test_round_trip_through_dashboard_reader():
    """Append in the same shape dm-result.py uses, then read back via
    the dashboard's `get_outbox` reader. Confirms the audit row is
    well-formed and the dashboard card will render it with the
    correct discord_dm 💬 icon + recipient_label marker."""
    def run(workspace):
        import outbox_log
        outbox_log.append(
            channel_type="discord_dm",
            recipient="1234567890",
            body="Hello via REST fallback",
            recipient_label="owner DM (via dm-result.py)",
        )
        sys.modules.pop("dash", None)
        spec = importlib.util.spec_from_file_location(
            "dash", REPO / "src" / "dashboard.py"
        )
        dash = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(dash)
        rows = dash.get_outbox(10)
        assert len(rows) == 1, f"expected 1 row, got {len(rows)}"
        row = rows[0]
        assert row["channel_type"] == "discord_dm", (
            f"channel_type must round-trip, got {row['channel_type']!r}"
        )
        assert row["recipient"] == "1234567890"
        assert row["body_preview"] == "Hello via REST fallback"
        assert row["recipient_label"] == "owner DM (via dm-result.py)", (
            f"recipient_label marker must round-trip so the dashboard "
            f"distinguishes REST-fallback rows from live-bridge rows; "
            f"got {row['recipient_label']!r}"
        )
    _isolate_workspace(run)


def main():
    test_one_append_site_and_fail_open_wrapped()
    test_append_uses_discord_dm_channel_type()
    test_append_has_required_kwargs()
    test_recipient_label_is_dm_result_marker()
    test_append_sits_inside_success_block()
    test_round_trip_through_dashboard_reader()
    print("All dm-result-outbox tests passed.")


if __name__ == "__main__":
    main()
