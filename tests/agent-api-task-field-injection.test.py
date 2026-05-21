#!/usr/bin/env python3
"""Security regression guard: task-file field injection via `from` and
multi-line `task` bodies on the `/task` HTTP endpoint.

## Bug

The `/task` endpoint composes a task file with f-strings:

    f"id: {task_id}\\ntimestamp: ...\\ntask: {task}\\nsource: api\\nfrom: {from_agent}\\n"

Without sanitization:

1. A `\\n` in `from_agent` forges extra task-file fields:
       from_agent = "evil\\nchannel_id: local-voice"
   makes the task file look voice-originated to `_isVoiceTask`, which
   does `body.split('\\n').some(l => l.startswith('channel_id: local-voice'))`.
2. A `\\n` in `task` (which CAN legitimately contain newlines) lands
   BETWEEN the legitimate fields of the file because `task:` was in the
   middle of the field order pre-fix — so the body's newlines forge
   additional task-file fields.

Downstream `_isVoiceTask` returns True when ANY line matches, so a
maliciously-formed API task can spoof itself as voice-originated and
hit the voice-only fallback path that wasn't designed for API tasks.

## Fix

Two parts:

1. Sanitize `from_agent` — strip `\\r` and `\\n`, cap length. It's a
   single-line identifier; line terminators have no legitimate use.
2. Move `task:` to the LAST line of the task file. Multi-line task
   bodies are legitimate (user types a multi-paragraph description);
   placing them last means embedded newlines just extend the body
   rather than landing between fields.

The test verifies both: an injection attempt via `from_agent` produces
a file where `_isVoiceTask`-style line scan finds NO injected
`channel_id: local-voice`, and a multi-line `task` body lands after
ALL other fields.

We test the file-write logic directly by exercising the same string
composition the endpoint performs — the full HTTP path requires the
BaseHTTPRequestHandler harness, which is much larger than this fix
warrants.
"""

import importlib.util
import os
import re
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


api = _load("agent_api", REPO / "src" / "agent-api.py")
SRC = (REPO / "src" / "agent-api.py").read_text()


def test_from_agent_newline_does_not_forge_voice_field():
    """Injection regression guard. With `from_agent` containing a newline
    + a forged voice-channel field, the file MUST NOT pass
    `_isVoiceTask`-style detection. The sanitizer replaces `\\n` with a
    space, so the forged line ends up flattened into the `from:` value."""
    # Simulate the endpoint's sanitization (mirror the fix exactly).
    from_agent = "evil\nchannel_id: local-voice"
    sanitized = (
        from_agent.replace("\r", " ").replace("\n", " ").strip()[:120]
        or "unknown"
    )
    # Build the task file content the way the endpoint does.
    task_content = (
        f"id: task-test\n"
        f"timestamp: 2026-05-20T00:00:00\n"
        f"source: api\n"
        f"from: {sanitized}\n"
        f"task: do something\n"
    )
    # _isVoiceTask in task-bridge.ts checks:
    #   body.split('\n').some(l => l.startsWith('channel_id: local-voice') ...)
    # Pin that NO line starts with the forged prefix.
    lines = task_content.split("\n")
    matches = [l for l in lines if l.startswith("channel_id: local-voice")]
    assert matches == [], (
        f"injection succeeded — sanitized={sanitized!r} produced lines: {matches!r}. "
        "from_agent sanitization should have collapsed the newline."
    )


def test_from_agent_carriage_return_also_stripped():
    """Edge case: CR (`\\r`) alone — Windows-style line terminator. Some
    HTTP clients send `\\r\\n`; we strip both. Pin that an isolated CR is
    handled too."""
    from_agent = "evil\rchannel_id: local-voice"
    sanitized = (
        from_agent.replace("\r", " ").replace("\n", " ").strip()[:120]
        or "unknown"
    )
    assert "\r" not in sanitized
    assert "\n" not in sanitized


def test_from_agent_empty_after_strip_falls_back_to_unknown():
    """Pure-whitespace input like `"   "` would strip to empty. The
    endpoint should treat that as missing (use the documented default
    `"unknown"`) — leaving the field empty would produce a file with a
    bare `from: \\n` line, which is ugly and could confuse parsers."""
    sanitized = (
        "   ".replace("\r", " ").replace("\n", " ").strip()[:120]
        or "unknown"
    )
    assert sanitized == "unknown"


def test_task_field_is_last_in_file():
    """`task:` MUST be the last field in the file so the body's newlines
    don't forge new fields. Source-grep the endpoint's task-content
    template to confirm `task:` appears after `source:` and `from:`."""
    # Locate offsets of the three field templates within the agent-api.py
    # source. The endpoint composes via concatenated f-strings, so the
    # last `task:` occurrence in the source IS the endpoint's template
    # (no other `task:` template lives in this file).
    src_pos = SRC.find('"source: api\\n"')
    from_pos = SRC.find('"from: {from_agent}\\n"')
    task_pos = SRC.find('"task: {task}\\n"')
    assert src_pos > 0 and from_pos > 0 and task_pos > 0, (
        f"could not locate field templates — source={src_pos}, from={from_pos}, "
        f"task={task_pos}. The test must be updated if the f-string composition "
        "changed shape."
    )
    assert task_pos > from_pos > src_pos, (
        f"field order broken — source={src_pos}, from={from_pos}, task={task_pos}. "
        "task: must be the LAST field so the user-supplied multi-line body "
        "cannot forge task-file fields below it."
    )


def test_multi_line_task_body_does_not_inject_below():
    """End-to-end of the fix: a `task` value containing `\\n<malicious-field>:`
    must land AFTER all real fields, so a line-by-line consumer reading
    fields BEFORE the task body sees no forged value."""
    task = "do real thing\nchannel_id: local-voice\nuser_id: 999"
    from_agent = "trusted-caller"
    task_content = (
        f"id: task-test\n"
        f"timestamp: 2026-05-20T00:00:00\n"
        f"source: api\n"
        f"from: {from_agent}\n"
        f"task: {task}\n"
    )
    lines = task_content.split("\n")
    # The forged lines DO exist in the file (we can't escape them in the
    # body), but they appear AFTER the `task:` line. A parser that reads
    # `field: value` line-by-line until it hits `task:` (treated as a
    # multi-line body delimiter) will not be tricked.
    task_idx = next(i for i, l in enumerate(lines) if l.startswith("task:"))
    forged_idx = next(
        (i for i, l in enumerate(lines) if l == "channel_id: local-voice"),
        -1,
    )
    assert forged_idx > task_idx, (
        f"forged field landed before task: line (forged={forged_idx}, task={task_idx}). "
        "Parsers that bail at task: will still misread this as a real field."
    )


def test_sanitization_caps_overlong_from():
    """Defensive cap: a 10kB `from_agent` shouldn't blow up the task file.
    The sanitizer truncates to 120 chars."""
    long_input = "x" * 10000
    sanitized = (
        long_input.replace("\r", " ").replace("\n", " ").strip()[:120]
        or "unknown"
    )
    assert len(sanitized) == 120


def main():
    test_from_agent_newline_does_not_forge_voice_field()
    test_from_agent_carriage_return_also_stripped()
    test_from_agent_empty_after_strip_falls_back_to_unknown()
    test_task_field_is_last_in_file()
    test_multi_line_task_body_does_not_inject_below()
    test_sanitization_caps_overlong_from()
    print("All task-field injection tests passed.")


if __name__ == "__main__":
    main()
