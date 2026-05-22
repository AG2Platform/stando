#!/usr/bin/env python3
"""Unit tests for pending_replies persistence in src/discord-bridge.py.

Covers two recent fix-PR motivations:
- #597: age out pending_replies entries older than 7 days. The pre-fix
  store leaked forever for tasks the agent never wrote a result file
  for (silent dedup / crash / ignored as noise). Caught with 375
  entries accumulated since 2026-04-12, 124 of them >7d old.
- #599: atomic write via tmp+replace, so a mid-write crash doesn't
  truncate the live file.

Tests target `_atomic_write_pending_replies` and
`load_pending_replies_from_disk` because they're pure-ish (file I/O
only, no Discord client) and carry the load-bearing invariants.

Mirrors tests/discord-chunker.test.py conventions.
"""

import importlib.util
import json
import os
import sys
import tempfile
import time
import types
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

try:
    import discord  # noqa: F401
except ImportError:
    stub = types.ModuleType("discord")
    stub.Intents = type(
        "Intents",
        (),
        {"default": staticmethod(lambda: type("I", (), {"message_content": False})())},
    )
    stub.Client = type(
        "Client",
        (),
        {"__init__": lambda self, **kw: None, "event": staticmethod(lambda fn: fn)},
    )
    stub.File = type("File", (), {})
    stub.Message = type("Message", (), {})
    sys.modules["discord"] = stub

_channels_env = Path.home() / ".claude" / "channels" / "discord" / ".env"
if not _channels_env.exists():
    _channels_env.parent.mkdir(parents=True, exist_ok=True)
    _channels_env.write_text("DISCORD_BOT_TOKEN=test-token-not-real\n")


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


bridge = _load("dbridge", REPO / "src" / "discord-bridge.py")


def _with_temp_pending_file(fn):
    """Run `fn(path)` with `PENDING_REPLIES_FILE` rebound to a fresh
    temp file. Restores the original after the case completes."""

    def wrapper():
        original = bridge.PENDING_REPLIES_FILE
        tmpdir = tempfile.mkdtemp(prefix="sutando-pending-test-")
        path = Path(tmpdir) / "pending.json"
        bridge.PENDING_REPLIES_FILE = path
        try:
            fn(path)
        finally:
            bridge.PENDING_REPLIES_FILE = original
            for p in Path(tmpdir).glob("*"):
                p.unlink()
            os.rmdir(tmpdir)

    return wrapper


@_with_temp_pending_file
def test_atomic_write_produces_valid_json(path):
    """The writer goes via tmp + rename. After the call returns, the
    final file must hold parseable JSON matching the input dict —
    no partial write, no `.tmp` leftover under the live path."""
    data = {"task-1": "111", "task-2": "222"}
    bridge._atomic_write_pending_replies(data)
    assert path.exists()
    assert json.loads(path.read_text()) == data
    # No `.tmp` sibling should linger.
    tmp_sibling = path.with_suffix(".json.tmp")
    assert not tmp_sibling.exists(), f"leftover tmp file: {tmp_sibling}"


@_with_temp_pending_file
def test_atomic_write_handles_empty_dict(path):
    """Empty dict still produces valid JSON (`{}`), not a missing file
    or a zero-byte file. Callers that ask "is anything pending?" by
    reading the file expect JSON."""
    bridge._atomic_write_pending_replies({})
    assert path.exists()
    assert json.loads(path.read_text()) == {}


@_with_temp_pending_file
def test_atomic_write_swallows_errors_silently(path):
    """`_atomic_write_pending_replies` is documented as "Silent on any
    failure" — telemetry/state persistence must never break the bridge.
    Verify the swallow by handing in a value that can't serialize."""
    # `set` is not JSON-serializable
    unserializable = {"task-1": {"channel": set()}}
    # Must not raise.
    bridge._atomic_write_pending_replies(unserializable)
    # And must not leave a corrupt file behind: if json.dumps blew up
    # before tmp.write_text completed, the LIVE file should still be
    # whatever it was (in this case, absent).
    if path.exists():
        # If the implementation chose to write a partial file, that's
        # a bug — assert that the file is still valid JSON.
        json.loads(path.read_text())  # raises if corrupt


@_with_temp_pending_file
def test_load_returns_empty_dict_when_file_missing(path):
    """Fresh install / first boot: no file yet. Loader must return an
    empty dict (the type pending_replies expects), not None."""
    assert not path.exists()
    got = bridge.load_pending_replies_from_disk()
    assert got == {}


@_with_temp_pending_file
def test_load_returns_empty_dict_on_corrupt_json(path):
    """Fail-closed on a corrupt file. A bad file must NOT prevent the
    bridge from booting — the `try/except` returns {} so the bridge
    starts with zero pending replies rather than crashing in startup."""
    path.write_text("{ this is not json")
    got = bridge.load_pending_replies_from_disk()
    assert got == {}


@_with_temp_pending_file
def test_load_preserves_recent_entries(path):
    """Entries within the 7-day window survive a load. Uses millisecond
    timestamps inside the task_id (the documented format)."""
    now_ms = int(time.time() * 1000)
    one_day_ago_ms = now_ms - (1 * 86400 * 1000)
    data = {
        f"task-{now_ms}": "111",
        f"task-{one_day_ago_ms}": "222",
    }
    path.write_text(json.dumps(data))
    got = bridge.load_pending_replies_from_disk()
    assert got == data, f"expected all entries to survive, got {got}"


@_with_temp_pending_file
def test_load_ages_out_stale_entries(path):
    """Entries older than 7 days are removed during load. Pre-#597 the
    store grew unboundedly; this is the cap."""
    now_ms = int(time.time() * 1000)
    eight_days_ago_ms = now_ms - (8 * 86400 * 1000)
    fresh_ms = now_ms - (60 * 1000)  # 1 minute old
    data = {
        f"task-{eight_days_ago_ms}": "stale-channel",
        f"task-{fresh_ms}": "fresh-channel",
    }
    path.write_text(json.dumps(data))
    got = bridge.load_pending_replies_from_disk()
    assert f"task-{fresh_ms}" in got
    assert f"task-{eight_days_ago_ms}" not in got, "stale entry survived age-out"
    # The aged-out entries should be rewritten back to disk (so the
    # next load doesn't have to repeat the work).
    on_disk = json.loads(path.read_text())
    assert f"task-{eight_days_ago_ms}" not in on_disk, "age-out not persisted"


@_with_temp_pending_file
def test_load_preserves_malformed_task_id_with_unparseable_ts(path):
    """If task_id doesn't parse as `task-<int>`, the loader can't
    decide its age. Per code comment: "leave it; cap protects the
    simple case". Pin that behavior — surprise removal of unknown-
    format task IDs would break agents that use a custom task_id
    convention."""
    data = {
        "task-not-an-int": "ch-1",
        "weird-format": "ch-2",
        "task-": "ch-3",  # empty number after dash
    }
    path.write_text(json.dumps(data))
    got = bridge.load_pending_replies_from_disk()
    # All malformed entries survive.
    assert got == data, f"unexpected age-out of malformed task_ids: {got}"


@_with_temp_pending_file
def test_load_handles_boundary_age_exactly_7_days(path):
    """Edge: exactly 7 days. Code uses `>` not `>=`, so exactly-7d
    survives by one tick. Confirm to nail down the boundary semantics."""
    now_ms = int(time.time() * 1000)
    exactly_7d_ago_ms = now_ms - (7 * 86400 * 1000)
    just_over_7d_ms = now_ms - (7 * 86400 * 1000) - 1  # 1ms older
    data = {
        f"task-{exactly_7d_ago_ms}": "boundary-channel",
        f"task-{just_over_7d_ms}": "stale-channel",
    }
    path.write_text(json.dumps(data))
    got = bridge.load_pending_replies_from_disk()
    assert f"task-{exactly_7d_ago_ms}" in got, "boundary entry incorrectly aged out"
    assert f"task-{just_over_7d_ms}" not in got, "stale entry survived"


@_with_temp_pending_file
def test_round_trip_write_then_load(path):
    """End-to-end: write a dict, load it back. Recent entries should
    round-trip identically (no quoting/casting drift)."""
    now_ms = int(time.time() * 1000)
    data = {f"task-{now_ms}": "channel-12345"}
    bridge._atomic_write_pending_replies(data)
    got = bridge.load_pending_replies_from_disk()
    assert got == data


def main():
    test_atomic_write_produces_valid_json()
    test_atomic_write_handles_empty_dict()
    test_atomic_write_swallows_errors_silently()
    test_load_returns_empty_dict_when_file_missing()
    test_load_returns_empty_dict_on_corrupt_json()
    test_load_preserves_recent_entries()
    test_load_ages_out_stale_entries()
    test_load_preserves_malformed_task_id_with_unparseable_ts()
    test_load_handles_boundary_age_exactly_7_days()
    test_round_trip_write_then_load()
    print("All pending_replies persistence tests passed.")


if __name__ == "__main__":
    main()
