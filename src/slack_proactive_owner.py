"""Proactive-DM owner resolution for the Slack bridge.

Extracted to its own module so the priority logic is unit-testable WITHOUT
importing `src/slack-bridge.py`, which constructs a `slack_bolt.App` at module
load time (requires `SLACK_BOT_TOKEN` and may do a network `auth.test`). Same
extraction rationale as `skills/phone-conversation/scripts/loopback_guard.ts`.

Mirrors `telegram-bridge.py`'s `_resolve_proactive_owner_id` priority order so
every bridge agrees on who "the owner" is for proactive notifications.
"""

from __future__ import annotations


def resolve_proactive_owner(
    access_data: dict, env_owner: str | None = None
) -> str | None:
    """Resolve the Slack user ID that should receive a proactive owner DM.

    Priority order:
      1. ``env_owner`` — the ``$SUTANDO_DM_OWNER_ID`` override (falsy if unset).
      2. ``tierMap[uid] == "owner"`` — the first tier-tagged owner in
         ``allowFrom`` list order. Tier tags are an explicit admin signal and
         win over ``tofuOwner`` (a first-install default the admin may not
         have refreshed after allowlisting more users).
      3. ``tofuOwner`` — recorded by TOFU onboarding; honored only if still
         present in ``allowFrom`` (an admin who removed it signaled intent).
      4. First entry in ``allowFrom`` IN LIST ORDER. Admins put the human
         owner first; list order is meaningful.

    Returns ``None`` when ``allowFrom`` is empty/absent.

    Pure function — no I/O. The caller reads ``access.json`` and
    ``os.environ`` and passes the values in.

    Pre-fix, `slack-bridge.py`'s `result_watcher` did
    ``next(iter(load_allowed()))`` — `load_allowed()` returns a *set*, so the
    "owner" was a nondeterministic set element. With multiple `allowFrom`
    entries (human owner + peer bots / team members) a proactive DM could be
    delivered to the wrong recipient.
    """
    if env_owner:
        return env_owner
    allow_list = access_data.get("allowFrom") or []
    if not allow_list:
        return None
    tier_map = access_data.get("tierMap") or {}
    tier_owner = next(
        (uid for uid in allow_list if tier_map.get(uid) == "owner"), None
    )
    if tier_owner is not None:
        return tier_owner
    tofu_owner = access_data.get("tofuOwner")
    if tofu_owner is not None and tofu_owner in allow_list:
        return tofu_owner
    return allow_list[0]
