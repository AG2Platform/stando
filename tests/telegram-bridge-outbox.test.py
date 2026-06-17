#!/usr/bin/env python3
"""Tests for outbox_log writes in telegram-bridge.py (Phase 5.17).

`src/outbox_log.py` is the audit log every bridge appends to after a
successful outbound delivery. Phase 5.15 added the dashboard reader +
card, Phase 5.16 added discord-bridge writes; this phase closes
bridge-family symmetry by porting the OSS telegram-bridge write site.

Telegram-bridge has a single `send_reply(chat_id, text, task_id=None)`
entry point that all outbound deliveries go through — task replies and
proactive owner DMs alike. So the port is small: one `outbox_log.append`
call after the chunked text send, plus a `task_id=...` arg added to
the function signature + the task-reply call site.

Tests cover four concerns:

  1. **Structural** — exactly 1 `outbox_log.append(...)` site exists in
     telegram-bridge.py, and it's wrapped in a `try / import / except
     Exception: pass` so a broken outbox_log can never block a Telegram
     reply.
  2. **Signature** — `send_reply` accepts the `task_id` keyword arg
     (catches a future refactor that drops it; OSS callers + the
     dashboard rely on the audit row carrying task_id when available).
  3. **Variable-binding** — the append carries channel_type="telegram",
     recipient (str-cast chat_id), body (the clean_text), and task_id
     (passed through from the caller).
  4. **Round-trip** — appending via outbox_log feeds back via the
     dashboard's `get_outbox` reader, with the right channel_type so
     the card emits the ✈️ icon.

Run: `python3 tests/telegram-bridge-outbox.test.py`
"""

import importlib.util
import inspect
import os
import re
import sys
import tempfile
from pathlib import Path


REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "src"))

TBRIDGE_PATH = REPO / "src" / "telegram-bridge.py"


def _load_tbridge():
    """Load telegram-bridge.py for signature / function inspection.

    Sets a placeholder TELEGRAM_BOT_TOKEN so the module's startup
    guard doesn't sys.exit; we never actually call the network."""
    os.environ.setdefault("TELEGRAM_BOT_TOKEN", "test-token-not-real")
    sys.modules.pop("tbridge_under_test", None)
    spec = importlib.util.spec_from_file_location(
        "tbridge_under_test", TBRIDGE_PATH
    )
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


# -----------------------------------------------------------------------
# 1. Structural — 1 append site, fail-open
# -----------------------------------------------------------------------


def test_one_append_site_and_it_is_fail_open():
    """Audit log writes are best-effort; a runtime error inside
    outbox_log MUST NOT propagate up the Telegram send path."""
    src = TBRIDGE_PATH.read_text()
    sites = list(re.finditer(r"outbox_log\.append\s*\(", src))
    assert len(sites) == 1, (
        f"expected exactly 1 outbox_log.append site in telegram-bridge.py, "
        f"got {len(sites)}. Future PR adding new delivery surfaces should "
        f"also update this count."
    )
    # Verify the wrapping try / except Exception: pass
    snippet = src[max(0, sites[0].start() - 600): sites[0].end() + 600]
    assert "try:" in snippet
    assert "except Exception:" in snippet
    assert "pass" in snippet


# -----------------------------------------------------------------------
# 2. Signature — send_reply accepts task_id
# -----------------------------------------------------------------------


def test_send_reply_accepts_task_id_kwarg():
    """OSS callers + the dashboard audit pipeline rely on the
    task_id being plumbed through send_reply. A future refactor that
    drops it would silently null out the audit row's task_id field."""
    tbridge = _load_tbridge()
    sig = inspect.signature(tbridge.send_reply)
    assert "task_id" in sig.parameters, (
        f"send_reply must accept `task_id` kwarg, got params: "
        f"{list(sig.parameters)!r}"
    )
    # Default must be None — every existing caller that doesn't pass
    # task_id must still work (proactive owner DMs).
    assert sig.parameters["task_id"].default is None, (
        f"send_reply.task_id default must be None for backward compat "
        f"with proactive-DM caller, got "
        f"{sig.parameters['task_id'].default!r}"
    )


def test_task_reply_caller_passes_task_id():
    """Structural check: the task-reply call site (poll_results)
    plumbs task_id through. The proactive caller intentionally does
    not (matches OSS behavior; the proactive file's stem could be
    threaded if we cared, but we don't yet)."""
    src = TBRIDGE_PATH.read_text()
    # The task-reply call site is the one that has `task_id=task_id`
    # as a kwarg in send_reply(...). Without it, audit rows lose
    # their task linkage.
    assert re.search(
        r"send_reply\([^)]*task_id\s*=\s*task_id[^)]*\)",
        src,
    ), (
        "task-reply send_reply call site does NOT pass `task_id=task_id` "
        "— audit rows for task replies will record task_id=None"
    )


# -----------------------------------------------------------------------
# 3. Variable-binding — required kwargs present
# -----------------------------------------------------------------------


def test_append_has_required_kwargs():
    """Each append must carry channel_type, recipient, body, task_id.
    Telegram doesn't use recipient_label (no human-readable name
    available without an extra API call) — mirrors OSS shape."""
    src = TBRIDGE_PATH.read_text()
    m = re.search(
        r"outbox_log\.append\s*\(\s*([\s\S]*?)\)\s*\n",
        src,
    )
    assert m, "outbox_log.append site not found"
    args = m.group(1)
    for required in ("channel_type", "recipient", "body", "task_id"):
        assert f"{required}=" in args, (
            f"append missing kwarg `{required}=`: {args!r}"
        )


def test_channel_type_is_telegram():
    """The dashboard's _channel_icon dict maps `telegram` to ✈️;
    a typo here would render the default `→` arrow."""
    src = TBRIDGE_PATH.read_text()
    m = re.search(
        r'outbox_log\.append\s*\(\s*[\s\S]*?channel_type\s*=\s*[\'"]([^\'"]+)[\'"]',
        src,
    )
    assert m, "channel_type kwarg not found in outbox_log.append"
    assert m.group(1) == "telegram", (
        f"channel_type must be 'telegram' to match dashboard icon map, "
        f"got {m.group(1)!r}"
    )


# -----------------------------------------------------------------------
# 4. Round-trip — append → outbox_log → dashboard.get_outbox
# -----------------------------------------------------------------------


def _isolate_workspace(fn):
    original = os.environ.get("SUTANDO_WORKSPACE")
    with tempfile.TemporaryDirectory(prefix="sutando-telegram-outbox-") as tmp:
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
    def run(workspace):
        import outbox_log
        outbox_log.append(
            channel_type="telegram",
            recipient="12345678",
            body="Hello over telegram",
            task_id="task-tg-test-1",
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
        assert row["channel_type"] == "telegram"
        assert row["recipient"] == "12345678"
        assert row["body_preview"] == "Hello over telegram"
        assert row["task_id"] == "task-tg-test-1"
    _isolate_workspace(run)


# -----------------------------------------------------------------------
# 5. Positioning — append comes after the text-send chunk loop
# -----------------------------------------------------------------------


def test_append_follows_text_send_loop():
    """The append must sit AFTER the chunked `api('sendMessage', ...)`
    loop, inside the same `if clean_text:` gate. Catches a future
    refactor that hoists the append above the gate — would record
    audit rows for file-only deliveries (no text body) with an
    empty body_preview."""
    src = TBRIDGE_PATH.read_text()
    # Find the send_reply function body
    fn_match = re.search(
        r"^def send_reply\([\s\S]+?(?=^def |\Z)",
        src,
        flags=re.MULTILINE,
    )
    assert fn_match, "send_reply function not found"
    body = fn_match.group(0)
    # Within the function, find positions of the send loop and the append
    api_send = body.find('api("sendMessage"')
    append_pos = body.find("outbox_log.append(")
    assert api_send > 0, "api('sendMessage', ...) call not found in send_reply"
    assert append_pos > 0, "outbox_log.append not found in send_reply"
    assert append_pos > api_send, (
        "outbox_log.append must come AFTER the text-send loop — "
        "currently positioned at byte {} before send at byte {}".format(
            append_pos, api_send
        )
    )


def main():
    test_one_append_site_and_it_is_fail_open()
    test_send_reply_accepts_task_id_kwarg()
    test_task_reply_caller_passes_task_id()
    test_append_has_required_kwargs()
    test_channel_type_is_telegram()
    test_round_trip_through_dashboard_reader()
    test_append_follows_text_send_loop()
    print("All telegram-bridge-outbox tests passed.")


if __name__ == "__main__":
    main()
