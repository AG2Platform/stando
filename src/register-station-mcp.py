#!/usr/bin/env python3
"""Register the Sutando Superpower Station MCP server with Claude Code.

Reads `$SUTANDO_HOME/cloud-auth.json` (or repo-root fallback) for the
user's API base + Bearer token, then writes an `mcpServers.sutando-station`
entry into `~/.claude.json`. Idempotent — only writes when the
configuration changes.

Triggered from `src/startup.sh` on every Sutando launch and from the
Swift `CloudAuth.cloudAuthDidSignIn` handler after the user signs in.
Both surfaces converge on this script so a single script update is the
only place we have to edit when Claude Code's MCP config schema shifts.

Usage:
    python3 src/register-station-mcp.py          # add/update entry
    python3 src/register-station-mcp.py --remove # delete entry (sign-out)

Exit codes:
    0  registered/removed (or no-op if already in desired state)
    1  no cloud-auth.json on disk — user is signed out; we leave the
       existing entry intact so Claude Code keeps working (register only)
    2  parse error in ~/.claude.json or cloud-auth.json
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from pathlib import Path


SERVER_KEY = "sutando-station"


def cloud_auth_path() -> Path | None:
    home = os.environ.get("SUTANDO_HOME")
    candidates: list[Path] = []
    if home:
        candidates.append(Path(home).expanduser() / "cloud-auth.json")
    # Repo-root fallback (dev workflow).
    here = Path(__file__).resolve().parent.parent
    candidates.append(here / "cloud-auth.json")
    for p in candidates:
        if p.exists():
            return p
    return None


def load_cloud_auth() -> dict | None:
    path = cloud_auth_path()
    if path is None:
        return None
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError as e:
        print(f"register-station-mcp: cannot parse {path}: {e}", file=sys.stderr)
        return None


def claude_config_path() -> Path:
    return Path.home() / ".claude.json"


def desired_entry(api_base: str, token: str) -> dict:
    base = api_base.rstrip("/")
    return {
        "type": "http",
        "url": f"{base}/api/mcp/v1",
        "headers": {
            "Authorization": f"Bearer {token}",
        },
    }


def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(text)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def load_claude_config(config_path: Path) -> dict | None:
    if not config_path.exists():
        return {}
    try:
        return json.loads(config_path.read_text())
    except json.JSONDecodeError as e:
        print(f"register-station-mcp: cannot parse {config_path}: {e}", file=sys.stderr)
        return None


def do_register() -> int:
    auth = load_cloud_auth()
    if auth is None:
        print("register-station-mcp: not signed in to cloud — nothing to do.", file=sys.stderr)
        return 1
    api_base = auth.get("apiBase")
    token = auth.get("token")
    if not api_base or not token:
        print("register-station-mcp: cloud-auth.json is missing apiBase or token.", file=sys.stderr)
        return 2

    config_path = claude_config_path()
    cfg = load_claude_config(config_path)
    if cfg is None:
        return 2

    cfg.setdefault("mcpServers", {})
    existing = cfg["mcpServers"].get(SERVER_KEY)
    target = desired_entry(api_base, token)

    if existing == target:
        print(f"✓ {SERVER_KEY} already up-to-date in {config_path}")
        return 0

    cfg["mcpServers"][SERVER_KEY] = target
    atomic_write(config_path, json.dumps(cfg, indent=2) + "\n")
    action = "updated" if existing else "added"
    print(f"✓ {SERVER_KEY} {action} in {config_path}")
    print(
        "  Restart Claude Code (or detach + reattach the tmux core-agent) "
        "for the new MCP server to load."
    )
    return 0


def do_remove() -> int:
    config_path = claude_config_path()
    cfg = load_claude_config(config_path)
    if cfg is None:
        return 2
    servers = cfg.get("mcpServers") or {}
    if SERVER_KEY not in servers:
        print(f"✓ {SERVER_KEY} not present in {config_path}")
        return 0
    del servers[SERVER_KEY]
    # Drop the key entirely if empty — keeps the config minimal so users
    # who inspect ~/.claude.json don't see a confusing empty section.
    if not servers and "mcpServers" in cfg:
        del cfg["mcpServers"]
    else:
        cfg["mcpServers"] = servers
    atomic_write(config_path, json.dumps(cfg, indent=2) + "\n")
    print(f"✓ {SERVER_KEY} removed from {config_path}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--remove",
        action="store_true",
        help="Delete the sutando-station entry from ~/.claude.json (used on sign-out).",
    )
    args = parser.parse_args()
    return do_remove() if args.remove else do_register()


if __name__ == "__main__":
    sys.exit(main())
