#!/usr/bin/env python3
"""Tests for `_recover_orphan_sending_files` in all three bridges.

Atomic-claim-by-rename in the proactive-delivery path
(`results/proactive-*.txt` -> `proactive-*.sending`) prevents same-tick
double-deliveries between concurrent poll iterations. But if the bridge
crashes between the rename and the actual delivery — process killed,
SIGKILL, OOM, unhandled exception in the send path — the `.sending`
file sits orphaned in `results/` forever, because no poll iteration
looks at `.sending` suffixes. The owner's proactive notification is
silently dropped until manual intervention.

Phase 5.11 ported OSS's startup-time recovery sweep to discord-bridge +
telegram-bridge. Phase 5.12 extends it to slack-bridge so the bug
class is closed symmetrically across every proactive-delivery surface.

Tests cover four concerns:

  1. Behavior parity — all three bridges have identical recovery
     semantics (`proactive-*.sending` -> `proactive-*.txt`, idempotent,
     fail-open on per-file errors, collision-aware).
  2. Drift guards — all three bridges DEFINE the function AND call it
     from their startup paths. Each consumer must run the sweep before
     poll loops start; a future PR that removes the call but keeps
     the function would silently regress the bug class.
  3. Selectivity — only `proactive-*.sending` files are touched.
     Other suffixes (`.tmp`, `.partial`, no suffix) and other
     prefixes (`task-*.sending`, `welcome-*.sending`) must pass
     through untouched.
  4. Collision safety — if both `<name>.sending` and `<name>.txt`
     exist (operator re-dropped, race), the .sending is left in
     place rather than clobbering the .txt.
"""

import importlib.util
import os
import re
import sys
import tempfile
import types
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "src"))


# Stub `discord` so loading discord-bridge.py doesn't require the lib.
if "discord" not in sys.modules:
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

# Stub `slack_bolt` so loading slack-bridge.py doesn't require the lib.
# Phase 5.12 adds slack to the recovery-sweep family.
if "slack_bolt" not in sys.modules:
    sb = types.ModuleType("slack_bolt")
    sb.App = type("App", (), {"__init__": lambda self, **kw: None,
                                 "event": staticmethod(lambda *a, **k: lambda fn: fn),
                                 "message": staticmethod(lambda *a, **k: lambda fn: fn)})
    sys.modules["slack_bolt"] = sb
    adapter = types.ModuleType("slack_bolt.adapter")
    sys.modules["slack_bolt.adapter"] = adapter
    sm = types.ModuleType("slack_bolt.adapter.socket_mode")
    sm.SocketModeHandler = type(
        "SocketModeHandler", (), {"__init__": lambda self, *a, **k: None}
    )
    sys.modules["slack_bolt.adapter.socket_mode"] = sm

# Materialize a placeholder .env so token loaders succeed.
_channels_env = Path.home() / ".claude" / "channels" / "discord" / ".env"
if not _channels_env.exists():
    _channels_env.parent.mkdir(parents=True, exist_ok=True)
    _channels_env.write_text("DISCORD_BOT_TOKEN=test-token-not-real\n")
os.environ.setdefault("TELEGRAM_BOT_TOKEN", "test-token-not-real")
os.environ.setdefault("SLACK_BOT_TOKEN", "xoxb-test-not-real")
os.environ.setdefault("SLACK_APP_TOKEN", "xapp-test-not-real")


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


tbridge = _load("tbridge", REPO / "src" / "telegram-bridge.py")
dbridge = _load("dbridge", REPO / "src" / "discord-bridge.py")
sbridge = _load("sbridge", REPO / "src" / "slack-bridge.py")


def _isolate_results_dir(module, fn):
    """Redirect `module.RESULTS_DIR` to a fresh tempdir for one test.

    Bridges' module-level `RESULTS_DIR` resolves to the dev's live
    workspace at import time; that directory may contain real
    proactive results we must not touch. This helper swaps in a
    sandboxed dir and restores on exit."""
    original = module.RESULTS_DIR
    tmp = Path(tempfile.mkdtemp(prefix="sutando-orphan-test-"))
    module.RESULTS_DIR = tmp
    try:
        fn(tmp)
    finally:
        module.RESULTS_DIR = original
        # Clean up anything the test created
        for p in tmp.iterdir():
            try:
                p.unlink()
            except OSError:
                pass
        tmp.rmdir()


# -----------------------------------------------------------------------
# 1. Behavior parity between bridges
# -----------------------------------------------------------------------


def _check_basic_recovery(module, label):
    """Drop two orphan .sending files; assert both are renamed to .txt
    and the function returns 2."""
    def run(tmp):
        orphan_a = tmp / "proactive-1234.sending"
        orphan_b = tmp / "proactive-5678.sending"
        orphan_a.write_text("body A")
        orphan_b.write_text("body B")
        n = module._recover_orphan_sending_files()
        assert n == 2, f"{label}: expected 2 recovered, got {n}"
        assert (tmp / "proactive-1234.txt").exists(), \
            f"{label}: proactive-1234.txt missing"
        assert (tmp / "proactive-5678.txt").exists(), \
            f"{label}: proactive-5678.txt missing"
        assert not orphan_a.exists(), f"{label}: orphan A not renamed"
        assert not orphan_b.exists(), f"{label}: orphan B not renamed"
    _isolate_results_dir(module, run)


def test_telegram_recovers_orphan_sending_files():
    _check_basic_recovery(tbridge, "telegram")


def test_discord_recovers_orphan_sending_files():
    _check_basic_recovery(dbridge, "discord")


def test_slack_recovers_orphan_sending_files():
    _check_basic_recovery(sbridge, "slack")


# -----------------------------------------------------------------------
# 2. Drift guards — both bridges DEFINE the function AND call it
# -----------------------------------------------------------------------


def test_all_bridges_define_recovery_function():
    """Bug class is closed only if the function exists in all three
    bridges. Catch a future PR that drops one side."""
    assert callable(getattr(tbridge, "_recover_orphan_sending_files", None)), \
        "telegram-bridge.py missing _recover_orphan_sending_files"
    assert callable(getattr(dbridge, "_recover_orphan_sending_files", None)), \
        "discord-bridge.py missing _recover_orphan_sending_files"
    assert callable(getattr(sbridge, "_recover_orphan_sending_files", None)), \
        "slack-bridge.py missing _recover_orphan_sending_files"


def test_all_bridges_call_recovery_at_startup():
    """The function is useless unless invoked. Verify each bridge
    calls it from its startup path.

    Structural source check (not runtime) — all startup paths run
    only when the process is launched, which we don't do in tests.
    The regex pins that a bare `_recover_orphan_sending_files()`
    call exists in `main()` (telegram, slack) and `on_ready()`
    (discord)."""
    tsrc = (REPO / "src" / "telegram-bridge.py").read_text()
    dsrc = (REPO / "src" / "discord-bridge.py").read_text()
    ssrc = (REPO / "src" / "slack-bridge.py").read_text()

    # Telegram: call inside main()
    main_block = re.search(
        r"^def main\(\)[\s\S]+?(?=^def |\Z)",
        tsrc,
        flags=re.MULTILINE,
    )
    assert main_block, "telegram-bridge.py main() not found"
    assert "_recover_orphan_sending_files(" in main_block.group(0), (
        "telegram-bridge.py main() does NOT call "
        "_recover_orphan_sending_files at startup — drift hazard"
    )

    # Discord: call inside on_ready()
    on_ready_block = re.search(
        r"^async def on_ready\(\)[\s\S]+?(?=^@client\.event|^def |\Z)",
        dsrc,
        flags=re.MULTILINE,
    )
    assert on_ready_block, "discord-bridge.py on_ready() not found"
    assert "_recover_orphan_sending_files(" in on_ready_block.group(0), (
        "discord-bridge.py on_ready() does NOT call "
        "_recover_orphan_sending_files at startup — drift hazard"
    )

    # Slack: call inside main()
    slack_main_block = re.search(
        r"^def main\(\)[\s\S]+?(?=^def |\Z)",
        ssrc,
        flags=re.MULTILINE,
    )
    assert slack_main_block, "slack-bridge.py main() not found"
    assert "_recover_orphan_sending_files(" in slack_main_block.group(0), (
        "slack-bridge.py main() does NOT call "
        "_recover_orphan_sending_files at startup — drift hazard"
    )


# -----------------------------------------------------------------------
# 3. Selectivity — only `proactive-*.sending` is touched
# -----------------------------------------------------------------------


def _check_selectivity(module, label):
    """Drop a mix of files that look adjacent but shouldn't be
    recovered. Confirm the function leaves them alone."""
    def run(tmp):
        # SHOULD be recovered (real orphan)
        orphan = tmp / "proactive-99.sending"
        orphan.write_text("orphan body")
        # SHOULD NOT be recovered:
        # - wrong prefix (task results aren't proactive)
        task_sending = tmp / "task-abc.sending"
        task_sending.write_text("task body")
        # - wrong suffix (in-flight atomic-write temp)
        proactive_tmp = tmp / "proactive-x.txt.tmp"
        proactive_tmp.write_text("in-flight body")
        # - already a .txt (caller delivers from this)
        proactive_txt = tmp / "proactive-1.txt"
        proactive_txt.write_text("pending body")
        # - subdirs are pure noise here, but just in case
        subdir = tmp / "subdir"
        subdir.mkdir()
        n = module._recover_orphan_sending_files()
        assert n == 1, f"{label}: expected 1 recovered, got {n}"
        # The real orphan should be renamed
        assert (tmp / "proactive-99.txt").exists(), \
            f"{label}: real orphan not renamed"
        assert not orphan.exists()
        # Other files must remain untouched
        assert task_sending.exists(), \
            f"{label}: task-*.sending was incorrectly recovered — too broad"
        assert proactive_tmp.exists(), \
            f"{label}: proactive-*.txt.tmp was incorrectly recovered"
        assert proactive_txt.exists() and proactive_txt.read_text() == "pending body", \
            f"{label}: existing .txt was clobbered"
        # Cleanup subdir (helper would skip it; we have to remove it
        # before _isolate_results_dir's rmdir).
        subdir.rmdir()
    _isolate_results_dir(module, run)


def test_telegram_recovery_is_selective():
    _check_selectivity(tbridge, "telegram")


def test_discord_recovery_is_selective():
    _check_selectivity(dbridge, "discord")


def test_slack_recovery_is_selective():
    _check_selectivity(sbridge, "slack")


# -----------------------------------------------------------------------
# 4. Collision safety — leave both in place if .txt already exists
# -----------------------------------------------------------------------


def _check_collision_safety(module, label):
    """If `proactive-X.sending` and `proactive-X.txt` both exist (the
    atomic-claim invariant says they shouldn't, but defensive
    startup), the function must NOT clobber the .txt. The .sending
    file is left as-is for operator intervention."""
    def run(tmp):
        orphan = tmp / "proactive-collision.sending"
        existing = tmp / "proactive-collision.txt"
        orphan.write_text("orphan body")
        existing.write_text("would-be-clobbered")
        n = module._recover_orphan_sending_files()
        assert n == 0, f"{label}: collision should NOT count as recovered"
        assert orphan.exists(), f"{label}: orphan disappeared during collision"
        assert existing.read_text() == "would-be-clobbered", (
            f"{label}: .txt was clobbered by collision"
        )
    _isolate_results_dir(module, run)


def test_telegram_recovery_collision_safe():
    _check_collision_safety(tbridge, "telegram")


def test_discord_recovery_collision_safe():
    _check_collision_safety(dbridge, "discord")


def test_slack_recovery_collision_safe():
    _check_collision_safety(sbridge, "slack")


# -----------------------------------------------------------------------
# 5. Idempotency — running twice is safe + missing dir is safe
# -----------------------------------------------------------------------


def test_recovery_idempotent_and_dir_missing_safe():
    """Second call with no orphans returns 0. Missing RESULTS_DIR
    also returns 0 (bridge can boot before any results have been
    materialized)."""
    def run(tmp):
        # First call: empty dir, returns 0
        assert tbridge._recover_orphan_sending_files() == 0
        assert dbridge._recover_orphan_sending_files() == 0
        assert sbridge._recover_orphan_sending_files() == 0
        # Drop one orphan, first call recovers it
        (tmp / "proactive-9.sending").write_text("x")
        assert tbridge._recover_orphan_sending_files() == 1
        # Second call: nothing to do
        assert tbridge._recover_orphan_sending_files() == 0
        # And the same applies to discord + slack (since we just
        # renamed it, there are no more .sending files)
        assert dbridge._recover_orphan_sending_files() == 0
        assert sbridge._recover_orphan_sending_files() == 0
        # Clean up the .txt before _isolate_results_dir rmdirs the tmp
        (tmp / "proactive-9.txt").unlink()
    _isolate_results_dir(tbridge, run)

    # Missing dir branch
    original_t = tbridge.RESULTS_DIR
    original_d = dbridge.RESULTS_DIR
    original_s = sbridge.RESULTS_DIR
    missing = Path("/tmp/sutando-orphan-test-missing-dir-99999")
    tbridge.RESULTS_DIR = missing
    dbridge.RESULTS_DIR = missing
    sbridge.RESULTS_DIR = missing
    try:
        assert tbridge._recover_orphan_sending_files() == 0
        assert dbridge._recover_orphan_sending_files() == 0
        assert sbridge._recover_orphan_sending_files() == 0
    finally:
        tbridge.RESULTS_DIR = original_t
        dbridge.RESULTS_DIR = original_d
        sbridge.RESULTS_DIR = original_s


def main():
    test_telegram_recovers_orphan_sending_files()
    test_discord_recovers_orphan_sending_files()
    test_slack_recovers_orphan_sending_files()
    test_all_bridges_define_recovery_function()
    test_all_bridges_call_recovery_at_startup()
    test_telegram_recovery_is_selective()
    test_discord_recovery_is_selective()
    test_slack_recovery_is_selective()
    test_telegram_recovery_collision_safe()
    test_discord_recovery_collision_safe()
    test_slack_recovery_collision_safe()
    test_recovery_idempotent_and_dir_missing_safe()
    print("All bridge-orphan-sending-recovery tests passed.")


if __name__ == "__main__":
    main()
