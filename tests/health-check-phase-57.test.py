#!/usr/bin/env python3
"""Phase 5.7 regression: check_discord_voice, check_notes_split_brain, and
the LoginFailure short-circuit in main()'s --fix branch.

Ports three OSS sutando additions:
  1. check_discord_voice(): pgrep-based discord-voice-server detection,
     soft-warn when down (it's on-demand, like conversation-server).
  2. check_notes_split_brain(): warns when <repo>/notes/ and <workspace>/notes/
     hold overlapping .md files — edits to one side become invisible.
  3. --fix branch: when a discord-bridge/telegram-bridge detail mentions
     LoginFailure or "token invalid", do NOT restart — print a guidance
     message instead. Pre-port, --fix would restart on bad tokens, which
     repeatedly crashes a fresh bridge against the same revoked credential
     and (if launchd is also managing one) creates a duplicate process.

We point $SUTANDO_WORKSPACE at a throwaway dir BEFORE importing health-check
so REPO_DIR/WORKSPACE_DIR/MEMORY_DIR resolve under it.
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from unittest.mock import patch

REPO = Path(__file__).resolve().parent.parent
_TMP = tempfile.mkdtemp(prefix="stando-hc-57-")
os.environ["SUTANDO_WORKSPACE"] = _TMP
# Pre-create dirs main()'s --fix branch writes into (logs/<bridge>.log open-
# for-append, state/ for health-last-notified.json). Resolved at import time
# via WORKSPACE_DIR; creating them after import is too late.
(Path(_TMP) / "logs").mkdir(parents=True, exist_ok=True)
(Path(_TMP) / "state").mkdir(parents=True, exist_ok=True)

sys.path.insert(0, str(REPO / "src"))


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


hc = _load("health_check", REPO / "src" / "health-check.py")


# ---------------------------------------------------------------- check_discord_voice

def test_discord_voice_returns_warn_when_not_running():
    """When pgrep finds no discord-voice-server process, return a soft warn.
    `warn` (not `down`/`fail`) so main()'s issue-count stays clean for the
    on-demand-by-design steady state."""
    fake = subprocess.CompletedProcess(args=[], returncode=1, stdout="", stderr="")
    with patch.object(hc.subprocess, "run", return_value=fake):
        out = hc.check_discord_voice()
    assert out["name"] == "discord-voice", out
    assert out["status"] == "warn", f"expected warn, got {out}"
    assert "running" in out["detail"], f"detail must mention 'running' so the dashboard service filter surfaces it: {out}"


def test_discord_voice_returns_ok_when_running():
    """When pgrep finds at least one PID, return ok. Detail contains 'running'
    (load-bearing for dashboard's service filter)."""
    fake = subprocess.CompletedProcess(args=[], returncode=0, stdout="54321\n", stderr="")
    with patch.object(hc.subprocess, "run", return_value=fake):
        out = hc.check_discord_voice()
    assert out["status"] == "ok", out
    assert "running" in out["detail"], out


def test_discord_voice_handles_timeout():
    """A pgrep timeout / OSError must NOT propagate — return warn, like 'not running'."""
    with patch.object(hc.subprocess, "run", side_effect=subprocess.TimeoutExpired(cmd="pgrep", timeout=5)):
        out = hc.check_discord_voice()
    assert out["status"] == "warn", out


# ---------------------------------------------------------------- check_notes_split_brain

def _seed_notes_dir(parent: Path, names: list[str]) -> Path:
    d = parent / "notes"
    d.mkdir(parents=True, exist_ok=True)
    for n in names:
        (d / n).write_text("body")
    return d


def test_notes_split_brain_returns_none_when_no_overlap():
    """No overlap → None (probe omitted from the checks list)."""
    tmp_repo = Path(tempfile.mkdtemp(prefix="hc-sb-repo-"))
    tmp_ws = Path(tempfile.mkdtemp(prefix="hc-sb-ws-"))
    _seed_notes_dir(tmp_repo, ["only-in-repo.md"])
    _seed_notes_dir(tmp_ws, ["only-in-ws.md"])
    with patch.object(hc, "REPO_DIR", tmp_repo), patch.object(hc, "WORKSPACE_DIR", tmp_ws):
        with patch.object(hc, "shared_personal_path", return_value=str(tmp_ws / "notes")):
            assert hc.check_notes_split_brain() is None


def test_notes_split_brain_returns_none_when_paths_are_the_same():
    """If repo notes/ and workspace notes/ resolve to the SAME path, there is
    no possible split-brain; the probe must return None even with files
    present. Prevents a false positive in single-dir installs."""
    tmp = Path(tempfile.mkdtemp(prefix="hc-sb-same-"))
    _seed_notes_dir(tmp, ["a.md"])
    with patch.object(hc, "REPO_DIR", tmp), patch.object(hc, "WORKSPACE_DIR", tmp):
        with patch.object(hc, "shared_personal_path", return_value=str(tmp / "notes")):
            assert hc.check_notes_split_brain() is None


def test_notes_split_brain_warns_when_overlap():
    """Overlap → warn with a detail that names the overlap + the migrate hint."""
    tmp_repo = Path(tempfile.mkdtemp(prefix="hc-sb-repo-"))
    tmp_ws = Path(tempfile.mkdtemp(prefix="hc-sb-ws-"))
    _seed_notes_dir(tmp_repo, ["shared.md", "repo-only.md"])
    _seed_notes_dir(tmp_ws, ["shared.md", "ws-only.md"])
    with patch.object(hc, "REPO_DIR", tmp_repo), patch.object(hc, "WORKSPACE_DIR", tmp_ws):
        with patch.object(hc, "shared_personal_path", return_value=str(tmp_ws / "notes")):
            out = hc.check_notes_split_brain()
    assert out is not None and out["status"] == "warn", out
    assert out["name"] == "notes-split-brain"
    assert "shared.md" in out["detail"], out
    assert "sutando-migrate.sh" in out["detail"], out


# ---------------------------------------------------------------- LoginFailure short-circuit

def test_main_fix_short_circuits_on_token_invalid():
    """When --fix sees a discord-bridge detail containing 'token invalid',
    it must print the no-restart guidance and NOT call subprocess.Popen
    (which would restart against a known-bad credential)."""
    failing = {
        "name": "discord-bridge",
        "status": "fail",
        "detail": "token invalid (LoginFailure) — regenerate at discord.com/developers/applications",
    }
    popen_calls: list[tuple] = []

    class _FakePopen:
        def __init__(self, *a, **kw):
            popen_calls.append((a, kw))

    buf = io.StringIO()
    with patch.object(hc, "run_all_checks", return_value=[failing]):
        with patch.object(hc.subprocess, "Popen", _FakePopen):
            with patch.object(hc.sys, "argv", ["health-check.py", "--fix"]):
                with contextlib.redirect_stdout(buf):
                    try:
                        hc.main()
                    except SystemExit:
                        pass  # main() ends with sys.exit(); harmless under test

    captured = buf.getvalue()
    assert "token invalid" in captured, f"expected guidance message; got: {captured!r}"
    assert "no restart" in captured.lower(), f"expected explicit 'no restart' wording; got: {captured!r}"
    assert popen_calls == [], f"Popen must NOT be called for a LoginFailure; got {popen_calls!r}"


def test_main_fix_still_restarts_on_normal_stale():
    """Regression guard: the LoginFailure short-circuit must NOT block a
    normal (non-LoginFailure) bridge restart. A stale code detail still
    triggers Popen."""
    failing = {
        "name": "discord-bridge",
        "status": "stale",
        "detail": "running but code is 45 min newer than process — restart needed",
    }
    popen_calls: list[tuple] = []

    class _FakePopen:
        def __init__(self, *a, **kw):
            popen_calls.append((a, kw))

    buf = io.StringIO()
    with patch.object(hc, "run_all_checks", return_value=[failing]):
        with patch.object(hc.subprocess, "Popen", _FakePopen):
            with patch.object(hc.subprocess, "run") as _run:
                _run.return_value = subprocess.CompletedProcess(args=[], returncode=1, stdout="", stderr="")
                with patch.object(hc.sys, "argv", ["health-check.py", "--fix"]):
                    with contextlib.redirect_stdout(buf):
                        try:
                            hc.main()
                        except SystemExit:
                            pass  # main() ends with sys.exit(); harmless under test

    captured = buf.getvalue()
    assert len(popen_calls) == 1, f"expected one Popen for the restart; got {popen_calls!r}\noutput: {captured}"


# ---------------------------------------------------------------- run_all_checks wiring

def test_run_all_checks_includes_discord_voice_probe():
    """run_all_checks() always appends a 'discord-voice' check — gate is
    'discord-voice can be started any time' per the new probe's comment."""
    # Avoid heavy actual checks; we only need to confirm presence in the list.
    with patch.object(hc.subprocess, "run", return_value=subprocess.CompletedProcess(args=[], returncode=1, stdout="", stderr="")):
        out = hc.run_all_checks()
    names = [c["name"] for c in out]
    assert "discord-voice" in names, f"discord-voice must appear in run_all_checks() output: got {names}"


def main():
    """Inline runner — stando tests must be invocable as plain scripts
    (the hyphenated filenames are not valid Python module names so pytest
    collection fails). Each test is independent + cleans up its own tmpdirs."""
    cases = [
        test_discord_voice_returns_warn_when_not_running,
        test_discord_voice_returns_ok_when_running,
        test_discord_voice_handles_timeout,
        test_notes_split_brain_returns_none_when_no_overlap,
        test_notes_split_brain_returns_none_when_paths_are_the_same,
        test_notes_split_brain_warns_when_overlap,
        test_main_fix_short_circuits_on_token_invalid,
        test_main_fix_still_restarts_on_normal_stale,
        test_run_all_checks_includes_discord_voice_probe,
    ]
    for fn in cases:
        fn()
        print(f"PASS {fn.__name__}")
    print(f"\nAll {len(cases)} Phase 5.7 health-check tests passed.")


if __name__ == "__main__":
    main()
