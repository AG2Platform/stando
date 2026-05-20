"""Per-machine runtime-state paths (tasks/, results/, state/, logs/, .env, …).

Thin wrapper over `workspace_default.resolve_workspace()`. Kept in its own
module so `util_paths.py` stays identical to upstream `sonichi/sutando` — the
canonical workspace resolution lives in `workspace_default`, this file only
adds the fork's directory-ensuring convenience.

  state_path(name)  — file path under the workspace; ensures the PARENT exists.
  state_dir(name)   — directory under the workspace; ensures IT exists.

Both resolve under `$SUTANDO_WORKSPACE` (default `~/.sutando/workspace/`).
"""
from __future__ import annotations

from pathlib import Path

from workspace_default import resolve_workspace


def state_path(name: str) -> Path:
    """Runtime-state file path under the workspace. Ensures the parent dir exists."""
    p = resolve_workspace(migrate=False) / name
    p.parent.mkdir(parents=True, exist_ok=True)
    return p


def state_dir(name: str) -> Path:
    """Runtime-state directory under the workspace. Ensures the directory exists."""
    p = resolve_workspace(migrate=False) / name
    p.mkdir(parents=True, exist_ok=True)
    return p
