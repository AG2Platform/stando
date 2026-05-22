#!/usr/bin/env python3
"""Unit tests for `_split_file_markers` in src/discord-bridge.py.

The `[file:|send:|attach:]` marker regex was duplicated inline at THREE
sites in `discord-bridge.py` — `poll_results` (channel replies),
`poll_proactive` (owner DMs), and the dm-fallback channel-redirect path.
PR #496 had to harden it once (tighten to absolute paths); any future
hardening had to be applied three times by hand. This file pins the
behavior of the consolidated `_split_file_markers` helper and the
underlying `_FILE_MARKER_RE` pattern so a future refactor that drifts
one call site fails here instead of in production.

Conventions mirror tests/discord-chunker.test.py (importlib + stubbed
discord + materialized .env).
"""

import importlib.util
import sys
import types
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# Same module-load bypass as the other discord-bridge tests.
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
split = bridge._split_file_markers


def test_no_markers_returns_text_and_empty_list():
    """The common case: a plain reply with no file attachments. Body
    comes back stripped but otherwise unchanged; file list is empty."""
    clean, files = split("Hello world — no files here.")
    assert clean == "Hello world — no files here."
    assert files == []


def test_empty_input():
    """Empty body (file-only reply that consumed the only marker, or
    proactive with no content). Both outputs must be safe to iterate /
    pass through `if clean_text:` guards in callers."""
    clean, files = split("")
    assert clean == ""
    assert files == []


def test_single_file_marker_extracted():
    """`[file: /path]` extracts the path and removes the marker."""
    clean, files = split("Here is the screenshot: [file: /tmp/sutando-x.png]")
    assert clean == "Here is the screenshot:"
    assert files == ["/tmp/sutando-x.png"]


def test_send_and_attach_aliases():
    """Three keywords share the same pattern: `file`, `send`, `attach`.
    Each must extract identically — they're aliases the agent uses
    interchangeably in result bodies."""
    for keyword in ("file", "send", "attach"):
        clean, files = split(f"body [{keyword}: /tmp/sutando-x.png]")
        assert files == ["/tmp/sutando-x.png"], f"keyword={keyword} did not match"
        assert clean == "body"


def test_home_relative_path_matches():
    """`~/...` is a deliberate allowed form — paths under the user's
    home are common (e.g., `~/.claude/...`). The bridge's downstream
    code does `os.path.expanduser` before `_is_path_sendable`."""
    clean, files = split("body [file: ~/.claude/notes/x.md]")
    assert files == ["~/.claude/notes/x.md"]
    assert clean == "body"


def test_relative_path_does_not_match():
    """PR #496 hardened the pattern to require absolute paths (`/...` or
    `~/...`). Relative paths previously resolved against the bridge's
    CWD, which differed between launchd-managed and bare-shell runs.
    Regression guard: bare filenames and `./` paths must NOT match."""
    for not_a_path in ("relative.txt", "./file.txt", "../escape.txt", "subdir/file.txt"):
        clean, files = split(f"body [file: {not_a_path}]")
        assert files == [], f"unexpectedly matched: {not_a_path!r}"


def test_multiple_markers_preserve_order():
    """Multiple markers in one body must extract in textual order so the
    downstream loop sends files in the order the agent intended."""
    clean, files = split(
        "first [file: /tmp/sutando-1.png] middle [send: /tmp/sutando-2.png] end"
    )
    assert files == ["/tmp/sutando-1.png", "/tmp/sutando-2.png"]
    assert clean == "first  middle  end"


def test_colon_in_path_does_not_break_match():
    """The character class `[^\\]:]+` rejects colons inside the path
    captures. This is deliberate — the path "ends" before any colon —
    so a marker like `[file: /tmp/x: notes]` stops at the colon. This
    also prevents accidentally matching `[reply: 12345]` (the directive)
    as a file path."""
    clean, files = split("body [reply: 12345678901234567890]")
    # `[reply:]` is the reply directive (handled elsewhere), not a file
    # marker. The keyword must be one of file/send/attach.
    assert files == []


def test_marker_with_path_containing_space_does_match():
    """The character class is `[^\\]:]+` — only `]` and `:` are excluded.
    Spaces inside the path ARE allowed (Discord file names with spaces
    are common). Confirms the regex doesn't silently drop them."""
    clean, files = split("body [file: /tmp/sutando-with space.png]")
    assert files == ["/tmp/sutando-with space.png"]


def test_strip_preserves_internal_whitespace():
    """`.strip()` collapses leading/trailing whitespace only — internal
    spacing (including marker-induced double spaces) is left intact for
    the callers to handle. This pins the post-strip body shape so a
    future "tidy up double spaces" refactor doesn't quietly change what
    users see."""
    clean, files = split("  body [file: /tmp/sutando-x.png] tail  ")
    assert clean == "body  tail"  # double space from marker removal preserved
    assert files == ["/tmp/sutando-x.png"]


def test_unknown_keyword_does_not_match():
    """Only `file`, `send`, `attach` are recognized. Other keywords like
    `path:` or `attach_to:` must not silently extract — they'd be
    user-content, not directives."""
    for bad in ("path", "url", "attachment", "file2"):
        clean, files = split(f"body [{bad}: /tmp/sutando-x.png]")
        assert files == [], f"keyword {bad!r} unexpectedly matched"


def test_marker_with_no_space_after_colon_matches():
    """`\\s*` allows zero whitespace between the colon and the path.
    Confirms the pattern accepts both `[file:/path]` and `[file: /path]`."""
    clean, files = split("body [file:/tmp/sutando-x.png]")
    assert files == ["/tmp/sutando-x.png"]


def test_marker_inside_code_fence_still_matches():
    """The marker doesn't know it's inside a code fence — extraction
    runs on the raw body before any rendering. This is the documented
    behavior; callers that want to demonstrate a marker without sending
    must escape or break the bracket. Captures the contract so a future
    "skip markers inside fences" change is a deliberate, tested choice."""
    body = "```text\nexample [file: /tmp/sutando-x.png]\n```"
    clean, files = split(body)
    assert files == ["/tmp/sutando-x.png"]


def test_three_call_sites_use_the_helper():
    """Architectural assertion: the regex must be defined exactly once.
    A future refactor that re-introduces an inline `file_pattern = re.compile(...)`
    at a third call site would break this — keep the source of truth single."""
    src = (REPO / "src" / "discord-bridge.py").read_text()
    # Pattern body should appear in exactly one place: the module-level
    # `_FILE_MARKER_RE` definition.
    occurrences = src.count(r"\[(?:file|send|attach):")
    assert occurrences == 1, (
        f"expected exactly 1 occurrence of the marker regex pattern, found {occurrences} "
        f"— a call site has likely re-introduced an inline `re.compile(...)` "
        f"copy and will drift when the pattern is next hardened"
    )


def main():
    test_no_markers_returns_text_and_empty_list()
    test_empty_input()
    test_single_file_marker_extracted()
    test_send_and_attach_aliases()
    test_home_relative_path_matches()
    test_relative_path_does_not_match()
    test_multiple_markers_preserve_order()
    test_colon_in_path_does_not_break_match()
    test_marker_with_path_containing_space_does_match()
    test_strip_preserves_internal_whitespace()
    test_unknown_keyword_does_not_match()
    test_marker_with_no_space_after_colon_matches()
    test_marker_inside_code_fence_still_matches()
    test_three_call_sites_use_the_helper()
    print("All file-marker tests passed.")


if __name__ == "__main__":
    main()
