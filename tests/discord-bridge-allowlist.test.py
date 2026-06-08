#!/usr/bin/env python3
"""
Structural regression test for the discord-bridge file-send allowlist
(PR #494). Guards against accidental removal of the CodeQL sanitizer
pattern or the fail-closed allowlist behavior.

The CodeQL py/path-injection rule relies on the realpath+startswith
sanitizer pattern existing at the sink path. If a refactor moves that
logic into a helper whose return is used inconsistently, or drops the
allowlist in favor of bare `discord.File(fpath)`, we want to catch it
at test time — not after a talk demo leaks an attacker-supplied path.

Scope: STRUCTURAL — regex-matches the source files. Does NOT import the
bridge (discord.py dep weight is huge). Mirrors the style of
`discord-bridge-access-tier.test.py`.

Architecture note (Phase 5.9 OSS sync): the sanitizer body now lives in
`src/send_allowlist.py` (shared with `src/dm-result.py`). The discord
bridge imports the function and aliases it as `_is_path_sendable` so
every existing sink call site stays unchanged. This test follows the
implementation: checks #1-#4 inspect the helper module, check #5
verifies the import + alias wiring in the bridge, and check #6
verifies every `discord.File()` sink is gated by the alias.

Guards:
  1. `is_path_sendable` is defined in `src/send_allowlist.py`.
  2. The helper uses `os.path.realpath` (CodeQL sanitizer pattern —
     NOT replaceable with `Path.resolve()` without re-proving).
  3. The helper checks both SEND_ALLOWED_ROOTS and SEND_ALLOWED_PREFIXES.
  4. Fail-closed default: helper returns False when no entry matches.
  5. `discord-bridge.py` imports the helper and binds it as the local
     `_is_path_sendable` name. (Drift guard — a future PR that
     re-inlines a copy would break this assertion.)
  6. `discord.File(fpath)` sinks are always gated by `_is_path_sendable`.

Run: python3 tests/discord-bridge-allowlist.test.py
Exit: 0 on pass, 1 on fail.
"""

from pathlib import Path
import re
import sys

REPO = Path(__file__).resolve().parent.parent
BRIDGE = REPO / "src" / "discord-bridge.py"
HELPER = REPO / "src" / "send_allowlist.py"


def fail(msg: str, context: str = "") -> int:
    print(f"FAIL: {msg}", file=sys.stderr)
    if context:
        print("---context---", file=sys.stderr)
        print(context[:1500], file=sys.stderr)
    return 1


def main() -> int:
    if not BRIDGE.exists():
        return fail(f"{BRIDGE} not found")
    if not HELPER.exists():
        return fail(f"{HELPER} not found — shared allowlist module is missing")

    bridge_src = BRIDGE.read_text()
    helper_src = HELPER.read_text()

    # 1. Helper defined in send_allowlist.py
    helper_match = re.search(
        r"def is_path_sendable\(fpath:\s*str\)\s*->\s*bool:\s*\n([\s\S]{0,2000}?)(?=\n\ndef |\n\n[A-Z]|\Z)",
        helper_src,
    )
    if not helper_match:
        return fail(
            "`is_path_sendable` function not found in send_allowlist.py — "
            "shared sanitizer body is missing"
        )
    helper_body = helper_match.group(1)

    # 2. realpath used (CodeQL sanitizer pattern)
    if "os.path.realpath" not in helper_body:
        return fail(
            "is_path_sendable must use os.path.realpath "
            "(CodeQL py/path-injection sanitizer)",
            helper_body,
        )

    # 3. Both ROOTS and PREFIXES consulted in the helper
    if "SEND_ALLOWED_ROOTS" not in helper_body or "SEND_ALLOWED_PREFIXES" not in helper_body:
        return fail(
            "is_path_sendable must check both SEND_ALLOWED_ROOTS and "
            "SEND_ALLOWED_PREFIXES",
            helper_body,
        )

    # 4. Fail-closed default: final `return False` after the loops
    if not re.search(
        r"for prefix in SEND_ALLOWED_PREFIXES:[\s\S]+?return\s+False", helper_body
    ):
        return fail(
            "is_path_sendable must return False after iterating both "
            "allowlists (fail-closed)",
            helper_body,
        )

    # 5. discord-bridge.py must import the helper AND alias it locally
    # as `_is_path_sendable` so existing sink call sites stay gated.
    # Match the multi-line `from send_allowlist import (...)` block AND
    # the explicit alias assignment.
    if not re.search(
        r"from\s+send_allowlist\s+import\s+\(?[\s\S]{0,400}?is_path_sendable\b",
        bridge_src,
    ):
        return fail(
            "discord-bridge.py must import `is_path_sendable` from "
            "`send_allowlist` — drift hazard if a copy gets inlined"
        )
    if not re.search(
        r"_is_path_sendable\s*=\s*_is_path_sendable_shared\b", bridge_src
    ):
        return fail(
            "discord-bridge.py must alias `_is_path_sendable = "
            "_is_path_sendable_shared` so existing sink call sites "
            "resolve to the shared helper"
        )

    # 6. Every discord.File(fpath) send call must be gated by _is_path_sendable.
    # Find all `discord.File(...)` sink calls; for each, check that the
    # enclosing 6-line window above contains an `_is_path_sendable` guard.
    for match in re.finditer(r"discord\.File\(\s*(\w+)\s*\)", bridge_src):
        arg = match.group(1)
        start = bridge_src.rfind("\n", 0, match.start())
        for _ in range(6):
            prev = bridge_src.rfind("\n", 0, start)
            if prev < 0:
                break
            start = prev
        window = bridge_src[start:match.end()]
        if (
            f"_is_path_sendable({arg})" not in window
            and f"_is_path_sendable( {arg}" not in window
        ):
            return fail(
                f"discord.File({arg}) sink found without preceding "
                f"_is_path_sendable gate",
                window,
            )

    print("PASS: discord-bridge.py file-send allowlist looks correct.")
    print("  - is_path_sendable (in send_allowlist.py) uses os.path.realpath")
    print("  - checks both SEND_ALLOWED_ROOTS and SEND_ALLOWED_PREFIXES")
    print("  - fail-closed default (returns False if no allowlist match)")
    print("  - discord-bridge.py imports + aliases the helper (no inline copy)")
    print("  - all discord.File() sinks gated by _is_path_sendable")
    return 0


if __name__ == "__main__":
    sys.exit(main())
