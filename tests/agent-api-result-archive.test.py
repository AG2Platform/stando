#!/usr/bin/env python3
"""Phase 5.3 regression: get_task_result() must find a completed result that
has already been moved to the month-partitioned archive.

## Why

task-bridge archives a result file (results/<id>.txt → results/archive/
<YYYY-MM>/<id>.txt) within ~seconds of delivering it. The web UI polls
GET /result/<id> until status != 'pending'. If the archive move wins the
race against the poll, get_task_result() — which only checked live
results/ + tasks/ — returned None and the endpoint 404'd a task that had
actually completed. OSS sutando added an archive-glob fallback; this ports
it. /tasks/active already scanned the same results/archive/<YYYY-MM>/
layout, so this just brings /result/ to parity.

We point $SUTANDO_WORKSPACE at a throwaway dir BEFORE importing agent-api
so RESULT_DIR/TASK_DIR resolve under it (state_dir() resolves at import).
"""

import importlib.util
import os
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
_TMP = tempfile.mkdtemp(prefix="stando-result-archive-")
os.environ["SUTANDO_WORKSPACE"] = _TMP

# workspace_default lives in src/; make it importable for agent-api's
# `from workspace_default import resolve_workspace`.
import sys
sys.path.insert(0, str(REPO / "src"))


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


api = _load("agent_api", REPO / "src" / "agent-api.py")


def test_completed_result_in_month_archive_is_found():
    """A result that exists only under results/archive/<YYYY-MM>/ must be
    reported completed (not 404)."""
    task_id = "task-archive-1700000000000"
    archive_dir = api.RESULT_DIR / "archive" / "2026-05"
    archive_dir.mkdir(parents=True, exist_ok=True)
    (archive_dir / f"{task_id}.txt").write_text("archived result body")

    out = api.get_task_result(task_id)
    assert out is not None, "archived result should be found, got None (404)"
    assert out["status"] == "completed", f"expected completed, got {out!r}"
    assert out["result"] == "archived result body"
    assert out["task_id"] == task_id


def test_live_result_still_wins_over_archive():
    """The live results/<id>.txt path takes precedence over the archive."""
    task_id = "task-archive-1700000000001"
    (api.RESULT_DIR / f"{task_id}.txt").write_text("live result body")
    archive_dir = api.RESULT_DIR / "archive" / "2026-05"
    archive_dir.mkdir(parents=True, exist_ok=True)
    (archive_dir / f"{task_id}.txt").write_text("stale archived body")

    out = api.get_task_result(task_id)
    assert out is not None and out["status"] == "completed"
    assert out["result"] == "live result body", f"live file should win, got {out!r}"


def test_unknown_task_still_returns_none():
    """No live result, no archive, no task file → None (404), unchanged."""
    assert api.get_task_result("task-archive-does-not-exist") is None


def main():
    test_completed_result_in_month_archive_is_found()
    test_live_result_still_wins_over_archive()
    test_unknown_task_still_returns_none()
    print("All agent-api result-archive tests passed.")


if __name__ == "__main__":
    main()
