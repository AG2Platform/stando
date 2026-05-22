#!/usr/bin/env python3
"""Unit tests for `resolve_proactive_owner` (src/slack_proactive_owner.py).

## Bug

`src/slack-bridge.py`'s `result_watcher` resolved the proactive-DM recipient
with `next(iter(load_allowed()))`. `load_allowed()` returns a **set**, so
`next(iter(...))` yields a nondeterministic element. With more than one
`allowFrom` entry (the human owner plus peer bots / team members), a proactive
owner-notification DM could be delivered to the wrong Slack user.

## Fix

`resolve_proactive_owner(access_data, env_owner)` resolves deterministically:
`$SUTANDO_DM_OWNER_ID` → `tierMap` owner → `tofuOwner` (if still allowlisted)
→ first `allowFrom` entry in **list order**. Mirrors telegram-bridge's
`_resolve_proactive_owner_id`.

The function is pure (no I/O) and lives in its own module so this test does
not import `slack-bridge.py` (which builds a `slack_bolt.App` at module load).
"""

import importlib.util
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location(
    "slack_proactive_owner", REPO / "src" / "slack_proactive_owner.py"
)
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)
resolve_proactive_owner = _mod.resolve_proactive_owner


def test_env_override_wins():
    """$SUTANDO_DM_OWNER_ID beats everything else."""
    data = {"allowFrom": ["U_A", "U_B"], "tofuOwner": "U_B"}
    assert resolve_proactive_owner(data, "U_ENV") == "U_ENV"


def test_empty_allowfrom_returns_none():
    assert resolve_proactive_owner({"allowFrom": []}, None) is None
    assert resolve_proactive_owner({}, None) is None


def test_tier_owner_beats_tofu_and_list_order():
    """A tierMap 'owner' wins over tofuOwner and over first-in-list."""
    data = {
        "allowFrom": ["U_BOT", "U_HUMAN", "U_TEAM"],
        "tofuOwner": "U_BOT",
        "tierMap": {"U_BOT": "team", "U_HUMAN": "owner", "U_TEAM": "team"},
    }
    assert resolve_proactive_owner(data, None) == "U_HUMAN"


def test_tofu_owner_used_when_no_tier_owner():
    """With no tierMap 'owner', tofuOwner is used — if still in allowFrom."""
    data = {"allowFrom": ["U_BOT", "U_HUMAN"], "tofuOwner": "U_HUMAN"}
    assert resolve_proactive_owner(data, None) == "U_HUMAN"


def test_tofu_owner_ignored_when_removed_from_allowfrom():
    """A tofuOwner the admin removed from allowFrom is not honored —
    falls through to first allowFrom entry in list order."""
    data = {"allowFrom": ["U_BOT", "U_HUMAN"], "tofuOwner": "U_GONE"}
    assert resolve_proactive_owner(data, None) == "U_BOT"


def test_falls_back_to_first_allowfrom_in_list_order():
    """No env, no tierMap owner, no tofuOwner → first allowFrom entry.
    This is the case the set-iteration bug made nondeterministic."""
    data = {"allowFrom": ["U_FIRST", "U_SECOND", "U_THIRD"]}
    assert resolve_proactive_owner(data, None) == "U_FIRST"


def test_env_empty_string_is_not_an_override():
    """A falsy env value must not be treated as an override."""
    data = {"allowFrom": ["U_FIRST", "U_SECOND"]}
    assert resolve_proactive_owner(data, "") == "U_FIRST"


def _run():
    passed = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
            passed += 1
    print(f"All slack proactive-owner-resolution tests passed ({passed}).")


if __name__ == "__main__":
    _run()
