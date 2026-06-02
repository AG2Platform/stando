#!/usr/bin/env python3
"""Tests for slack-bridge's in-memory access cache (Phase 5.13 / #899).

Bug class:
    ~/.claude/channels/slack/access.json can be deleted out from under
    the bridge — Sutando.app's Settings UI does this when the user
    revokes access, but it can also happen via an accidental rm or a
    sync conflict. Before this PR, the next inbound Slack DM would
    see ACCESS_FILE.exists() == False, fall straight into TOFU, and
    silently overwrite the prior tofuOwner / tierMap / manually-added
    allowFrom entries with a fresh one-user payload — effectively
    re-onboarding whoever sent the next message as the new owner.

Fix:
    Mirror access.json into _access_cache on every successful read +
    on TOFU write. Before TOFU, if the file is missing but the cache
    holds a valid prior state (tofuOwner present), restore the file
    from cache. Genuine first-time TOFU still proceeds when the cache
    is empty.

Tests cover six concerns:

  1. `load_allowed` populates `_access_cache` on successful read,
     including mtime.
  2. `load_tier_map` short-circuits to the cache when mtime matches
     the on-disk file — proves the fast path is actually fast.
  3. `load_tier_map` falls back to re-read when mtime differs
     (file modified externally) — proves the slow path still works.
  4. `_restore_access_from_cache` writes the cached payload back to
     ACCESS_FILE with 0o600 perms, only when cache has tofuOwner.
  5. `tofu_onboard` restores from cache instead of re-TOFUing when
     ACCESS_FILE is externally deleted but cache holds prior state
     — the #899 regression that motivated the cache.
  6. `tofu_onboard` falls through to genuine TOFU when both file
     AND cache are empty (fresh install case).

Plus drift guards:
  - Module exposes _access_cache, _access_cache_mtime, _access_cache_lock
  - load_allowed source contains _update_access_cache call
  - tofu_onboard source contains _restore_access_from_cache check

Run: python3 tests/slack-bridge-access-cache.test.py
"""

import importlib.util
import json
import os
import re
import stat
import sys
import tempfile
import threading
import time
import types
from pathlib import Path


REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "src"))


def _ensure_slack_bolt_stub():
    """slack-bridge.py calls sys.exit(1) if slack_bolt isn't importable.
    Stub it before module import (same pattern as slack-bridge-tier-map.test.py)."""
    if "slack_bolt" not in sys.modules:
        stub = types.ModuleType("slack_bolt")
        class _StubApp:
            def __init__(self, *a, **kw):
                self.client = types.SimpleNamespace()
            def event(self, _name):
                return lambda fn: fn
        stub.App = _StubApp
        sys.modules["slack_bolt"] = stub
        adapter = types.ModuleType("slack_bolt.adapter")
        sys.modules["slack_bolt.adapter"] = adapter
        sm = types.ModuleType("slack_bolt.adapter.socket_mode")
        sm.SocketModeHandler = object
        sys.modules["slack_bolt.adapter.socket_mode"] = sm


def _load_bridge():
    os.environ.setdefault("SLACK_BOT_TOKEN", "xoxb-test-not-real")
    os.environ.setdefault("SLACK_APP_TOKEN", "xapp-test-not-real")
    os.environ.setdefault(
        "SUTANDO_WORKSPACE", tempfile.mkdtemp(prefix="sutando-test-cache-")
    )
    _ensure_slack_bolt_stub()
    spec = importlib.util.spec_from_file_location(
        "sbridge_cache", REPO / "src" / "slack-bridge.py"
    )
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


sbridge = _load_bridge()


def _isolate_access_file(fn):
    """Redirect `sbridge.ACCESS_FILE` to a fresh tempdir and reset the
    in-memory cache before running fn. Restores everything on exit.

    The bridge module's ACCESS_FILE resolves to the developer's live
    ~/.claude/channels/slack/access.json at import time; tests must
    not poke that path."""
    original_file = sbridge.ACCESS_FILE
    original_cache = sbridge._access_cache
    original_mtime = sbridge._access_cache_mtime
    tmp_root = Path(tempfile.mkdtemp(prefix="sutando-access-cache-test-"))
    sbridge.ACCESS_FILE = tmp_root / "access.json"
    # Reset module-level cache state for a clean baseline per test.
    sbridge._access_cache = None
    sbridge._access_cache_mtime = 0.0
    try:
        fn(tmp_root)
    finally:
        sbridge.ACCESS_FILE = original_file
        sbridge._access_cache = original_cache
        sbridge._access_cache_mtime = original_mtime
        # Best-effort cleanup
        for p in tmp_root.iterdir():
            try:
                p.unlink()
            except OSError:
                pass
        try:
            tmp_root.rmdir()
        except OSError:
            pass


# -----------------------------------------------------------------------
# 1. load_allowed populates the cache
# -----------------------------------------------------------------------


def test_load_allowed_populates_cache():
    def run(root):
        payload = {
            "allowFrom": ["Uowner", "Ufriend"],
            "tofuOwner": "Uowner",
            "tierMap": {"Ufriend": "team"},
        }
        sbridge.ACCESS_FILE.write_text(json.dumps(payload))
        before_mtime = sbridge._access_cache_mtime
        assert before_mtime == 0.0, "baseline should be 0"
        result = sbridge.load_allowed()
        assert result == {"Uowner", "Ufriend"}, f"got {result!r}"
        # Cache should now mirror the file
        assert sbridge._access_cache is not None, "cache not populated"
        assert sbridge._access_cache["tofuOwner"] == "Uowner"
        assert sbridge._access_cache["tierMap"] == {"Ufriend": "team"}
        # mtime should match the file's mtime exactly
        assert sbridge._access_cache_mtime == sbridge.ACCESS_FILE.stat().st_mtime
    _isolate_access_file(run)


# -----------------------------------------------------------------------
# 2. load_tier_map short-circuits to cache when mtime matches
# -----------------------------------------------------------------------


def test_load_tier_map_uses_cache_when_mtime_matches():
    def run(root):
        payload = {"allowFrom": ["U1"], "tierMap": {"U1": "team"}}
        sbridge.ACCESS_FILE.write_text(json.dumps(payload))
        # Prime the cache
        sbridge.load_allowed()
        cache_mtime = sbridge._access_cache_mtime
        assert cache_mtime > 0
        # Mutate the file's _content_ but keep mtime — write directly and
        # then restore mtime via os.utime. (We deliberately diverge cache
        # from disk to prove the fast path returns the cache, not disk.)
        sbridge.ACCESS_FILE.write_text(json.dumps({"tierMap": {"U1": "other"}}))
        os.utime(sbridge.ACCESS_FILE, (cache_mtime, cache_mtime))
        tm = sbridge.load_tier_map()
        # Cache wins because mtime matches → still {"U1": "team"}
        assert tm == {"U1": "team"}, (
            f"expected cache hit, got disk read result {tm!r}"
        )
    _isolate_access_file(run)


# -----------------------------------------------------------------------
# 3. load_tier_map re-reads when mtime differs
# -----------------------------------------------------------------------


def test_load_tier_map_rereads_when_mtime_differs():
    def run(root):
        sbridge.ACCESS_FILE.write_text(json.dumps(
            {"allowFrom": ["U1"], "tierMap": {"U1": "team"}}
        ))
        sbridge.load_allowed()
        # Sleep just enough to guarantee a distinct mtime tick on coarse
        # filesystems (HFS+ has 1-second resolution on older macOS).
        time.sleep(1.05)
        sbridge.ACCESS_FILE.write_text(json.dumps(
            {"allowFrom": ["U1"], "tierMap": {"U1": "other"}}
        ))
        tm = sbridge.load_tier_map()
        assert tm == {"U1": "other"}, (
            f"expected disk re-read after mtime change, got {tm!r}"
        )
        # And the cache should now reflect the new payload
        assert sbridge._access_cache["tierMap"] == {"U1": "other"}
    _isolate_access_file(run)


# -----------------------------------------------------------------------
# 4. _restore_access_from_cache writes cache back at 0o600, only with tofuOwner
# -----------------------------------------------------------------------


def test_restore_writes_cache_back_with_secure_perms():
    def run(root):
        payload = {
            "allowFrom": ["Uowner"],
            "tofuOwner": "Uowner",
            "tofuOnboardedAt": 1234567890,
        }
        # Manually prime the cache without writing to disk
        sbridge._access_cache = payload
        sbridge._access_cache_mtime = 0.0
        assert not sbridge.ACCESS_FILE.exists()
        restored = sbridge._restore_access_from_cache()
        assert restored is True
        assert sbridge.ACCESS_FILE.exists()
        # Same payload round-trips
        on_disk = json.loads(sbridge.ACCESS_FILE.read_text())
        assert on_disk == payload
        # File perms must be 0o600 — owner's user ID is sensitive
        mode = stat.S_IMODE(os.stat(sbridge.ACCESS_FILE).st_mode)
        assert mode == 0o600, f"expected 0o600 perms, got {oct(mode)}"
    _isolate_access_file(run)


def test_restore_refuses_when_cache_has_no_tofu_owner():
    def run(root):
        # Cache populated but without tofuOwner — should NOT restore.
        # This guards against re-creating a corrupt or pre-TOFU file
        # that would lock the bridge into a broken state.
        sbridge._access_cache = {"allowFrom": [], "tierMap": {}}
        sbridge._access_cache_mtime = 0.0
        restored = sbridge._restore_access_from_cache()
        assert restored is False
        assert not sbridge.ACCESS_FILE.exists(), (
            "must not create file when cache lacks tofuOwner"
        )
    _isolate_access_file(run)


def test_restore_returns_false_when_cache_empty():
    def run(root):
        sbridge._access_cache = None
        restored = sbridge._restore_access_from_cache()
        assert restored is False
        assert not sbridge.ACCESS_FILE.exists()
    _isolate_access_file(run)


# -----------------------------------------------------------------------
# 5. tofu_onboard restores from cache instead of re-TOFUing (#899)
# -----------------------------------------------------------------------


def test_tofu_onboard_recovers_from_external_deletion():
    """The #899 scenario: user has already been TOFU'd, the access.json
    was externally deleted (Settings UI or accidental rm), and a new
    Slack DM arrives. Without the cache, the bridge would TOFU the
    new sender and silently destroy the prior owner. With the cache,
    the file is restored from memory and the prior owner stays the
    rightful owner."""
    def run(root):
        prior_payload = {
            "allowFrom": ["Uoriginal_owner"],
            "tofuOwner": "Uoriginal_owner",
            "tierMap": {"Uoriginal_owner": "owner"},
            "tofuOnboardedAt": 1234567890,
            "tofuOnboardedUsername": "alice",
        }
        # Prime cache as if a prior session had loaded the file
        sbridge._access_cache = prior_payload
        sbridge._access_cache_mtime = 0.0
        # External deletion happens here — no file on disk
        assert not sbridge.ACCESS_FILE.exists()
        # New, unknown user sends a DM → tofu_onboard called with their ID
        result = sbridge.tofu_onboard("Uattacker_or_innocent_bystander", "bob")
        # The file must be restored with the ORIGINAL owner, not the new one
        assert sbridge.ACCESS_FILE.exists(), "cache restore failed to write file"
        on_disk = json.loads(sbridge.ACCESS_FILE.read_text())
        assert on_disk["tofuOwner"] == "Uoriginal_owner", (
            f"#899 regression: original owner overwritten, got {on_disk['tofuOwner']!r}"
        )
        assert "Uattacker_or_innocent_bystander" not in on_disk["allowFrom"], (
            "#899 regression: new sender silently added to allowFrom"
        )
        # tofu_onboard's return value must be the restored allowFrom set,
        # not a fresh {new_user_id}
        assert result == {"Uoriginal_owner"}, (
            f"tofu_onboard returned wrong set: {result!r}"
        )
    _isolate_access_file(run)


# -----------------------------------------------------------------------
# 6. Genuine first-time TOFU still works when cache is empty
# -----------------------------------------------------------------------


def test_tofu_onboard_genuine_first_time_when_cache_empty():
    def run(root):
        sbridge._access_cache = None
        sbridge._access_cache_mtime = 0.0
        assert not sbridge.ACCESS_FILE.exists()
        result = sbridge.tofu_onboard("Ufirstuser", "first")
        # File written, sender onboarded as owner
        assert sbridge.ACCESS_FILE.exists()
        on_disk = json.loads(sbridge.ACCESS_FILE.read_text())
        assert on_disk["tofuOwner"] == "Ufirstuser"
        assert on_disk["allowFrom"] == ["Ufirstuser"]
        assert on_disk["tofuOnboardedUsername"] == "first"
        assert result == {"Ufirstuser"}
        # And the cache should now reflect the new payload
        assert sbridge._access_cache is not None
        assert sbridge._access_cache["tofuOwner"] == "Ufirstuser"
        # Perms must be 0o600 — same guard as restore path
        mode = stat.S_IMODE(os.stat(sbridge.ACCESS_FILE).st_mode)
        assert mode == 0o600, f"expected 0o600 perms after TOFU, got {oct(mode)}"
    _isolate_access_file(run)


# -----------------------------------------------------------------------
# Drift guards — module surface + source structural checks
# -----------------------------------------------------------------------


def test_module_exposes_cache_surface():
    """Catch a future PR that drops the cache state or the helper
    functions. All four must be present and callable / accessible."""
    assert hasattr(sbridge, "_access_cache"), "_access_cache attr missing"
    assert hasattr(sbridge, "_access_cache_mtime"), "_access_cache_mtime attr missing"
    assert hasattr(sbridge, "_access_cache_lock"), "_access_cache_lock attr missing"
    assert isinstance(sbridge._access_cache_lock, type(threading.Lock())), (
        "_access_cache_lock is not a threading.Lock instance"
    )
    assert callable(sbridge._update_access_cache)
    assert callable(sbridge._restore_access_from_cache)


def test_source_wires_cache_into_call_sites():
    """Structural guard: the cache is useless unless the three load /
    TOFU functions actually call into it. A future PR that drops
    `_update_access_cache(data)` from `load_allowed` would silently
    regress #899."""
    src = (REPO / "src" / "slack-bridge.py").read_text()

    def block(fn_name: str) -> str:
        m = re.search(
            rf"^def {re.escape(fn_name)}\([\s\S]+?(?=^def |\Z)",
            src,
            flags=re.MULTILINE,
        )
        assert m, f"{fn_name} not found in slack-bridge.py"
        return m.group(0)

    # load_allowed must update the cache after a successful read
    la = block("load_allowed")
    assert "_update_access_cache(" in la, (
        "load_allowed() does NOT call _update_access_cache — drift hazard"
    )

    # load_tier_map must consult the cache (read path) AND update on miss
    ltm = block("load_tier_map")
    assert "_access_cache" in ltm, (
        "load_tier_map() does NOT consult _access_cache — drift hazard"
    )
    assert "_update_access_cache(" in ltm, (
        "load_tier_map() does NOT update _access_cache on miss — drift hazard"
    )

    # tofu_onboard must attempt cache restore before genuine TOFU
    tofu = block("tofu_onboard")
    assert "_restore_access_from_cache(" in tofu, (
        "tofu_onboard() does NOT attempt _restore_access_from_cache — "
        "regression of #899"
    )
    assert "_update_access_cache(" in tofu, (
        "tofu_onboard() does NOT update _access_cache after writing payload"
    )


def test_main_primes_access_cache_at_startup():
    """The cache machinery only protects against external deletion if
    it's populated. Across a bridge restart with no prior in-process
    state, the cache is None until the first successful `load_allowed`
    call. If that first call happens to be the access check for an
    inbound DM that arrives AFTER an external deletion, the cache is
    still None — `_restore_access_from_cache` returns False — and
    `tofu_onboard` silently overwrites the prior owner.

    `main()` must call `load_allowed()` immediately after the orphan
    recovery sweep (and before any threads spin up) to prime the
    cache from disk while access.json is still intact. Phase 5.14
    of the OSS → private sync ports this 1-line pairing that was
    missed in the Phase 5.13 cache port."""
    src = (REPO / "src" / "slack-bridge.py").read_text()
    main_block_m = re.search(
        r"^def main\(\)[\s\S]+?(?=^def |\Z)",
        src,
        flags=re.MULTILINE,
    )
    assert main_block_m, "slack-bridge.py main() not found"
    main_block = main_block_m.group(0)
    assert "load_allowed()" in main_block, (
        "main() does NOT call load_allowed() to prime the cache — "
        "regresses the #899 fix across bridge restarts"
    )
    # And it must come AFTER the orphan sweep so the bridge isn't
    # blocked on a network/IO error during recovery.
    recovery_idx = main_block.find("_recover_orphan_sending_files(")
    prime_idx = main_block.find("load_allowed()")
    assert recovery_idx >= 0, "main() missing _recover_orphan_sending_files() call"
    assert prime_idx > recovery_idx, (
        "load_allowed() priming must come AFTER _recover_orphan_sending_files() "
        "(see OSS slack-bridge main() ordering)"
    )


def main():
    test_load_allowed_populates_cache()
    test_load_tier_map_uses_cache_when_mtime_matches()
    test_load_tier_map_rereads_when_mtime_differs()
    test_restore_writes_cache_back_with_secure_perms()
    test_restore_refuses_when_cache_has_no_tofu_owner()
    test_restore_returns_false_when_cache_empty()
    test_tofu_onboard_recovers_from_external_deletion()
    test_tofu_onboard_genuine_first_time_when_cache_empty()
    test_module_exposes_cache_surface()
    test_source_wires_cache_into_call_sites()
    test_main_primes_access_cache_at_startup()
    print("All slack-bridge-access-cache tests passed.")


if __name__ == "__main__":
    main()
