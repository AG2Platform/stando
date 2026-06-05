#!/usr/bin/env python3
"""Integration tests for `send_dm` in src/dm-result.py.

Probes the end-to-end REST flow by replacing `urllib.request.urlopen`
with a recording fake — every request issued by `send_dm` lands in a
captured list so the test can assert ordering, URLs, and payload bodies
were what the real Discord API would have seen.

Two real bugs fixed in this PR are covered as regression guards:

  - `_resolve_owner_id` now honors `tierMap[uid] == "owner"`. Pre-fix
    the resolver only knew about $SUTANDO_DM_OWNER_ID and the
    bot-filter fallback; admins who tier-tagged an owner in
    access.json saw their notifications routed by the bot-filter
    instead. Same drift class as PR #22 (telegram-bridge).
  - `send_dm` now strips `[file:|send:|attach:]` markers from the body
    before chunking. Pre-fix the markers landed verbatim in the user's
    DM because dm-result is REST-only and has no multipart upload
    path. Captures the file list and logs it so the lossy delivery is
    visible.

Also pins the empty-body edge case: a body that becomes empty after
marker-strip must NOT POST `""` to /messages (Discord 400, error code
50006).

Scope intentionally small — five cases focused on behaviors the unit
tests for the helpers can't reach.
"""

import importlib.util
import json
import os
import sys
import tempfile
import types
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

os.environ.setdefault("DISCORD_BOT_TOKEN", "test-token-not-real")

# Materialize a placeholder .env so `_load_token()` finds it. dm-result
# also reads ACCESS_JSON for resolution — we override its module-level
# attribute per case below.
_channels_env = Path.home() / ".claude" / "channels" / "discord" / ".env"
if not _channels_env.exists():
    _channels_env.parent.mkdir(parents=True, exist_ok=True)
    _channels_env.write_text("DISCORD_BOT_TOKEN=test-token-not-real\n")


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


dm = _load("dm_result", REPO / "src" / "dm-result.py")


class _FakeResponse:
    """Minimal urllib response — `read()` returns whatever bytes the
    fake transport wants to return for the request that produced it."""

    def __init__(self, body_bytes: bytes):
        self._body = body_bytes

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class _FakeTransport:
    """Records every request and replies with canned responses keyed on
    `(method, url-suffix)`. Anything unmapped raises so the test fails
    loudly instead of silently hanging or returning None."""

    def __init__(self, responses):
        self.calls: list[dict] = []
        self._responses = dict(responses)

    def urlopen(self, request, timeout=None):  # signature matches urllib
        method = getattr(request, "method", None) or (
            "POST" if request.data is not None else "GET"
        )
        url = request.full_url
        body = None
        if request.data is not None:
            body = json.loads(request.data.decode())
        self.calls.append({"method": method, "url": url, "body": body})
        # Match on (method, suffix). e.g. ("GET", "/users/@me").
        for (m, suffix), reply in self._responses.items():
            if m == method and url.endswith(suffix):
                return _FakeResponse(json.dumps(reply).encode())
        raise AssertionError(f"unmocked request: {method} {url}")


def _install_transport(transport):
    dm.urllib.request.urlopen = transport.urlopen


def _restore_transport(original):
    dm.urllib.request.urlopen = original


def _with_access_json(content, fn, discord_config_data=None):
    """Override ACCESS_JSON to a temp file with the given dict for one
    test case. Restores afterward.

    Also isolates `discord_config.config_path()` so the resolver
    doesn't consult the real workspace's `discord-config.json` (which
    would short-circuit the legacy access.json tierMap chain that
    these tests pin). Phase 5.10: `discord-config.json` is consulted
    BEFORE access.json[tierMap] — without isolation, the dev's live
    workspace file would route every test through the real owner."""
    original_access = dm.ACCESS_JSON
    tmp_dir = Path(tempfile.mkdtemp(prefix="sutando-dm-test-"))
    tmp_access = tmp_dir / "access.json"
    tmp_access.write_text(json.dumps(content))
    dm.ACCESS_JSON = tmp_access

    # Isolate the workspace-local discord-config.json. Write whatever
    # `discord_config_data` says (None -> file absent -> helper returns
    # {} -> legacy access.json chain runs).
    import discord_config as _dc
    tmp_dc_path = tmp_dir / "discord-config.json"
    if discord_config_data is not None:
        tmp_dc_path.write_text(json.dumps(discord_config_data))
    original_config_path = _dc.config_path
    _dc.config_path = lambda: tmp_dc_path

    try:
        fn()
    finally:
        dm.ACCESS_JSON = original_access
        _dc.config_path = original_config_path
        tmp_access.unlink()
        if tmp_dc_path.exists():
            tmp_dc_path.unlink()
        tmp_dir.rmdir()


# -----------------------------------------------------------------------
# Cases
# -----------------------------------------------------------------------


def test_tier_map_resolution_skips_bot_lookup():
    """Bug A regression guard. allowFrom is `[non-owner, owner]` AND
    tierMap tags `owner`. The resolver MUST return `owner` directly,
    without calling `/users/{id}` on either ID — the tierMap signal is
    authoritative and the network round-trip is wasted work."""
    transport = _FakeTransport({
        ("POST", "/users/@me/channels"): {"id": "dm-channel-1"},
        ("POST", "/channels/dm-channel-1/messages"): {"id": "msg-1"},
    })
    original_urlopen = dm.urllib.request.urlopen

    def run():
        _install_transport(transport)
        try:
            ok = dm.send_dm("hello")
        finally:
            _restore_transport(original_urlopen)
        assert ok is True
        # The DM-open call must target the TIER-TAGGED owner, not the
        # first allowFrom entry.
        open_calls = [c for c in transport.calls if c["url"].endswith("/users/@me/channels")]
        assert len(open_calls) == 1, transport.calls
        assert open_calls[0]["body"] == {"recipient_id": "tier-owner-id"}
        # And critically, NO /users/{id} lookup happened — tierMap
        # short-circuits the bot-filter loop.
        bot_lookups = [c for c in transport.calls if "/users/" in c["url"] and not c["url"].endswith("/users/@me/channels")]
        assert bot_lookups == [], f"unexpected bot lookups: {bot_lookups}"

    _with_access_json(
        {
            "allowFrom": ["bot-id-A", "tier-owner-id", "bot-id-B"],
            "tierMap": {"tier-owner-id": "owner"},
        },
        run,
    )


def test_bot_filter_fallback_still_works_without_tier_map():
    """Pre-existing behavior preserved: with no tierMap, the resolver
    walks allowFrom, queries `/users/{id}.bot`, and picks the first
    non-bot. This case has bot first → human second; the lookup must
    skip the bot and return the human."""
    transport = _FakeTransport({
        ("GET", "/users/bot-id"): {"id": "bot-id", "bot": True},
        ("GET", "/users/human-id"): {"id": "human-id", "bot": False},
        ("POST", "/users/@me/channels"): {"id": "dm-channel-2"},
        ("POST", "/channels/dm-channel-2/messages"): {"id": "msg-2"},
    })
    original_urlopen = dm.urllib.request.urlopen

    def run():
        _install_transport(transport)
        try:
            ok = dm.send_dm("hi")
        finally:
            _restore_transport(original_urlopen)
        assert ok is True
        open_calls = [c for c in transport.calls if c["url"].endswith("/users/@me/channels")]
        assert open_calls[0]["body"] == {"recipient_id": "human-id"}

    _with_access_json(
        {"allowFrom": ["bot-id", "human-id"]},
        run,
    )


def test_file_markers_stripped_from_body():
    """Bug D regression guard. A result body containing a file marker
    must deliver the *clean text* to Discord — not the literal
    `[file: /path]` string. The file is logged as dropped (since
    REST multipart isn't implemented) but the user's DM is clean."""
    transport = _FakeTransport({
        ("POST", "/users/@me/channels"): {"id": "dm-3"},
        ("POST", "/channels/dm-3/messages"): {"id": "msg-3"},
    })
    original_urlopen = dm.urllib.request.urlopen

    def run():
        _install_transport(transport)
        try:
            ok = dm.send_dm(
                "Here's the screenshot you asked about: [file: /tmp/sutando-x.png]"
            )
        finally:
            _restore_transport(original_urlopen)
        assert ok is True
        msg_calls = [c for c in transport.calls if "/messages" in c["url"]]
        assert len(msg_calls) == 1
        sent_body = msg_calls[0]["body"]["content"]
        # The marker is gone …
        assert "[file:" not in sent_body, f"marker leaked into DM: {sent_body!r}"
        # … but the surrounding text is preserved.
        assert "Here's the screenshot you asked about:" in sent_body

    _with_access_json(
        {"allowFrom": ["human-id"], "tierMap": {"human-id": "owner"}},
        run,
    )


def test_empty_body_after_marker_strip_does_not_post_messages():
    """Bug C: a body that's ONLY a file marker becomes empty after
    strip. The pre-fix code did `chunks = list(chunker(text)) or [text]`,
    which fell back to `[""]` and posted an empty message — Discord
    rejected with 400 / code 50006. New behavior: skip the /messages
    call entirely; report no-op."""
    transport = _FakeTransport({
        ("POST", "/users/@me/channels"): {"id": "dm-4"},
        # If /messages is called, the test fails because we didn't
        # register a response — _FakeTransport raises AssertionError.
    })
    original_urlopen = dm.urllib.request.urlopen

    def run():
        _install_transport(transport)
        try:
            ok = dm.send_dm("[file: /tmp/sutando-x.png]")
        finally:
            _restore_transport(original_urlopen)
        assert ok is True  # No-op is not an error.
        msg_calls = [c for c in transport.calls if "/messages" in c["url"]]
        assert msg_calls == [], (
            f"expected NO /messages POSTs for an all-marker body; got {msg_calls}"
        )

    _with_access_json(
        {"allowFrom": ["human-id"], "tierMap": {"human-id": "owner"}},
        run,
    )


def test_env_override_skips_access_json_entirely():
    """Existing behavior preserved: $SUTANDO_DM_OWNER_ID short-circuits
    all of access.json + tierMap + bot-lookup. Pin it so a future
    refactor (e.g., moving env-read below tierMap "for consistency")
    doesn't break the documented priority order."""
    transport = _FakeTransport({
        ("POST", "/users/@me/channels"): {"id": "dm-5"},
        ("POST", "/channels/dm-5/messages"): {"id": "msg-5"},
    })
    original_urlopen = dm.urllib.request.urlopen
    os.environ["SUTANDO_DM_OWNER_ID"] = "env-override-id"

    def run():
        _install_transport(transport)
        try:
            ok = dm.send_dm("hi")
        finally:
            _restore_transport(original_urlopen)
            del os.environ["SUTANDO_DM_OWNER_ID"]
        assert ok is True
        open_calls = [c for c in transport.calls if c["url"].endswith("/users/@me/channels")]
        assert open_calls[0]["body"] == {"recipient_id": "env-override-id"}

    # access.json contents are deliberately the WRONG owner so we can
    # prove the env override won.
    _with_access_json(
        {
            "allowFrom": ["other-human-id"],
            "tierMap": {"other-human-id": "owner"},
        },
        run,
    )


def main():
    test_tier_map_resolution_skips_bot_lookup()
    test_bot_filter_fallback_still_works_without_tier_map()
    test_file_markers_stripped_from_body()
    test_empty_body_after_marker_strip_does_not_post_messages()
    test_env_override_skips_access_json_entirely()
    print("All send_dm integration tests passed.")


if __name__ == "__main__":
    main()
