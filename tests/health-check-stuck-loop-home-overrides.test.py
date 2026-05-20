#!/usr/bin/env python3
"""Regression test: core-status.json follows SUTANDO_HOME, not REPO_DIR."""

import importlib.util
import json
import os
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("health_check", REPO / "src" / "health-check.py")
hc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hc)


def case_stuck_loop_home_overrides_repo() -> list[str]:
    fails = []
    with tempfile.TemporaryDirectory() as home_td, tempfile.TemporaryDirectory() as repo_td:
        home = Path(home_td)
        repo = Path(repo_td)
        payload = {"status": "running", "step": "tool:read", "ts": int(time.time())}
        (home / "core-status.json").write_text(json.dumps(payload))
        orig_repo = hc.REPO_DIR
        orig_home = os.environ.get("SUTANDO_HOME")
        try:
            os.environ["SUTANDO_HOME"] = str(home)
            hc.REPO_DIR = repo
            r = hc.check_core_proactive_loop(threshold_sec=600)
        finally:
            hc.REPO_DIR = orig_repo
            if orig_home is None:
                os.environ.pop("SUTANDO_HOME", None)
            else:
                os.environ["SUTANDO_HOME"] = orig_home
    if r["status"] != "ok" or not r["detail"].startswith("running"):
        fails.append(f"SUTANDO_HOME core-status.json should be read as running, got {r}")
    return fails


fails = case_stuck_loop_home_overrides_repo()
assert not fails, "\n".join(fails)
print("PASS: health-check core-status honors SUTANDO_HOME over REPO_DIR.")
