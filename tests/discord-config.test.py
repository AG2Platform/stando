#!/usr/bin/env python3
"""Tests for `src/discord_config.py` — the shared owner-resolution helper.

`discord_config.resolve_owner_id` is the single source of truth for the
owner-id resolution chain used by both `discord-bridge.py:_poll_proactive`
(live bridge) and `dm-result.py:_resolve_owner_id` (REST fallback). If
either site drifts away from importing it, the failure mode is the
exact bug class that bit #846 (one site got the tierMap read and the
other didn't, routing proactive DMs to the wrong user).

Tests cover four concerns:

  1. Resolution chain semantics — the 5 documented config-driven steps
     in priority order (env -> workspace owner -> workspace tierMap ->
     legacy owner -> legacy tierMap), with the helper returning None
     when none match (signaling "caller does the bot-filter walk").
  2. Helper safety: load_config on missing/corrupt file, save_config
     atomicity, auto_seed_if_missing idempotency + the warn-on-fallback
     path Lucy flagged.
  3. Drift guards: both consumers (`discord-bridge.py` and
     `dm-result.py`) must import the helper, not carry inline copies
     of the resolution chain.
  4. Stale-tier safety: a `tierMap[uid] == "owner"` entry for a user
     NOT in `allowFrom` must NOT resolve them (the helper's `allow_list`
     filter is the only thing standing between a delisted owner and a
     routing bug).
"""

import importlib.util
import json
import logging
import os
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "src"))


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


import discord_config  # noqa: E402


# -----------------------------------------------------------------------
# 1. resolve_owner_id chain semantics
# -----------------------------------------------------------------------


def test_env_override_wins_over_everything():
    """Step 1: $SUTANDO_DM_OWNER_ID is the operator escape hatch. It
    must win even when every config field has a different owner."""
    os.environ["SUTANDO_DM_OWNER_ID"] = "env-owner"
    try:
        result = discord_config.resolve_owner_id(
            {
                "allowFrom": ["other"],
                "tierMap": {"other": "owner"},
                "owner": "legacy-owner",
            },
            config={"owner": "ws-owner", "tierMap": {"other": "owner"}},
        )
        assert result == "env-owner", f"env override didn't win; got {result!r}"
    finally:
        del os.environ["SUTANDO_DM_OWNER_ID"]


def test_workspace_owner_wins_over_legacy():
    """Step 2: discord-config.json `owner` field wins over the legacy
    access.json `owner` field. Drift compatibility — if both files have
    `owner` set, the Sutando-owned one takes precedence."""
    os.environ.pop("SUTANDO_DM_OWNER_ID", None)
    result = discord_config.resolve_owner_id(
        {"owner": "legacy-owner"},
        config={"owner": "ws-owner"},
    )
    assert result == "ws-owner"


def test_workspace_tier_map_wins_over_legacy_tier_map():
    """Step 3 > Step 5. Both files can carry a `tierMap`; if both tag
    a (different) user as owner, the workspace file wins."""
    os.environ.pop("SUTANDO_DM_OWNER_ID", None)
    result = discord_config.resolve_owner_id(
        {"allowFrom": ["a", "b"], "tierMap": {"a": "owner"}},
        config={"tierMap": {"b": "owner"}},
    )
    assert result == "b"


def test_legacy_owner_used_when_no_workspace_fields():
    """Step 4: workspace file has no owner/tierMap (e.g. empty {}). The
    legacy access.json `owner` field is consulted next."""
    os.environ.pop("SUTANDO_DM_OWNER_ID", None)
    result = discord_config.resolve_owner_id(
        {"owner": "legacy-owner", "allowFrom": ["a"]},
        config={},
    )
    assert result == "legacy-owner"


def test_legacy_tier_map_used_when_no_higher_priority():
    """Step 5: the #846 path — `access.json[tierMap][uid] == "owner"`
    AND uid is in allowFrom. Final config-driven step."""
    os.environ.pop("SUTANDO_DM_OWNER_ID", None)
    result = discord_config.resolve_owner_id(
        {"allowFrom": ["alice", "bob"], "tierMap": {"bob": "owner"}},
        config={},
    )
    assert result == "bob"


def test_returns_none_when_chain_exhausted():
    """No env var, no workspace fields, no legacy fields. Helper must
    return None — the SIGNAL that the caller should do the bot-filter
    walk. Crucial: helper deliberately does NOT fall through to
    allowFrom[0]; that's the #1147 bug path."""
    os.environ.pop("SUTANDO_DM_OWNER_ID", None)
    result = discord_config.resolve_owner_id(
        {"allowFrom": ["alice", "bob"]},
        config={},
    )
    assert result is None


def test_stale_tier_map_for_delisted_user_does_not_resolve():
    """Safety: if `tierMap` tags a user as "owner" but that user is
    NOT in `allowFrom` (delisted but tier-tag forgotten), the helper
    must NOT resolve them. The `allow_list` filter is the guard."""
    os.environ.pop("SUTANDO_DM_OWNER_ID", None)
    result = discord_config.resolve_owner_id(
        {"allowFrom": ["alice"], "tierMap": {"removed-owner": "owner"}},
        config={},
    )
    assert result is None, (
        "stale tierMap[removed-owner] -> owner resolved a delisted user; "
        "the allowFrom filter is broken"
    )


# -----------------------------------------------------------------------
# 2. load_config / save_config / auto_seed_if_missing
# -----------------------------------------------------------------------


def test_load_config_missing_file_returns_empty_dict():
    """File absent -> {}. Treats "no Sutando-side config" the same as
    "empty config" so the legacy fallback chain runs untouched."""
    tmp_dir = Path(tempfile.mkdtemp(prefix="sutando-dc-test-"))
    try:
        original = discord_config.config_path
        discord_config.config_path = lambda: tmp_dir / "missing.json"
        assert discord_config.load_config() == {}
    finally:
        discord_config.config_path = original
        tmp_dir.rmdir()


def test_load_config_corrupt_file_returns_empty_dict():
    """Corrupted JSON -> {}. Bridge stays operational; only the
    Sutando-side override goes away (legacy access.json chain still
    works)."""
    tmp_dir = Path(tempfile.mkdtemp(prefix="sutando-dc-test-"))
    tmp_path = tmp_dir / "discord-config.json"
    tmp_path.write_text("{not valid json")
    try:
        original = discord_config.config_path
        discord_config.config_path = lambda: tmp_path
        assert discord_config.load_config() == {}
    finally:
        discord_config.config_path = original
        tmp_path.unlink()
        tmp_dir.rmdir()


def test_save_config_atomic_replace():
    """save_config writes tmp + rename. Verify the final file matches
    the dict and no `.tmp` debris remains."""
    tmp_dir = Path(tempfile.mkdtemp(prefix="sutando-dc-test-"))
    tmp_path = tmp_dir / "discord-config.json"
    try:
        original = discord_config.config_path
        discord_config.config_path = lambda: tmp_path
        discord_config.save_config({"owner": "abc", "tierMap": {"abc": "owner"}})
        loaded = json.loads(tmp_path.read_text())
        assert loaded == {"owner": "abc", "tierMap": {"abc": "owner"}}
        # No tmp residue
        residue = list(tmp_dir.glob("*.tmp"))
        assert residue == [], f"atomic-write debris left behind: {residue}"
    finally:
        discord_config.config_path = original
        tmp_path.unlink()
        tmp_dir.rmdir()


def test_auto_seed_idempotent_when_file_exists():
    """If discord-config.json already exists, auto_seed_if_missing
    must NOT overwrite — operator-edited owner fields would be lost."""
    tmp_dir = Path(tempfile.mkdtemp(prefix="sutando-dc-test-"))
    tmp_path = tmp_dir / "discord-config.json"
    tmp_path.write_text(json.dumps({"owner": "operator-set"}))
    try:
        original = discord_config.config_path
        discord_config.config_path = lambda: tmp_path
        result = discord_config.auto_seed_if_missing(
            {"owner": "different-legacy-owner", "allowFrom": ["alice"]}
        )
        assert result == {"owner": "operator-set"}, (
            f"auto_seed clobbered an existing file; got {result}"
        )
    finally:
        discord_config.config_path = original
        tmp_path.unlink()
        tmp_dir.rmdir()


def test_auto_seed_seeds_legacy_owner_when_missing():
    """First boot, access.json[owner] set -> seed picks it up cleanly
    without the WARN path."""
    tmp_dir = Path(tempfile.mkdtemp(prefix="sutando-dc-test-"))
    tmp_path = tmp_dir / "discord-config.json"
    try:
        original = discord_config.config_path
        discord_config.config_path = lambda: tmp_path
        result = discord_config.auto_seed_if_missing(
            {"owner": "human-id", "allowFrom": ["human-id", "bot-id"]}
        )
        assert result["owner"] == "human-id"
        loaded = json.loads(tmp_path.read_text())
        assert loaded["owner"] == "human-id"
    finally:
        discord_config.config_path = original
        if tmp_path.exists():
            tmp_path.unlink()
        tmp_dir.rmdir()


def test_auto_seed_warns_on_allow_from_zero_fallback(caplog=None):
    """Per Lucy's #1147 watch-point #2: when seed falls through to
    `allowFrom[0]` (no owner field, no tierMap match), emit a WARN.
    Operator catches a mis-seed instead of silently recreating the
    #1147 bug."""
    tmp_dir = Path(tempfile.mkdtemp(prefix="sutando-dc-test-"))
    tmp_path = tmp_dir / "discord-config.json"
    test_log = logging.getLogger("test-auto-seed-warn")
    test_log.setLevel(logging.DEBUG)
    handler = _ListHandler()
    test_log.addHandler(handler)
    try:
        original = discord_config.config_path
        discord_config.config_path = lambda: tmp_path
        result = discord_config.auto_seed_if_missing(
            {"allowFrom": ["maybe-not-owner"]},
            logger_=test_log,
        )
        assert result["owner"] == "maybe-not-owner"
        # Critical: WARN must fire, mentioning Susan / #1147 context
        warns = [r for r in handler.records if r.levelno >= logging.WARNING]
        assert warns, "auto_seed fell through to allowFrom[0] without WARN"
        msg = warns[0].getMessage()
        assert "allowFrom[0]" in msg or "VERIFY" in msg, msg
    finally:
        discord_config.config_path = original
        if tmp_path.exists():
            tmp_path.unlink()
        tmp_dir.rmdir()


class _ListHandler(logging.Handler):
    def __init__(self):
        super().__init__()
        self.records: list[logging.LogRecord] = []

    def emit(self, record):
        self.records.append(record)


# -----------------------------------------------------------------------
# 3. Drift guards — both consumers import the helper
# -----------------------------------------------------------------------


def test_dm_result_imports_discord_config():
    """`src/dm-result.py` must `import discord_config` and call
    `resolve_owner_id` from it. Drift hazard if a future PR re-inlines
    the chain."""
    src = (REPO / "src" / "dm-result.py").read_text()
    assert "import discord_config" in src, (
        "dm-result.py no longer imports discord_config — drift hazard"
    )
    assert "discord_config.resolve_owner_id(" in src, (
        "dm-result.py no longer calls discord_config.resolve_owner_id — "
        "must be the resolution engine, not just imported"
    )


def test_discord_bridge_imports_discord_config():
    """`src/discord-bridge.py` must `import discord_config` AND call
    `resolve_owner_id` in the proactive owner block AND
    `auto_seed_if_missing` in on_ready."""
    src = (REPO / "src" / "discord-bridge.py").read_text()
    assert "import discord_config" in src, (
        "discord-bridge.py no longer imports discord_config — drift hazard"
    )
    assert "discord_config.resolve_owner_id(" in src, (
        "discord-bridge.py no longer calls discord_config.resolve_owner_id"
    )
    assert "discord_config.auto_seed_if_missing(" in src, (
        "discord-bridge.py no longer seeds discord-config.json at startup"
    )


def main():
    test_env_override_wins_over_everything()
    test_workspace_owner_wins_over_legacy()
    test_workspace_tier_map_wins_over_legacy_tier_map()
    test_legacy_owner_used_when_no_workspace_fields()
    test_legacy_tier_map_used_when_no_higher_priority()
    test_returns_none_when_chain_exhausted()
    test_stale_tier_map_for_delisted_user_does_not_resolve()
    test_load_config_missing_file_returns_empty_dict()
    test_load_config_corrupt_file_returns_empty_dict()
    test_save_config_atomic_replace()
    test_auto_seed_idempotent_when_file_exists()
    test_auto_seed_seeds_legacy_owner_when_missing()
    test_auto_seed_warns_on_allow_from_zero_fallback()
    test_dm_result_imports_discord_config()
    test_discord_bridge_imports_discord_config()
    print("All discord_config tests passed.")


if __name__ == "__main__":
    main()
