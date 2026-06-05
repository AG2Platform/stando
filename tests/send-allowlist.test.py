#!/usr/bin/env python3
"""Tests for `src/send_allowlist.py` — the shared file-attachment policy.

`send_allowlist.is_path_sendable` is the single source of truth for the
gate between an agent-emitted `[file: /path]` marker and any outbound
Discord delivery (both the WS-connected `discord-bridge.py` and the
REST-fallback `dm-result.py`). If a future refactor weakens this
function — or if either consumer drifts away from importing it —
exfil paths reopen.

Tests cover three concerns:

  1. Policy semantics (same shape as the pre-extract test in
     `tests/discord-bridge-file-send-allowlist.test.py`, but applied
     directly to the helper module): regular-file gate, allowlist
     match, symlink/path-traversal rejection, fail-closed default.

  2. Drift guards: both consumers (`discord-bridge.py` and
     `dm-result.py`) must reference the SAME object as the helper,
     not their own copies. Identity, not just equality, because a
     copy would equal at module-load time but drift on later edits.

  3. Documented-set guard: the prefix set stays the deliberate four
     entries. A future PR widening it to e.g. `/tmp/` forces an
     explicit test update.
"""

import importlib.util
import os
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

# Materialize a placeholder .env so `_load_token()` succeeds during
# discord-bridge module load.
_channels_env = Path.home() / ".claude" / "channels" / "discord" / ".env"
if not _channels_env.exists():
    _channels_env.parent.mkdir(parents=True, exist_ok=True)
    _channels_env.write_text("DISCORD_BOT_TOKEN=test-token-not-real\n")


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


import send_allowlist  # noqa: E402

# Both consumers — load with module-loader so hyphenated filenames work.
bridge = _load("dbridge", REPO / "src" / "discord-bridge.py")
dm = _load("dm_result", REPO / "src" / "dm-result.py")


# -----------------------------------------------------------------------
# 1. Policy semantics
# -----------------------------------------------------------------------


def test_nonexistent_path_is_not_sendable():
    """Fail-closed on missing files."""
    assert not send_allowlist.is_path_sendable(
        "/tmp/sutando-helper-does-not-exist-99999.png"
    )


def test_directory_is_not_sendable():
    """`os.path.isfile` is the type gate — directories must reject."""
    tmp = Path(tempfile.mkdtemp(prefix="/tmp/sutando-test-helper-dir-"))
    try:
        assert not send_allowlist.is_path_sendable(str(tmp))
    finally:
        tmp.rmdir()


def test_allowed_prefix_match():
    """Files under `/tmp/sutando-*` are explicitly allowed."""
    with tempfile.NamedTemporaryFile(
        prefix="sutando-helper-test-", suffix=".png", dir="/tmp", delete=False
    ) as f:
        f.write(b"x")
        path = f.name
    try:
        assert send_allowlist.is_path_sendable(path), \
            f"expected allowed prefix to match {path}"
    finally:
        os.unlink(path)


def test_arbitrary_path_rejected():
    """A regular file outside the allowlist must reject."""
    assert not send_allowlist.is_path_sendable("/etc/hosts")


def test_symlink_outside_allowed_root_rejected():
    """Symlink-escape regression guard. A symlink at an allowed prefix
    that points at an out-of-list file must reject — `realpath`
    collapses before the prefix comparison."""
    link = Path("/tmp/sutando-helper-symlink-pointer.txt")
    # Target lives at the $HOME root — outside every allowed root/prefix
    # even after the /tmp broadening (feedback 2033745d) — so this still
    # genuinely exercises the realpath-collapse escape guard.
    outside = Path.home() / "sutando-allowlist-escape-test-DELETEME.txt"
    outside.write_text("would be exfil")
    if link.exists() or link.is_symlink():
        link.unlink()
    try:
        os.symlink(outside, link)
        assert not send_allowlist.is_path_sendable(str(link)), (
            f"symlink {link} → {outside} bypassed the allowlist — "
            "realpath collapse is broken"
        )
    finally:
        if link.exists() or link.is_symlink():
            link.unlink()
        outside.unlink()


def test_path_traversal_dotdot_rejected():
    """`..` segments that escape the allowlist must reject. Since /tmp is
    now broadly allowed (feedback 2033745d), the traversal must escape
    /tmp entirely — realpath collapses it to /etc/hosts (a real file
    outside every allowed root) before the prefix check."""
    traversal = "/tmp/sutando-x/../../../etc/hosts"
    assert not send_allowlist.is_path_sendable(traversal), (
        "path traversal via .. bypassed the allowlist — "
        "realpath collapse is broken"
    )


# -----------------------------------------------------------------------
# 2. Drift guards: consumers must reference the helper, not copies
# -----------------------------------------------------------------------


def test_discord_bridge_imports_helper_constants_by_identity():
    """`discord-bridge.py` must reference the SAME tuple object as the
    helper — not a copy. A future PR that re-inlines the constants
    would equal-compare at first but drift on the next edit. Identity
    check is the only honest drift guard."""
    assert bridge.SEND_ALLOWED_ROOTS is send_allowlist.SEND_ALLOWED_ROOTS, (
        "discord-bridge.SEND_ALLOWED_ROOTS is no longer the helper's "
        "object — drift hazard reintroduced."
    )
    assert bridge.SEND_ALLOWED_PREFIXES is send_allowlist.SEND_ALLOWED_PREFIXES, (
        "discord-bridge.SEND_ALLOWED_PREFIXES is no longer the helper's "
        "object — drift hazard reintroduced."
    )
    # The function alias must point at the helper's function. (We
    # check by calling — identity comparison through `is` on
    # functions works in CPython but is implementation-defined for
    # wrapped/decorated functions, so we use a function-call probe.)
    assert bridge._is_path_sendable is send_allowlist.is_path_sendable, (
        "discord-bridge._is_path_sendable is no longer the helper — "
        "drift hazard reintroduced."
    )


def test_dm_result_imports_helper_constants_by_identity():
    """Same drift guard for dm-result.py."""
    assert dm._SEND_ALLOWED_ROOTS is send_allowlist.SEND_ALLOWED_ROOTS, (
        "dm-result._SEND_ALLOWED_ROOTS is no longer the helper's "
        "object — drift hazard reintroduced."
    )
    assert dm._SEND_ALLOWED_PREFIXES is send_allowlist.SEND_ALLOWED_PREFIXES, (
        "dm-result._SEND_ALLOWED_PREFIXES is no longer the helper's "
        "object — drift hazard reintroduced."
    )
    assert dm._is_path_sendable is send_allowlist.is_path_sendable, (
        "dm-result._is_path_sendable is no longer the helper — "
        "drift hazard reintroduced."
    )


# -----------------------------------------------------------------------
# 3. Documented-set guard
# -----------------------------------------------------------------------


def test_allowed_prefixes_are_the_documented_set():
    """Architectural assertion: the allowed prefixes must stay a small,
    deliberate set. Broadened 2026-06 (feedback 2033745d) from the
    `/tmp/sutando-*`/`/tmp/echo-*` prefixes to all of /tmp (both realpath
    forms) so the agent can deliver ad-hoc working files it writes there
    (e.g. /tmp/report.xlsx). This is an INTENTIONAL, owner-scoped beta
    exposure widening — acceptable because (a) bot file-sends are owner-
    driven (non-owner tasks run sandboxed read-only) and (b) the realpath
    sanitizer still blocks symlink/`..` escapes to $HOME + system paths
    (see the escape tests above). Any FURTHER widening (e.g. `/Users/`,
    `/var/folders/`, `/`) must update this set deliberately."""
    documented = {
        "/tmp/",
        "/private/tmp/",
    }
    actual = set(send_allowlist.SEND_ALLOWED_PREFIXES)
    assert actual == documented, (
        f"SEND_ALLOWED_PREFIXES has changed unexpectedly. "
        f"Removed: {documented - actual}, Added: {actual - documented}. "
        "Update this test deliberately to confirm the new exposure is intended."
    )


def main():
    test_nonexistent_path_is_not_sendable()
    test_directory_is_not_sendable()
    test_allowed_prefix_match()
    test_arbitrary_path_rejected()
    test_symlink_outside_allowed_root_rejected()
    test_path_traversal_dotdot_rejected()
    test_discord_bridge_imports_helper_constants_by_identity()
    test_dm_result_imports_helper_constants_by_identity()
    test_allowed_prefixes_are_the_documented_set()
    print("All send_allowlist tests passed.")


if __name__ == "__main__":
    main()
