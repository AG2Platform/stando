#!/usr/bin/env python3
"""Regression guard for the prose-quoted file-marker false positive.

Caught by the owner on 2026-05-20: an agent's reply body contained the
inline-code substring ``` `[file: /tmp/sutando-x.png]` ``` as part of
prose explaining the marker convention. The bridge's regex extracts
ANY `[file:|send:|attach:]` substring regardless of markdown context
(inline code, code fence, blockquote, etc.), so it tried to send
`/tmp/sutando-x.png` — which doesn't exist — and shipped a
`(file not found: /tmp/sutando-x.png)` Discord message as confusing
noise after the agent's clean reply.

A markdown-aware regex is the principled fix but a much larger change.
The minimal user-impact fix is to STOP shipping the warning message to
the user when the extracted path doesn't exist — those are almost
always false-positive extractions from prose, and the warning is
worse-than-useless noise. Operators retain visibility via stderr logs
for real typos.

`(file not allowed: ...)` (allowlist rejection) is NOT silenced —
that's a security signal worth surfacing.

This test pins the new behavior by inspecting the source for the
relevant branches; the full poll_results flow is async + coupled to
discord.py and would need a much larger harness to invoke end-to-end.
"""

import importlib.util
import sys
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
SRC = (REPO / "src" / "discord-bridge.py").read_text()


def test_no_send_sites_for_file_not_found_remain():
    """All three send paths (poll_results, poll_proactive,
    poll_dm_fallback) previously called `channel.send(f"(file not
    found: ...)")` directly. After this PR, none should remain — the
    user-facing warning is replaced with a stderr log."""
    # Look for the exact pre-fix send-call shape.
    bad_patterns = [
        '.send(f"(file not found: ',
        ".send(f'(file not found: ",
    ]
    for pat in bad_patterns:
        assert pat not in SRC, (
            f"source still contains {pat!r} — a send call would surface "
            "the false-positive warning to the user. Replace with a stderr "
            "log (see poll_results comment)."
        )


def test_file_not_allowed_still_surfaces_to_user():
    """Defensive: the `(file not allowed: ...)` path MUST still send
    to the user. It's a security signal (someone's trying to exfil a
    file outside the allowlist) and silencing it would degrade
    operator + user awareness of attempted exfil. Pin so a future
    over-zealous "silence all warnings" refactor doesn't drop it."""
    # The allowed-path rejection still uses a send. Confirm it survived.
    assert '.send(f"(file not allowed: ' in SRC, (
        "(file not allowed: ...) warning was removed too — that's a "
        "security signal and must stay user-visible"
    )


def test_telegram_bridge_aligned():
    """Telegram bridge had the same pattern (line 386 pre-fix). Pin
    that it also no longer surfaces the false-positive to the user."""
    tg_src = (REPO / "src" / "telegram-bridge.py").read_text()
    bad_patterns = [
        'api("sendMessage", chat_id=chat_id, text=f"(file not found: ',
        "api('sendMessage', chat_id=chat_id, text=f'(file not found: ",
    ]
    for pat in bad_patterns:
        assert pat not in tg_src, (
            f"telegram-bridge still surfaces (file not found:) — {pat!r}"
        )
    # access-denied (the security-relevant case) still surfaces.
    assert "(file access denied: " in tg_src, (
        "telegram-bridge dropped the security-relevant access-denied warning"
    )


def main():
    test_no_send_sites_for_file_not_found_remain()
    test_file_not_allowed_still_surfaces_to_user()
    test_telegram_bridge_aligned()
    print("All prose-marker regression-guard tests passed.")


if __name__ == "__main__":
    main()
