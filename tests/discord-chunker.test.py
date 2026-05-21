#!/usr/bin/env python3
"""Unit tests for `_chunk_for_discord` — covers MacBook PR #563 review findings.

Pre-extraction this file loaded `src/discord-bridge.py` AND `src/dm-result.py`
via importlib and ran the same 7 cases against EACH copy of the chunker,
specifically because both files carried a copy and the test was the only
thing keeping them honest (they had nonetheless already drifted on the
long-line hard-split branch — see `src/discord_chunker.py` docstring).

Post-extraction the chunker lives in `src/discord_chunker.py` and both
bridge / dm-result import from it. The test loads it once.
"""

import importlib.util
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "src"))

# Plain import — `discord_chunker.py` has no underscore-in-filename
# obstacle and no module-load side effects (no discord runtime, no token
# file read). The previous importlib + stub-discord + materialize-.env
# bootstrap from this file is no longer needed.
import discord_chunker  # noqa: E402


def _run_cases(mod, label):
    # Test 1: empty/short
    assert list(mod._chunk_for_discord("")) == []
    assert list(mod._chunk_for_discord("hi")) == ["hi"]

    # Test 2: long plain text → multiple chunks, all <= max_len
    src = "\n".join(["line " + str(i) * 40 for i in range(200)])
    chunks = list(mod._chunk_for_discord(src, max_len=300))
    assert all(len(c) <= 300 for c in chunks), f"{label}: chunk too long"
    assert len(chunks) > 1

    # Test 3: code block spanning multiple chunks preserves opener with language tag
    src = "intro\n```python\n" + ("x = 1\n" * 400) + "```\nouter"
    chunks = list(mod._chunk_for_discord(src, max_len=300))
    assert len(chunks) >= 3, f"{label}: expected multi-chunk, got {len(chunks)}"
    for i, c in enumerate(chunks[:-1]):
        assert c.endswith("```"), f"{label}: chunk {i} missing closer: {c[-30:]!r}"
    assert "```python" in chunks[1], f"{label}: language tag dropped"

    # Test 4: print("```") inside fenced block must NOT close the fence early
    src = '```python\nprint("```")\nx = 1\nmore = 2\n```'
    chunks = list(mod._chunk_for_discord(src))
    full = "\n".join(chunks)
    fence_lines = [
        ln for ln in full.split("\n") if mod._is_fence_open_line(ln) is not None
    ]
    assert len(fence_lines) == 2, (
        f"{label}: print(```) misclassified as fence "
        f"(found {len(fence_lines)} fence-lines, expected 2)"
    )

    # Test 5: nested 4-tick outer fence preserved (Markdown allows ```` to wrap ```)
    src = "````markdown\n```python\ninner\n```\nstill outer\n````"
    chunks = list(mod._chunk_for_discord(src))
    assert "````markdown" in chunks[0], f"{label}: outer 4-tick opener lost"

    # Test 6: regex correctness for _is_fence_open_line
    cases = [
        ("```python", "```python"),
        ("```", "```"),
        ("``` ", "```"),
        ("```py extra", "```py extra"),
        ("~~~js", "~~~js"),
        ('print("```")', None),
        ("    print('```')", None),
        ("foo ```inline``` bar", None),
        ("``", None),
    ]
    for inp, exp in cases:
        got = mod._is_fence_open_line(inp)
        assert got == exp, f"{label}: {inp!r} -> got {got!r}, expected {exp!r}"

    # Test 7: tilde fence closes with tildes — token-kind preservation
    src = "~~~python\n" + ("x = 1\n" * 400) + "~~~"
    chunks = list(mod._chunk_for_discord(src, max_len=300))
    assert len(chunks) >= 2
    assert chunks[0].rstrip().endswith("~~~"), (
        f"{label}: tilde fence closed with wrong token: {chunks[0][-30:]!r}"
    )

    # Test 8 (NEW): the long-line hard-split branch with non-empty buf.
    # Pre-extraction, discord-bridge.py and dm-result.py disagreed on the
    # while-loop condition for this branch. With both call sites now
    # importing from the single canonical chunker, behavior is unified.
    # Construct an input that forces the long-line branch: short line +
    # long-line that's just under max_len, then exercise repeatedly.
    # The bug shape we're guarding against: a chunk exceeding max_len
    # because of mis-accounting `buf_len` in the while condition.
    src = "short line\n" + "x" * 250 + "\n" + "y" * 250 + "\n" + "z" * 250
    chunks = list(mod._chunk_for_discord(src, max_len=100))
    assert all(len(c) <= 100 for c in chunks), (
        f"{label}: hard-split chunk exceeded max_len — "
        f"sizes: {[len(c) for c in chunks]}"
    )

    print(f"[{label}] all 8 cases OK")


def main():
    _run_cases(discord_chunker, "discord_chunker")
    print("All chunker tests passed.")


if __name__ == "__main__":
    main()
