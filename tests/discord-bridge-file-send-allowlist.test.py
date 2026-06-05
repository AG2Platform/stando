#!/usr/bin/env python3
"""Security-relevant tests for `_is_path_sendable` in src/discord-bridge.py.

`_is_path_sendable` is the gate between an agent-emitted `[file: /path]`
marker and `await channel.send(file=discord.File(fpath))`. If it's
permissive, an agent that's been prompt-injected — or a confused result
file — can exfiltrate arbitrary files (SSH keys, .env, browser cookies)
to Discord. PR #494 added the allowlist; PR #496 hardened it; this
test pins both improvements so a future refactor doesn't regress them
into a path-traversal/symlink-escape primitive.

Mirrors tests/discord-chunker.test.py conventions.
"""

import importlib.util
import os
import sys
import tempfile
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
is_sendable = bridge._is_path_sendable


def _make_file(path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("x")
    return path


def test_nonexistent_path_is_not_sendable():
    """Fail-closed on missing files. Pre-check before any allowlist match,
    so an attacker can't manipulate a not-yet-existing path."""
    assert not is_sendable("/tmp/sutando-does-not-exist-12345.png")


def test_directory_is_not_sendable():
    """`os.path.isfile` is the type gate — directories must reject, even
    if they sit under an allowed root. Otherwise `discord.File(dir)`
    fails downstream with a confusing error."""
    tmp = Path(tempfile.mkdtemp(prefix="/tmp/sutando-test-dir-"))
    try:
        assert not is_sendable(str(tmp))
    finally:
        tmp.rmdir()


def test_allowed_prefix_match():
    """Files under `/tmp/sutando-*` are explicitly allowed. This is the
    standard path for screenshots, generated assets, etc."""
    with tempfile.NamedTemporaryFile(
        prefix="sutando-test-", suffix=".png", dir="/tmp", delete=False
    ) as f:
        f.write(b"x")
        path = f.name
    try:
        assert is_sendable(path), f"expected allowed prefix to match {path}"
    finally:
        os.unlink(path)


def test_disallowed_prefix_rejected():
    """A real file outside every allowed root/prefix must reject. Since
    /tmp is now broadly allowed (feedback 2033745d), this fixture lives at
    the $HOME root — which is NOT allowed (only ~/Desktop/iclr-backups and
    ~/Documents/sutando-launch-assets are) — to keep the fail-closed
    default under test."""
    with tempfile.NamedTemporaryFile(
        prefix="sutando-disallowed-root-", suffix=".txt",
        dir=str(Path.home()), delete=False
    ) as f:
        f.write(b"x")
        path = f.name
    try:
        assert not is_sendable(path), f"expected reject for {path}"
    finally:
        os.unlink(path)


def test_arbitrary_path_rejected():
    """Generic existing file (e.g., `/etc/hosts`) must reject. Files
    outside the allowlist are the attacker's exfil target — verify the
    fail-closed default."""
    # /etc/hosts exists on every macOS / Linux system. NOT under any
    # SEND_ALLOWED_ROOTS / SEND_ALLOWED_PREFIXES.
    assert not is_sendable("/etc/hosts")


def test_symlink_pointing_outside_allowed_root_rejected():
    """Path-injection guard: an attacker who can write a symlink under an
    allowed root must not be able to use it to exfil files outside.
    `_is_path_sendable` calls `realpath` before the prefix comparison
    precisely to defeat this. Regression guard for the original allowlist
    motivation (PR #494)."""
    # Create a symlink under an allowed prefix (/tmp/sutando-) pointing at a
    # real file outside every allowed root. Since /tmp is now broadly
    # allowed (feedback 2033745d), the target lives at the $HOME root so the
    # escape is genuinely outside policy and realpath-collapse stays tested.
    link = Path("/tmp/sutando-symlink-pointer.txt")
    if link.exists() or link.is_symlink():
        link.unlink()
    outside = Path.home() / "sutando-escaped-symlink-target-DELETEME.txt"
    outside.write_text("would be exfil")
    try:
        os.symlink(outside, link)
        assert not is_sendable(str(link)), (
            f"symlink {link} → {outside} bypassed the allowlist — "
            "realpath collapse is broken"
        )
    finally:
        if link.exists() or link.is_symlink():
            link.unlink()
        outside.unlink()


def test_path_traversal_dotdot_rejected():
    """A `..` traversal that escapes the allowlist must reject. Since /tmp
    is now broadly allowed (feedback 2033745d), the traversal must leave
    /tmp entirely — realpath collapses `/tmp/sutando-x/../../../etc/hosts`
    to /etc/hosts (a real file outside every allowed root) before the
    prefix check."""
    traversal = "/tmp/sutando-x/../../../etc/hosts"
    assert not is_sendable(traversal), (
        "path traversal via .. bypassed the allowlist — "
        "realpath collapse is broken"
    )


def test_allowed_prefixes_are_the_documented_set():
    """Architectural assertion: the allowed prefixes must stay a small,
    deliberate set. Broadened 2026-06 (feedback 2033745d) to all of /tmp
    (both realpath forms) so the agent can deliver ad-hoc /tmp working
    files; an INTENTIONAL owner-scoped beta widening (realpath still blocks
    escapes to $HOME/system — see the escape tests above). Any FURTHER
    widening (e.g. `/Users/`, `/var/folders/`, `/`) must update this set
    deliberately."""
    documented = {
        "/tmp/",
        "/private/tmp/",
    }
    actual = set(bridge.SEND_ALLOWED_PREFIXES)
    assert actual == documented, (
        f"SEND_ALLOWED_PREFIXES has changed unexpectedly. "
        f"Removed: {documented - actual}, Added: {actual - documented}. "
        "Update this test deliberately to confirm the new exposure is intended."
    )


def main():
    test_nonexistent_path_is_not_sendable()
    test_directory_is_not_sendable()
    test_allowed_prefix_match()
    test_disallowed_prefix_rejected()
    test_arbitrary_path_rejected()
    test_symlink_pointing_outside_allowed_root_rejected()
    test_path_traversal_dotdot_rejected()
    test_allowed_prefixes_are_the_documented_set()
    print("All _is_path_sendable security tests passed.")


if __name__ == "__main__":
    main()
